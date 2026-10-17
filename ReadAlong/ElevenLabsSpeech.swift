import AVFoundation
import Foundation
import Security

struct ElevenLabsSpeechSettings: Sendable {
    let apiKey: String
    let voiceID: String
    let modelID: String
}

@MainActor
final class ElevenLabsSpeechConfiguration: ObservableObject {
    static let sampleAmericanVoiceID = "EXAVITQu4vr4xnSDxMaL" // Sarah
    static let sampleBritishVoiceID = "JBFqnCBsd6RMkjVDRZzb" // George

    @Published var isEnabled: Bool { didSet { save() } }
    @Published var modelID: String { didSet { save() } }
    @Published var americanVoiceID: String { didSet { save() } }
    @Published var britishVoiceID: String { didSet { save() } }
    @Published var apiKey: String {
        didSet {
            guard !isRestoringAPIKey else { return }
            let value = apiKey
            keychainSaveQueue.async { ElevenLabsSpeechKeychain.save(value) }
        }
    }
    private var isRestoringAPIKey = false
    private let keychainSaveQueue = DispatchQueue(label: "ReadAlong.ElevenLabs.KeychainSave", qos: .utility)

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "elevenLabsSpeechEnabled")
        modelID = defaults.string(forKey: "elevenLabsSpeechModelID") ?? "eleven_flash_v2_5"
        americanVoiceID = defaults.string(forKey: "elevenLabsAmericanVoiceID") ?? Self.sampleAmericanVoiceID
        britishVoiceID = defaults.string(forKey: "elevenLabsBritishVoiceID") ?? Self.sampleBritishVoiceID
        apiKey = ""
        Task.detached(priority: .utility) { [weak self] in
            let savedKey = ElevenLabsSpeechKeychain.load()
            await MainActor.run {
                guard let self, let savedKey, self.apiKey.isEmpty else { return }
                self.isRestoringAPIKey = true
                self.apiKey = savedKey
                self.isRestoringAPIKey = false
            }
        }
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!americanVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !britishVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func settings(for accent: EnglishAccent) -> ElevenLabsSpeechSettings? {
        guard isEnabled, isConfigured else { return nil }
        let selectedVoiceID = accent == .american ? americanVoiceID : britishVoiceID
        let voiceID = selectedVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty else { return nil }
        return ElevenLabsSpeechSettings(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            voiceID: voiceID,
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func useSampleVoices() {
        americanVoiceID = Self.sampleAmericanVoiceID
        britishVoiceID = Self.sampleBritishVoiceID
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: "elevenLabsSpeechEnabled")
        defaults.set(modelID, forKey: "elevenLabsSpeechModelID")
        defaults.set(americanVoiceID, forKey: "elevenLabsAmericanVoiceID")
        defaults.set(britishVoiceID, forKey: "elevenLabsBritishVoiceID")
    }
}

enum ElevenLabsSpeechService {
    struct TimedAudio: Sendable {
        let data: Data
        let wordStartTimes: [TimeInterval]
        let wordPausesApplied: Bool
    }

    static func synthesize(text: String, speed: Double, settings: ElevenLabsSpeechSettings) async throws -> Data {
        let request = try makeRequest(text: text, speed: speed, settings: settings, withTimestamps: false)
        let (data, http) = try await perform(request)
        guard http.mimeType == "audio/mpeg" || http.mimeType == "audio/mp3" else {
            throw ElevenLabsSpeechError.invalidResponse
        }
        return data
    }

    static func synthesizeChildWords(
        _ words: [String],
        pause: Double,
        speed: Double,
        settings: ElevenLabsSpeechSettings,
        previousText: String? = nil,
        nextText: String? = nil
    ) async throws -> TimedAudio {
        guard !words.isEmpty else { throw ElevenLabsSpeechError.invalidResponse }
        var text = ""
        var wordOffsets: [Int] = []
        for word in words {
            if !text.isEmpty { text += " " }
            wordOffsets.append(text.count)
            text += word
        }

        let request = try makeRequest(
            text: text, speed: speed, settings: settings, withTimestamps: true,
            previousText: previousText, nextText: nextText
        )
        let (data, http) = try await perform(request)
        guard http.mimeType == "application/json",
              let response = try? JSONDecoder().decode(TimingResponse.self, from: data),
              let audio = Data(base64Encoded: response.audioBase64), !audio.isEmpty else {
            throw ElevenLabsSpeechError.invalidResponse
        }
        let alignment = response.alignment
        let startTimes: [TimeInterval]
        let endTimes: [TimeInterval]
        if alignment?.characters.joined() == text,
           let times = alignment?.characterStartTimesSeconds,
           let ends = alignment?.characterEndTimesSeconds,
           times.count == alignment?.characters.count,
           ends.count == times.count,
           zip(wordOffsets, words).allSatisfy({ offset, word in offset + word.count <= times.count }) {
            startTimes = wordOffsets.map { times[$0] }
            endTimes = zip(wordOffsets, words).map { offset, word in ends[offset + word.count - 1] }
        } else {
            startTimes = []
            endTimes = []
        }
        guard pause > 0, startTimes.count == words.count, endTimes.count == words.count else {
            return TimedAudio(data: audio, wordStartTimes: startTimes, wordPausesApplied: pause <= 0)
        }
        do {
            let processed = try insertWordPauses(into: audio, starts: startTimes, ends: endTimes, pause: pause)
            return TimedAudio(data: processed.data, wordStartTimes: processed.starts, wordPausesApplied: true)
        } catch {
            // Speech remains usable if a particular MP3 cannot be decoded locally.
            return TimedAudio(data: audio, wordStartTimes: startTimes, wordPausesApplied: false)
        }
    }

