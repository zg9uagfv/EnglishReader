import AVFoundation
import Foundation
import KokoroSwift
import MLXUtilsLibrary
import SwiftUI

struct KokoroVoiceOption: Identifiable {
    let identifier: String
    let displayName: String

    var id: String { identifier }

    static let americanFemale = make("af", "美式女声", ["alloy", "aoede", "bella", "heart", "jessica", "kore", "nicole", "nova", "river", "sarah", "sky"])
    static let americanMale = make("am", "美式男声", ["adam", "echo", "eric", "fenrir", "liam", "michael", "onyx", "puck", "santa"])
    static let britishFemale = make("bf", "英式女声", ["alice", "emma", "isabella", "lily"])
    static let britishMale = make("bm", "英式男声", ["daniel", "fable", "george", "lewis"])

    private static func make(_ prefix: String, _ group: String, _ names: [String]) -> [KokoroVoiceOption] {
        names.map { name in
            KokoroVoiceOption(identifier: "\(prefix)_\(name)", displayName: "\(group) · \(name.capitalized)")
        }
    }
}

/// On-device Kokoro synthesis. Model files are intentionally kept outside the
/// app bundle so the 300+ MB model is not checked into the project.
final class KokoroSpeechEngine {
    private struct WordTiming: Sendable {
        let wordOffset: Int
        let startTime: Double
    }
    static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EnglishReader/Kokoro", isDirectory: true)
    }()

    @AppStorage("kokoroModelFile") private var configuredModelFile = ""
    @AppStorage("kokoroVoiceFile") private var configuredVoiceFile = ""
    @AppStorage("kokoroVoiceName") private var configuredVoiceName = "af_heart"

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var didFinish: (() -> Void)?
    private var didSpeakWord: ((Int) -> Void)?
    private var wordTimings: [WordTiming] = []
    private var progressTimer: DispatchSourceTimer?
    private var lastReportedWordOffset: Int?
    private var activeRequestID = UUID()

    var isPlaying: Bool { player.isPlaying }
    var isPaused = false

    init() {
        audioEngine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
    }

    var isInstalled: Bool {
        let paths = resourcePaths()
        return paths != nil
    }

    func speak(
        text: String,
        accent: EnglishAccent,
        speed: Double,
        didSpeakWord: @escaping (Int) -> Void,
        didFinish: @escaping () -> Void
    ) async throws {
        guard let paths = resourcePaths() else { throw KokoroSpeechError.resourcesMissing }
        let requestID = UUID()
        stopPlayback()
        activeRequestID = requestID
        self.didFinish = didFinish
        self.didSpeakWord = didSpeakWord

        let synthesis = try await Task.detached(priority: .userInitiated) {
            let tts = KokoroTTS(modelPath: paths.modelFile, g2p: .misaki)
            guard let voices = NpyzReader.read(fileFromPath: paths.voiceFile),
                  let voice = voices[paths.voiceName + ".npy"] else {
                throw KokoroSpeechError.voiceInvalid
            }
            let language: Language = accent == .american ? .enUS : .enGB
            let (samples, tokens) = try tts.generateAudio(
                voice: voice,
                language: language,
                text: text,
                speed: Float(speed / 0.45)
            )
            let timings = tokens?.compactMap { token -> WordTiming? in
                guard let startTime = token.start_ts else { return nil }
                let prefix = String(text[..<token.tokenRange.lowerBound])
                let wordOffset = prefix.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                return WordTiming(wordOffset: wordOffset, startTime: startTime)
            } ?? []
            return (samples, timings)
        }.value
        let samples = synthesis.0
        guard activeRequestID == requestID else { throw KokoroSpeechError.cancelled }
        wordTimings = synthesis.1

        // Timestamp prediction is available for the Misaki English pipeline.
        // Preserve a usable progress indicator if a future G2P token lacks it.
        if wordTimings.isEmpty {
            let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let duration = Double(samples.count) / 24_000
            let interval = duration / Double(max(1, wordCount))
            wordTimings = (0..<wordCount).map {
                WordTiming(wordOffset: $0, startTime: Double($0) * interval)
            }
        }

        guard !samples.isEmpty else { throw KokoroSpeechError.emptyAudio }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw KokoroSpeechError.audioBufferUnavailable
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try audioEngine.start()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.activeRequestID == requestID else { return }
                self.invalidateProgressTimer()
                self.isPaused = false
                let completion = self.didFinish
                self.didFinish = nil
                self.didSpeakWord = nil
                completion?()
            }
        }
        player.play()
        startProgressTimer()
        isPaused = false
    }

    func pause() {
        guard player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        player.play()
        isPaused = false
    }

    func stop() {
        activeRequestID = UUID()
        stopPlayback()
    }

    private func stopPlayback() {
        invalidateProgressTimer()
        player.stop()
        audioEngine.stop()
        isPaused = false
        didFinish = nil
        didSpeakWord = nil
        wordTimings = []
        lastReportedWordOffset = nil
    }

    private func startProgressTimer() {
        invalidateProgressTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(40), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.reportPlaybackProgress()
        }
        progressTimer = timer
        timer.resume()
    }

    private func invalidateProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func reportPlaybackProgress() {
        guard let nodeTime = player.lastRenderTime,
              let playbackTime = player.playerTime(forNodeTime: nodeTime) else { return }
        let seconds = Double(playbackTime.sampleTime) / playbackTime.sampleRate
        guard let timing = wordTimings.last(where: { $0.startTime <= seconds }),
              timing.wordOffset != lastReportedWordOffset else { return }
        lastReportedWordOffset = timing.wordOffset
        didSpeakWord?(timing.wordOffset)
    }

    private func resourcePaths() -> (modelFile: URL, voiceFile: URL, voiceName: String)? {
        let voiceName = configuredVoiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoiceName = voiceName.isEmpty ? "af_heart" : voiceName
        let modelSetting = configuredModelFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceSetting = configuredVoiceFile.trimmingCharacters(in: .whitespacesAndNewlines)

        if !modelSetting.isEmpty || !voiceSetting.isEmpty {
            guard !modelSetting.isEmpty, !voiceSetting.isEmpty else { return nil }
            let model = URL(fileURLWithPath: modelSetting)
            let voice = URL(fileURLWithPath: voiceSetting)
            guard FileManager.default.fileExists(atPath: model.path),
                  FileManager.default.fileExists(atPath: voice.path) else { return nil }
            return (model, voice, resolvedVoiceName)
        }

        let downloadedModel = Self.defaultDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
        let downloadedVoice = Self.defaultDirectory.appendingPathComponent("voices.npz")
        if FileManager.default.fileExists(atPath: downloadedModel.path),
           FileManager.default.fileExists(atPath: downloadedVoice.path) {
            return (downloadedModel, downloadedVoice, resolvedVoiceName)
        }

        guard let bundledModel = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors"),
              let bundledVoice = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            return nil
        }
        return (bundledModel, bundledVoice, resolvedVoiceName)
    }
}

enum KokoroSpeechError: LocalizedError {
    case resourcesMissing, voiceInvalid, emptyAudio, audioBufferUnavailable, cancelled

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: return "未安装 Kokoro 模型或音色文件。"
        case .voiceInvalid: return "Kokoro 音色文件无效。"
        case .emptyAudio: return "Kokoro 未生成音频。"
        case .audioBufferUnavailable: return "无法创建 Kokoro 音频缓冲区。"
        case .cancelled: return "Kokoro 朗读已取消。"
        }
    }
}
