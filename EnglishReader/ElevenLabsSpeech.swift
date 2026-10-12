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
    @Published var apiKey: String { didSet { ElevenLabsSpeechKeychain.save(apiKey) } }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "elevenLabsSpeechEnabled")
        modelID = defaults.string(forKey: "elevenLabsSpeechModelID") ?? "eleven_flash_v2_5"
        americanVoiceID = defaults.string(forKey: "elevenLabsAmericanVoiceID") ?? Self.sampleAmericanVoiceID
        britishVoiceID = defaults.string(forKey: "elevenLabsBritishVoiceID") ?? Self.sampleBritishVoiceID
        apiKey = ElevenLabsSpeechKeychain.load() ?? ""
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
        settings: ElevenLabsSpeechSettings
    ) async throws -> TimedAudio {
        guard !words.isEmpty else { throw ElevenLabsSpeechError.invalidResponse }
        let breakTag = String(format: "<break time=\"%.1fs\" />", locale: Locale(identifier: "en_US_POSIX"), min(3.0, max(0.5, pause)))
        let separator = " \(breakTag) "
        var text = ""
        var wordOffsets: [Int] = []
        for word in words {
            if !text.isEmpty { text += separator }
            wordOffsets.append(text.count)
            text += word
        }

        let request = try makeRequest(text: text, speed: speed, settings: settings, withTimestamps: true)
        let (data, http) = try await perform(request)
        guard http.mimeType == "application/json",
              let response = try? JSONDecoder().decode(TimingResponse.self, from: data),
              let audio = Data(base64Encoded: response.audioBase64), !audio.isEmpty else {
            throw ElevenLabsSpeechError.invalidResponse
        }
        let alignment = response.alignment
        let startTimes: [TimeInterval]
        if alignment?.characters.joined() == text,
           let times = alignment?.characterStartTimesSeconds,
           times.count == alignment?.characters.count,
           wordOffsets.allSatisfy({ $0 < times.count }) {
            startTimes = wordOffsets.map { times[$0] }
        } else {
            startTimes = []
        }
        return TimedAudio(data: audio, wordStartTimes: startTimes)
    }

    private static func makeRequest(
        text: String,
        speed: Double,
        settings: ElevenLabsSpeechSettings,
        withTimestamps: Bool
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
        let voiceSpeed = min(1.2, max(0.7, speed / 0.45))
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": settings.modelID,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true,
                "speed": voiceSpeed
            ]
        ])

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
                code: detail?["code"] as? String
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

        enum CodingKeys: String, CodingKey {
            case characters
            case characterStartTimesSeconds = "character_start_times_seconds"
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
            if code == "insufficient_credits" { return "ElevenLabs 额度不足，请查看账户剩余额度。" }
            if statusCode == 401 || statusCode == 403 { return "ElevenLabs API Key 无效，或该声音不允许通过 API 使用。" }
            if statusCode == 429 { return "ElevenLabs 请求过于频繁或额度不足。" }
            return "ElevenLabs 请求失败（HTTP \(statusCode)）。"
        }
    }
}

private enum ElevenLabsSpeechKeychain {
    private static let service = "EnglishReader.ElevenLabsSpeech"
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
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
