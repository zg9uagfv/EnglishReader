import AVFoundation
import Foundation
import NaturalLanguage

enum EnglishAccent: String, CaseIterable, Identifiable {
    case american = "美式英语"
    case british = "英式英语"

    var id: Self { self }

    var languageCode: String {
        switch self {
        case .american: return "en-US"
        case .british: return "en-GB"
        }
    }
}

struct EnglishVoiceOption: Identifiable, Hashable {
    let identifier: String
    let name: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality

    var id: String { identifier }
    var displayName: String {
        let qualityName: String
        switch quality {
        case .premium: qualityName = "Premium"
        case .enhanced: qualityName = "Enhanced"
        default: qualityName = "标准"
        }
        return "\(name) · \(qualityName)"
    }

    static func available(for accent: EnglishAccent) -> [EnglishVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == accent.languageCode }
            .map { EnglishVoiceOption(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality) }
            .sorted {
                if qualityRank($0.quality) != qualityRank($1.quality) {
                    return qualityRank($0.quality) > qualityRank($1.quality)
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func preferred(for accent: EnglishAccent) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == accent.languageCode }
        return voices.max {
            if qualityRank($0.quality) != qualityRank($1.quality) {
                return qualityRank($0.quality) < qualityRank($1.quality)
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
        }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}

@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private static let pronounIPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])I(?![\p{L}\p{N}'’])"#
    )

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isReadingArticle = false
    @Published private(set) var currentSpokenWordIndex: Int?
    @Published private(set) var lastError: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterances: Set<ObjectIdentifier> = []
    private var childWords: [String] = []
    private var nextChildWordIndex = 0
    private var childWordPause = 1.0
    private var childAccent = EnglishAccent.american
    private var childSpeed = 0.45
    private var isChildSequenceActive = false
    private var isSystemChildReading = false
    private var pendingNextWord: DispatchWorkItem?
    private var normalText = ""
    private var normalWordOffset = 0
    private var isNormalSequenceActive = false
    private var normalBaseWordIndex = 0
    private var selectedVoiceIdentifier: String?
    private var elevenLabsSettings: ElevenLabsSpeechSettings?
    private var elevenLabsPlayer: AVAudioPlayer?
    private var elevenLabsTask: Task<Void, Never>?
    private var elevenLabsActiveChildSynthesisTask: Task<ElevenLabsSpeechService.TimedAudio, Error>?
    private var elevenLabsPrefetchTask: Task<ElevenLabsSpeechService.TimedAudio, Error>?
    private var elevenLabsPrefetchStartIndex: Int?
    private var elevenLabsProgressTask: Task<Void, Never>?
    private var elevenLabsWordStartTimes: [TimeInterval] = []
    private var elevenLabsChunkBaseWordIndex = 0
    private var elevenLabsRequestID = UUID()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        accent: EnglishAccent,
        speed: Double,
        childMode: Bool = false,
        wordPause: Double = 1.0,
        voiceIdentifier: String? = nil,
        elevenLabsSettings: ElevenLabsSpeechSettings? = nil
    ) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        resetChildSequence()
        isSystemChildReading = false
        isNormalSequenceActive = false
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        stopElevenLabsPlayback()
        isSpeaking = true
        isPaused = false
        isReadingArticle = true
        lastError = nil
        currentSpokenWordIndex = nil
        selectedVoiceIdentifier = voiceIdentifier
        self.elevenLabsSettings = elevenLabsSettings

        if childMode {
            childWords = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            nextChildWordIndex = 0
            childWordPause = wordPause
            childAccent = accent
            childSpeed = speed
            isChildSequenceActive = true
            if elevenLabsSettings != nil { startElevenLabsChildChunk() }
            else {
                resetChildSequence()
                isSystemChildReading = true
                startNormalSpeech(content, accent: accent, speed: min(speed, 0.4), baseWordIndex: 0)
            }
        } else {
            if let elevenLabsSettings { startElevenLabsSpeech(content, accent: accent, speed: speed, settings: elevenLabsSettings, baseWordIndex: 0) }
            else { startNormalSpeech(content, accent: accent, speed: speed, baseWordIndex: 0) }
        }
    }

    func updatePlaybackSettings(accent: EnglishAccent, speed: Double, wordPause: Double, voiceIdentifier: String?) {
        guard isSpeaking else { return }
        selectedVoiceIdentifier = voiceIdentifier
        if elevenLabsSettings != nil {
            if isChildSequenceActive {
                let speedChanged = childSpeed != speed
                childAccent = accent
                childSpeed = speed
                childWordPause = wordPause
                if speedChanged {
                    elevenLabsPrefetchTask?.cancel()
                    elevenLabsPrefetchTask = nil
                    elevenLabsPrefetchStartIndex = nil
                }
                if pendingNextWord != nil {
                    scheduleNextElevenLabsChildChunk()
                }
            }
            // Audio already returned by ElevenLabs cannot change synthesis speed.
            return
        }
        if isChildSequenceActive {
            childAccent = accent
            childSpeed = speed
            childWordPause = wordPause
            pendingNextWord?.cancel()
            pendingNextWord = nil

            if !activeUtterances.isEmpty {
                activeUtterances.removeAll()
                synthesizer.stopSpeaking(at: .immediate)
                nextChildWordIndex = max(0, nextChildWordIndex - 1)
                speakNextChildWord()
            } else if !isPaused {
                scheduleNextChildWord()
            }
        } else if isNormalSequenceActive {
            let source = normalText as NSString
            let offset = min(normalWordOffset, source.length)
            let remaining = source.substring(from: offset)
            let baseWordIndex = currentSpokenWordIndex ?? normalBaseWordIndex
            activeUtterances.removeAll()
            synthesizer.stopSpeaking(at: .immediate)
            startNormalSpeech(remaining, accent: accent,
                              speed: isSystemChildReading ? min(speed, 0.4) : speed,
                              baseWordIndex: baseWordIndex)
        }
    }

    func speakWord(_ word: String, accent: EnglishAccent, voiceIdentifier: String? = nil, elevenLabsSettings: ElevenLabsSpeechSettings? = nil) {
        resetChildSequence()
        isSystemChildReading = false
        isNormalSequenceActive = false
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        stopElevenLabsPlayback()
        isSpeaking = true
        isPaused = false
        isReadingArticle = false
        lastError = nil
        currentSpokenWordIndex = nil
        selectedVoiceIdentifier = voiceIdentifier
        self.elevenLabsSettings = elevenLabsSettings
        if let elevenLabsSettings {
            startElevenLabsSpeech(word, accent: accent, speed: 0.42, settings: elevenLabsSettings, baseWordIndex: 0)
            return
        }
        // 单词点读是词典式发音，使用标准强读；弱读只用于句中有上下文的儿童模式逐词朗读。
        let utterance = makeUtterance(word, accent: accent, speed: 0.42)
        activeUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    func togglePause() {
        if let elevenLabsPlayer {
            if elevenLabsPlayer.isPlaying {
                elevenLabsPlayer.pause()
                isPaused = true
            } else if isPaused {
                elevenLabsPlayer.play()
                isPaused = false
            }
            return
        }
        if isChildSequenceActive, elevenLabsSettings != nil {
            if isPaused {
                isPaused = false
                if elevenLabsTask == nil { scheduleNextElevenLabsChildChunk() }
            } else {
                pendingNextWord?.cancel()
                pendingNextWord = nil
                isPaused = true
            }
            return
        }
        if synthesizer.isPaused {
            if synthesizer.continueSpeaking() {
                isPaused = false
            }
        } else if isPaused, isChildSequenceActive, activeUtterances.isEmpty {
            isPaused = false
            scheduleNextChildWord()
        } else if synthesizer.isSpeaking {
            if synthesizer.pauseSpeaking(at: .immediate) {
                isPaused = true
            }
        } else if isChildSequenceActive, pendingNextWord != nil {
            pendingNextWord?.cancel()
            pendingNextWord = nil
            isPaused = true
        }
    }

    /// Restarts the current article at a word boundary so the reader can scrub
    /// through text progress without AVSpeechSynthesizer needing random access.
    func seek(
        toWordAt requestedIndex: Int,
        in text: String,
        accent: EnglishAccent,
        speed: Double,
        childMode: Bool,
        wordPause: Double,
        voiceIdentifier: String?,
        elevenLabsSettings: ElevenLabsSpeechSettings? = nil
    ) {
        let words = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        guard !words.isEmpty else { return }

        let index = min(max(0, requestedIndex), words.count - 1)
        resetChildSequence()
        isSystemChildReading = false
        isNormalSequenceActive = false
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        stopElevenLabsPlayback()
        isSpeaking = true
        isPaused = false
        isReadingArticle = true
        lastError = nil
        currentSpokenWordIndex = index
        selectedVoiceIdentifier = voiceIdentifier
        self.elevenLabsSettings = elevenLabsSettings

        if childMode {
            childWords = words
            nextChildWordIndex = index
            childWordPause = wordPause
            childAccent = accent
            childSpeed = speed
            isChildSequenceActive = true
            if elevenLabsSettings != nil { startElevenLabsChildChunk() }
            else {
                resetChildSequence()
                isSystemChildReading = true
                startNormalSpeech(words[index...].joined(separator: " "), accent: accent,
                                  speed: min(speed, 0.4), baseWordIndex: index)
            }
        } else {
            let content = words[index...].joined(separator: " ")
            if let elevenLabsSettings { startElevenLabsSpeech(content, accent: accent, speed: speed, settings: elevenLabsSettings, baseWordIndex: index) }
            else { startNormalSpeech(content, accent: accent, speed: speed, baseWordIndex: index) }
        }
    }

    func stop() {
        resetChildSequence()
        isSystemChildReading = false
        isNormalSequenceActive = false
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        stopElevenLabsPlayback()
        elevenLabsSettings = nil
        isSpeaking = false
        isPaused = false
        isReadingArticle = false
        currentSpokenWordIndex = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.finish(utterance)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === elevenLabsPlayer else { return }
        elevenLabsPlayer = nil
        finishElevenLabsPlayback()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.finish(utterance)
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async {
            guard self.isNormalSequenceActive,
                  self.activeUtterances.contains(ObjectIdentifier(utterance)) else { return }
            self.normalWordOffset = characterRange.location
            let source = self.normalText as NSString
            let safeLocation = min(characterRange.location, source.length)
            let prefix = source.substring(to: safeLocation)
            let precedingWords = prefix.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            self.currentSpokenWordIndex = self.normalBaseWordIndex + precedingWords
        }
    }

    private func makeUtterance(_ text: String, accent: EnglishAccent, speed: Double) -> AVSpeechUtterance {
        // Some system voices announce a standalone uppercase "I" as "capital I".
        // Annotate the pronoun in place so speech delegate ranges still match
        // the article text used for highlighting and seeking.
        let attributed = NSMutableAttributedString(string: text)
        let ipaKey = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
        for match in Self.pronounIPattern.matches(in: text, range: NSRange(location: 0, length: attributed.length)) {
            attributed.addAttribute(ipaKey, value: "aɪ", range: match.range)
        }
        let utterance = AVSpeechUtterance(attributedString: attributed)
        if let selectedVoiceIdentifier,
           let selected = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier),
           selected.language == accent.languageCode {
            utterance.voice = selected
        } else {
            utterance.voice = EnglishVoiceOption.preferred(for: accent)
                ?? AVSpeechSynthesisVoice(language: accent.languageCode)
        }
        utterance.rate = Float(speed)
        utterance.pitchMultiplier = 1.0
        return utterance
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        guard activeUtterances.remove(ObjectIdentifier(utterance)) != nil else { return }
        if activeUtterances.isEmpty {
            if isChildSequenceActive, nextChildWordIndex < childWords.count {
                scheduleNextChildWord()
            } else {
                resetChildSequence()
                isSystemChildReading = false
                isNormalSequenceActive = false
                isSpeaking = false
                isPaused = false
                isReadingArticle = false
                currentSpokenWordIndex = nil
            }
        }
    }

    private func speakNextChildWord() {
        pendingNextWord = nil
        guard isChildSequenceActive, !isPaused, nextChildWordIndex < childWords.count else { return }
        let word = childWords[nextChildWordIndex]
        let followingWord = nextChildWordIndex + 1 < childWords.count
            ? childWords[nextChildWordIndex + 1]
            : nil
        currentSpokenWordIndex = nextChildWordIndex
        nextChildWordIndex += 1
        let utterance = makeChildUtterance(
            word,
            followingWord: followingWord,
            accent: childAccent,
            speed: childSpeed
        )
        activeUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    private func scheduleNextChildWord() {
        pendingNextWord?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.speakNextChildWord()
        }
        pendingNextWord = work
        DispatchQueue.main.asyncAfter(deadline: .now() + childWordPause, execute: work)
    }

    private func startElevenLabsChildChunk() {
        guard isChildSequenceActive, !isPaused,
              let settings = elevenLabsSettings,
              nextChildWordIndex < childWords.count else { return }
        pendingNextWord = nil
        let start = nextChildWordIndex
        let end = childChunkEndIndex(startingAt: start)
        let words = Array(childWords[start..<end])
        let previousText = childChunkContext(before: start)
        let nextText = childChunkContext(after: end)
        nextChildWordIndex = end
        currentSpokenWordIndex = start
        let prefetched = elevenLabsPrefetchStartIndex == start ? elevenLabsPrefetchTask : nil
        if prefetched == nil { elevenLabsPrefetchTask?.cancel() }
        elevenLabsPrefetchTask = nil
        elevenLabsPrefetchStartIndex = nil
        stopElevenLabsPlayback(cancelPrefetch: false)
        elevenLabsActiveChildSynthesisTask = prefetched
        let requestID = UUID()
        elevenLabsRequestID = requestID
        elevenLabsTask = Task { [weak self] in
            do {
                let audio: ElevenLabsSpeechService.TimedAudio
                if let prefetched { audio = try await prefetched.value }
                else {
                    audio = try await ElevenLabsSpeechService.synthesizeChildWords(
                        words, speed: childSpeed, settings: settings,
                        previousText: previousText, nextText: nextText
                    )
                }
                guard !Task.isCancelled, let self, self.elevenLabsRequestID == requestID else { return }
                self.elevenLabsActiveChildSynthesisTask = nil
                let player = try AVAudioPlayer(data: audio.data)
                guard self.elevenLabsRequestID == requestID else { return }
                self.elevenLabsWordStartTimes = audio.wordStartTimes
                self.elevenLabsChunkBaseWordIndex = start
                player.delegate = self
                self.elevenLabsPlayer = player
                player.prepareToPlay()
                if !self.isPaused {
                    guard player.play() else { throw ElevenLabsSpeechError.invalidResponse }
                }
                self.startElevenLabsProgressTracking()
                self.prefetchNextElevenLabsChildChunk(settings: settings)
            } catch {
                guard !Task.isCancelled, let self, self.elevenLabsRequestID == requestID else { return }
                self.lastError = "\(error.localizedDescription) 已改用系统语音。"
                self.stopElevenLabsPlayback()
                self.elevenLabsSettings = nil
                let remaining = self.childWords[start...].joined(separator: " ")
                self.resetChildSequence()
                self.isSystemChildReading = true
                self.startNormalSpeech(remaining, accent: self.childAccent,
                                       speed: min(self.childSpeed, 0.4), baseWordIndex: start)
            }
        }
    }

    private func prefetchNextElevenLabsChildChunk(settings: ElevenLabsSpeechSettings) {
        guard nextChildWordIndex < childWords.count else { return }
        let start = nextChildWordIndex
        let end = childChunkEndIndex(startingAt: start)
        let words = Array(childWords[start..<end])
        let previousText = childChunkContext(before: start)
        let nextText = childChunkContext(after: end)
        let speed = childSpeed
        elevenLabsPrefetchStartIndex = start
        elevenLabsPrefetchTask = Task {
            try await ElevenLabsSpeechService.synthesizeChildWords(
                words, speed: speed, settings: settings,
                previousText: previousText, nextText: nextText
            )
        }
    }

    private func childChunkContext(before index: Int) -> String? {
        guard index > 0 else { return nil }
        return childWords[max(0, index - 8)..<index].joined(separator: " ")
    }

    private func childChunkContext(after index: Int) -> String? {
        guard index < childWords.count else { return nil }
        return childWords[index..<min(index + 8, childWords.count)].joined(separator: " ")
    }

    private func childChunkEndIndex(startingAt start: Int) -> Int {
        // Keep short sentences together so dialogue plays with natural prosody.
        let limit = min(start + 50, childWords.count)
        let candidate = childWords[start..<limit].joined(separator: " ")
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = candidate
        var wordCount = limit - start
        tokenizer.enumerateTokens(in: candidate.startIndex..<candidate.endIndex) { range, _ in
            let count = candidate[..<range.upperBound]
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            if count >= 25 { wordCount = count }
            return true
        }
        return start + max(1, wordCount)
    }

    private func scheduleNextElevenLabsChildChunk() {
        pendingNextWord?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startElevenLabsChildChunk()
        }
        pendingNextWord = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(2.0, childWordPause), execute: work)
    }

    private func startElevenLabsProgressTracking() {
        elevenLabsProgressTask?.cancel()
        elevenLabsProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.elevenLabsPlayer else { return }
                if player.isPlaying,
                   let index = self.elevenLabsWordStartTimes.lastIndex(where: { $0 <= player.currentTime }) {
                    let wordIndex = self.elevenLabsChunkBaseWordIndex + index
                    if self.currentSpokenWordIndex != wordIndex {
                        self.currentSpokenWordIndex = wordIndex
                    }
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func resetChildSequence() {
        pendingNextWord?.cancel()
        pendingNextWord = nil
        childWords.removeAll()
        nextChildWordIndex = 0
        isChildSequenceActive = false
    }

    private func startNormalSpeech(
        _ text: String,
        accent: EnglishAccent,
        speed: Double,
        baseWordIndex: Int
    ) {
        normalText = text
        normalWordOffset = 0
        normalBaseWordIndex = baseWordIndex
        isNormalSequenceActive = true
        let utterance = makeUtterance(text, accent: accent, speed: speed)
        utterance.preUtteranceDelay = 0.05
        activeUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    private func startElevenLabsSpeech(
        _ text: String,
        accent: EnglishAccent,
        speed: Double,
        settings: ElevenLabsSpeechSettings,
        baseWordIndex: Int
    ) {
        stopElevenLabsPlayback()
        let requestID = UUID()
        elevenLabsRequestID = requestID
        isNormalSequenceActive = !isChildSequenceActive
        elevenLabsTask = Task { [weak self] in
            do {
                let data = try await ElevenLabsSpeechService.synthesize(text: text, speed: speed, settings: settings)
                guard !Task.isCancelled, let self, self.elevenLabsRequestID == requestID else { return }
                let player = try AVAudioPlayer(data: data)
                guard self.elevenLabsRequestID == requestID else { return }
                player.delegate = self
                self.elevenLabsPlayer = player
                player.prepareToPlay()
                guard player.play() else { throw ElevenLabsSpeechError.invalidResponse }
            } catch {
                guard !Task.isCancelled, let self, self.elevenLabsRequestID == requestID else { return }
                self.lastError = "\(error.localizedDescription) 已改用系统语音。"
                self.stopElevenLabsPlayback()
                self.elevenLabsSettings = nil
                self.startNormalSpeech(text, accent: accent, speed: speed, baseWordIndex: baseWordIndex)
            }
        }
    }

    private func finishElevenLabsPlayback() {
        elevenLabsTask = nil
        elevenLabsProgressTask?.cancel()
        elevenLabsProgressTask = nil
        if isChildSequenceActive, nextChildWordIndex < childWords.count {
            currentSpokenWordIndex = nextChildWordIndex - 1
            scheduleNextElevenLabsChildChunk()
            return
        }
        resetChildSequence()
        isNormalSequenceActive = false
        isSpeaking = false
        isPaused = false
        isReadingArticle = false
        currentSpokenWordIndex = nil
    }

    private func stopElevenLabsPlayback(cancelPrefetch: Bool = true) {
        elevenLabsRequestID = UUID()
        elevenLabsTask?.cancel()
        elevenLabsTask = nil
        elevenLabsActiveChildSynthesisTask?.cancel()
        elevenLabsActiveChildSynthesisTask = nil
        if cancelPrefetch {
            elevenLabsPrefetchTask?.cancel()
            elevenLabsPrefetchTask = nil
            elevenLabsPrefetchStartIndex = nil
        }
        elevenLabsProgressTask?.cancel()
        elevenLabsProgressTask = nil
        elevenLabsWordStartTimes = []
        elevenLabsPlayer?.delegate = nil
        elevenLabsPlayer?.stop()
        elevenLabsPlayer = nil
    }

    private func makeChildUtterance(
        _ word: String,
        followingWord: String?,
        accent: EnglishAccent,
        speed: Double
    ) -> AVSpeechUtterance {
        let cleaned = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let nextStartsWithVowel = followingWord?
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .first
            .map { "aeiou".contains($0) } ?? false

        let ipa: String?
        switch cleaned {
        case "a": ipa = "ə"
        case "an": ipa = "ən"
        case "the": ipa = nextStartsWithVowel ? "ði" : "ðə"
        // Do not attach an IPA annotation to "to". Some macOS voices parse
        // /tuː/ with an added /j/ glide, making the standalone word sound
        // like “to you”. The system's native dictionary pronunciation is
        // correct for an isolated word.
        case "to": ipa = nil
        case "of": ipa = "əv"
        case "and": ipa = "ənd"
        case "for": ipa = accent == .british ? "fə" : "fɚ"
        case "at": ipa = "ət"
        case "can": ipa = "kən"
        case "as": ipa = "əz"
        default: ipa = nil
        }

        guard let ipa else {
            return makeUtterance(word, accent: accent, speed: speed)
        }

        let ipaKey = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
        let attributed = NSAttributedString(string: cleaned, attributes: [ipaKey: ipa])
        let utterance = AVSpeechUtterance(attributedString: attributed)
        if let selectedVoiceIdentifier,
           let selected = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier),
           selected.language == accent.languageCode {
            utterance.voice = selected
        } else {
            utterance.voice = EnglishVoiceOption.preferred(for: accent)
                ?? AVSpeechSynthesisVoice(language: accent.languageCode)
        }
        utterance.rate = Float(speed)
        utterance.pitchMultiplier = 1.0
        return utterance
    }
}