    private static func insertWordPauses(
        into mp3: Data,
        starts: [TimeInterval],
        ends: [TimeInterval],
        pause: Double
    ) throws -> (data: Data, starts: [TimeInterval]) {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        try mp3.write(to: sourceURL, options: .atomic)
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              source.length > 0, source.length < Int64(UInt32.max),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(source.length)) else {
            throw ElevenLabsSpeechError.invalidResponse
        }
        try source.read(into: input)
        let inputFrames = Int(input.frameLength)
        let sampleRate = format.sampleRate
        guard inputFrames > 0, sampleRate > 0 else { throw ElevenLabsSpeechError.invalidResponse }

        struct Insertion {
            let frame: Int
            let silenceFrames: Int
        }
        var insertions: [Insertion] = []
        var adjustedStarts = starts
        var addedFrames = 0
        for index in 0..<(starts.count - 1) {
            let wordEnd = max(starts[index], ends[index])
            let nextStart = starts[index + 1]
            guard wordEnd.isFinite, nextStart.isFinite else { throw ElevenLabsSpeechError.invalidResponse }
            let naturalGap = max(0, nextStart - wordEnd)
            let silenceFrames = Int((max(0, pause - naturalGap) * sampleRate).rounded())
            let boundaryTime = nextStart > wordEnd ? (wordEnd + nextStart) / 2 : wordEnd
            let frame = min(inputFrames, max(0, Int((boundaryTime * sampleRate).rounded())))
            guard insertions.last.map({ frame >= $0.frame }) ?? true else {
                throw ElevenLabsSpeechError.invalidResponse
            }
            insertions.append(Insertion(frame: frame, silenceFrames: silenceFrames))
            addedFrames += silenceFrames
            adjustedStarts[index + 1] = max(
                nextStart + Double(addedFrames) / sampleRate,
                Double(frame + addedFrames) / sampleRate
            )
        }
        let outputFrames = inputFrames + addedFrames
        guard outputFrames < Int(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(outputFrames)),
              let inputChannels = input.floatChannelData,
              let outputChannels = output.floatChannelData else {
            throw ElevenLabsSpeechError.invalidResponse
        }
        output.frameLength = UInt32(outputFrames)
        for channel in 0..<Int(format.channelCount) {
            let sourceSamples = inputChannels[channel]
            let outputSamples = outputChannels[channel]
            var inputOffset = 0
            var outputOffset = 0
            for insertion in insertions {
                let count = insertion.frame - inputOffset
                if count > 0 {
                    memcpy(outputSamples.advanced(by: outputOffset),
                           sourceSamples.advanced(by: inputOffset), count * MemoryLayout<Float>.size)
                }
                outputOffset += count
                if insertion.silenceFrames > 0 {
                    memset(outputSamples.advanced(by: outputOffset), 0,
                           insertion.silenceFrames * MemoryLayout<Float>.size)
                    outputOffset += insertion.silenceFrames
                }
                inputOffset = insertion.frame
            }
            let remaining = inputFrames - inputOffset
            if remaining > 0 {
                memcpy(outputSamples.advanced(by: outputOffset),
                       sourceSamples.advanced(by: inputOffset), remaining * MemoryLayout<Float>.size)
            }
            var priorSilence = 0
            for insertion in insertions where insertion.silenceFrames > 0 {
                let left = insertion.frame + priorSilence
                let right = left + insertion.silenceFrames
                let fadeFrames = min(Int(sampleRate * 0.005), left, outputFrames - right)
                if fadeFrames > 0 {
                    for sample in 0..<fadeFrames {
                        outputSamples[left - fadeFrames + sample] *= Float(fadeFrames - sample) / Float(fadeFrames)
                        outputSamples[right + sample] *= Float(sample + 1) / Float(fadeFrames)
                    }
                }
                priorSilence += insertion.silenceFrames
            }
        }
        let channelCount = Int(format.channelCount)
        let byteCount = outputFrames * channelCount * MemoryLayout<Int16>.size
        guard byteCount <= Int(UInt32.max) - 36 else { throw ElevenLabsSpeechError.invalidResponse }
        var samples = [Int16](repeating: 0, count: outputFrames * channelCount)
        for frame in 0..<outputFrames {
            for channel in 0..<channelCount {
                let value = outputChannels[channel][frame]
                let sample = value.isFinite ? max(-1, min(1, value)) : 0
                samples[frame * channelCount + channel] = Int16((sample * 32767).rounded()).littleEndian
            }
        }
        var wav = Data("RIFF".utf8)
        func append16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        append32(UInt32(36 + byteCount))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)
        append16(UInt16(channelCount))
        append32(UInt32(sampleRate.rounded()))
        append32(UInt32(sampleRate.rounded()) * UInt32(channelCount) * 2)
        append16(UInt16(channelCount * 2))
        append16(16)
        wav.append(contentsOf: "data".utf8)
        append32(UInt32(byteCount))
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        return (wav, adjustedStarts)
    }

    private static func makeRequest(
        text: String,
        speed: Double,
        settings: ElevenLabsSpeechSettings,
        withTimestamps: Bool,
        previousText: String? = nil,
        nextText: String? = nil
    ) throws -> URLRequest {
        let validVoiceID = settings.voiceID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        let endpoint = withTimestamps ? "/with-timestamps" : ""
        guard validVoiceID,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(settings.voiceID)\(endpoint)?output_format=mp3_44100_128") else {
            throw ElevenLabsSpeechError.invalidVoiceID
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(settings.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(withTimestamps ? "application/json" : "audio/mpeg", forHTTPHeaderField: "Accept")
        // The article speed slider is calibrated for AVSpeechSynthesizer. ElevenLabs
        // accepts a narrower synthesis speed range of 0.7...1.2.
        let voiceSpeed = min(1.2, max(0.7, speed / 0.45 * (withTimestamps ? 0.7 : 1.0)))
        var body: [String: Any] = [
            "text": text,
            "model_id": settings.modelID,
            "voice_settings": [
                "stability": 0.8,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true,
                "speed": voiceSpeed
            ]
        ]
        if let previousText { body["previous_text"] = previousText }
        if let nextText { body["next_text"] = nextText }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ElevenLabsSpeechError.invalidResponse }
        guard 200..<300 ~= http.statusCode, !data.isEmpty else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = body?["detail"] as? [String: Any]
            throw ElevenLabsSpeechError.service(
                statusCode: http.statusCode,
                code: detail?["status"] as? String ?? detail?["code"] as? String
            )
        }
        return (data, http)
    }

    private struct TimingResponse: Decodable {
        let audioBase64: String
        let alignment: Alignment?

        enum CodingKeys: String, CodingKey {
            case audioBase64 = "audio_base64"
            case alignment
        }
    }

    private struct Alignment: Decodable {
        let characters: [String]
        let characterStartTimesSeconds: [TimeInterval]
        let characterEndTimesSeconds: [TimeInterval]?

        enum CodingKeys: String, CodingKey {
            case characters
            case characterStartTimesSeconds = "character_start_times_seconds"
            case characterEndTimesSeconds = "character_end_times_seconds"
        }
    }
}

