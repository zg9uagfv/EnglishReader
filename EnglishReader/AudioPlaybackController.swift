import AVFoundation
import Foundation
import Speech

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var fileName = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRate: Float = 1.0
    @Published private(set) var currentSpokenWordIndex: Int?
    @Published private(set) var transcriptionText = ""
    @Published private(set) var transcriptionStatus: String?
    @Published private(set) var isTranscribing = false

    private struct TimedWord {
        let text: String
        let startTime: Double
        let duration: Double
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationObserver: NSKeyValueObservation?
    private var scopedURL: URL?
    private var transcriptionTask: SFSpeechRecognitionTask?
    private var timedWords: [TimedWord] = []
    private var isSeeking = false

    var hasAudio: Bool { player != nil }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        transcriptionTask?.cancel()
    }

    func load(url: URL, localeIdentifier: String, playbackRate: Float, shouldTranscribe: Bool = true) {
        stopAndReleaseFile()
        let hasAccess = url.startAccessingSecurityScopedResource()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        scopedURL = hasAccess ? url : nil
        fileName = url.deletingPathExtension().lastPathComponent
        currentTime = 0
        duration = 0
        currentSpokenWordIndex = nil
        transcriptionText = ""
        transcriptionStatus = shouldTranscribe ? "正在识别音频内容…" : nil
        isTranscribing = shouldTranscribe
        self.playbackRate = playbackRate
        observe(player: player, item: item)
        if shouldTranscribe { transcribe(url: url, localeIdentifier: localeIdentifier) }
    }

    func startSystemTranscription(url: URL, localeIdentifier: String) {
        transcriptionStatus = "正在使用系统语音识别…"
        isTranscribing = true
        transcribe(url: url, localeIdentifier: localeIdentifier)
    }

    func beginTranscription(status: String) {
        transcriptionStatus = status
        isTranscribing = true
    }

    func finishTranscription(status: String?) {
        transcriptionStatus = status
        isTranscribing = false
    }

    func apply(transcription: LLMTranscription) {
        transcriptionTask?.cancel()
        timedWords = normalizedTimedWords(transcription.words.map {
            TimedWord(text: $0.text, startTime: $0.start, duration: max(0.01, $0.end - $0.start))
        })
        transcriptionText = timedWords.isEmpty ? EnglishTextFormatter.formatArticle(transcription.text) : alignedText(from: timedWords)
        transcriptionStatus = nil
        isTranscribing = false
        updateCurrentWordIndex()
    }

    func unload() {
        stopAndReleaseFile()
        fileName = ""
        duration = 0
        currentTime = 0
        currentSpokenWordIndex = nil
        transcriptionText = ""
        transcriptionStatus = nil
        isTranscribing = false
    }

    func togglePlayback() {
        guard !isTranscribing, let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    func seek(to seconds: Double) {
        guard !isTranscribing, let player else { return }
        let target = min(max(0, seconds), duration)
        isSeeking = true
        currentTime = target
        updateCurrentWordIndex()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                self.currentTime = target
                self.updateCurrentWordIndex()
            }
        }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func transcribe(url: URL, localeIdentifier: String) {
        transcriptionTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            let status = await Self.requestSpeechAuthorization()
            guard status == .authorized else {
                self.transcriptionStatus = "需要允许“语音识别”权限，才能显示音频文本。"
                self.isTranscribing = false
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
                self.transcriptionStatus = "当前设备暂时无法进行音频识别。"
                self.isTranscribing = false
                return
            }

            let asset = AVURLAsset(url: url)
            let totalDuration = asset.duration.seconds
            guard totalDuration.isFinite, totalDuration > 0 else {
                self.transcriptionStatus = "无法读取音频时长。"
                self.isTranscribing = false
                return
            }

            let chunkLength = 55.0
            let chunkCount = Int(ceil(totalDuration / chunkLength))
            var allWords: [TimedWord] = []

            do {
                for chunkIndex in 0..<chunkCount {
                    guard !Task.isCancelled else { return }
                    let start = Double(chunkIndex) * chunkLength
                    let length = min(chunkLength, totalDuration - start)
                    self.transcriptionStatus = "正在识别第 \(chunkIndex + 1)/\(chunkCount) 段音频…"
                    let chunkURL = try await self.exportChunk(from: asset, start: start, duration: length)
                    defer { try? FileManager.default.removeItem(at: chunkURL) }

                    let transcription = try await self.recognize(chunkURL, with: recognizer)
                    allWords.append(contentsOf: transcription.segments.map {
                        TimedWord(text: $0.substring, startTime: start + $0.timestamp, duration: $0.duration)
                    })
                    // A Speech segment can contain more than one visible word. Normalize
                    // timestamps to the exact whitespace tokens used by the reader.
                    self.timedWords = self.normalizedTimedWords(allWords)
                    self.transcriptionText = self.alignedText(from: self.timedWords)
                    self.updateCurrentWordIndex()
                }
                self.transcriptionStatus = nil
                self.isTranscribing = false
            } catch {
                self.transcriptionStatus = "音频识别失败：\(error.localizedDescription)"
                self.isTranscribing = false
            }
        }
    }

    private func exportChunk(from asset: AVAsset, start: Double, duration: Double) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioTranscriptionError.exportUnavailable
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw exporter.error ?? AudioTranscriptionError.exportFailed
        }
        return outputURL
    }

    private func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> SFTranscription {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            var isFinished = false
            transcriptionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !isFinished else { return }
                if let result, result.isFinal {
                    isFinished = true
                    continuation.resume(returning: result.bestTranscription)
                } else if let error {
                    isFinished = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            Task { @MainActor [weak self] in self?.duration = seconds }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let itemDuration = item.duration.seconds
            let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isSeeking else { return }
                self.currentTime = seconds
                if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                self.updateCurrentWordIndex()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
                self.updateCurrentWordIndex()
                player.seek(to: .zero)
            }
        }
    }

    private func updateCurrentWordIndex() {
        guard !timedWords.isEmpty else { currentSpokenWordIndex = nil; return }
        currentSpokenWordIndex = timedWords.lastIndex { $0.startTime <= currentTime + 0.05 } ?? 0
    }

    /// The reading view indexes words by whitespace, so its words must have the
    /// same count and ordering as the timestamped audio words.
    private func normalizedTimedWords(_ source: [TimedWord]) -> [TimedWord] {
        source.flatMap { item -> [TimedWord] in
            let tokens = item.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard !tokens.isEmpty else { return [] }
            let tokenDuration = max(0.01, item.duration / Double(tokens.count))
            return tokens.enumerated().map { offset, token in
                TimedWord(
                    text: String(token),
                    startTime: item.startTime + Double(offset) * tokenDuration,
                    duration: tokenDuration
                )
            }
        }
    }

    private func alignedText(from words: [TimedWord]) -> String {
        guard !words.isEmpty else { return "" }

        var output = words[0].text
        for index in words.indices.dropFirst() {
            let previous = words[index - 1]
            let word = words[index]
            let pause = word.startTime - (previous.startTime + previous.duration)
            output += (pause > 1.1 ? "\n\n" : " ") + word.text
        }
        return output
    }

    private func stopAndReleaseFile() {
        player?.pause()
        transcriptionTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        player = nil
        timeObserver = nil
        endObserver = nil
        durationObserver = nil
        scopedURL = nil
        transcriptionTask = nil
        timedWords = []
        isPlaying = false
        isTranscribing = false
    }
}

private enum AudioTranscriptionError: LocalizedError {
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .exportUnavailable: return "当前设备无法分段处理该音频。"
        case .exportFailed: return "音频分段处理失败。"
        }
    }
}