enum ElevenLabsSpeechError: LocalizedError {
    case invalidVoiceID, invalidResponse, service(statusCode: Int, code: String?)

    var errorDescription: String? {
        switch self {
        case .invalidVoiceID: return "ElevenLabs Voice ID 无效。"
        case .invalidResponse: return "ElevenLabs 未返回有效音频。"
        case .service(let statusCode, let code):
            if code == "paid_plan_required" { return "当前 ElevenLabs 声音需要付费方案才能通过 API 使用。请改用设置中的免费方案示例声音。" }
            if code == "insufficient_credits" || code == "quota_exceeded" { return "ElevenLabs 额度已用完，请查看账户剩余额度。" }
            if code == "invalid_api_key" { return "ElevenLabs API Key 无效或已过期，请检查设置中的密钥。" }
            if statusCode == 401 { return "ElevenLabs 拒绝了请求（HTTP 401），请检查 API Key、账户额度或权限。" }
            if statusCode == 403 { return "ElevenLabs 拒绝了这次请求，请检查 API Key 权限和声音使用权限。" }
            if statusCode == 429 { return "ElevenLabs 请求过于频繁或额度不足。" }
            return "ElevenLabs 请求失败（HTTP \(statusCode)）。"
        }
    }
}

private enum ElevenLabsSpeechKeychain {
    private static let service = "ReadAlong.ElevenLabsSpeech"
    private static let legacyService = "EnglishReader.ElevenLabsSpeech"
    private static let account = "apiKey"

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> String? {
        load(service: service) ?? load(service: legacyService)
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
