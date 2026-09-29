import AVFoundation
import Foundation

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
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentSpokenWordIndex: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterances: Set<ObjectIdentifier> = []
    private var childWords: [String] = []
    private var nextChildWordIndex = 0
    private var childWordPause = 1.0
    private var childAccent = EnglishAccent.american
    private var childSpeed = 0.45
    private var isChildSequenceActive = false
    private var pendingNextWord: DispatchWorkItem?
    private var normalText = ""
    private var normalWordOffset = 0
    private var isNormalSequenceActive = false
    private var normalBaseWordIndex = 0
    private var selectedVoiceIdentifier: String?
    private var wordAudioPlayer: AVPlayer?
    private var wordAudioTask: Task<Void, Never>?

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
        voiceIdentifier: String? = nil
    ) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        resetChildSequence()
        isNormalSequenceActive = false
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        isPaused = false
        currentSpokenWordIndex = nil
        selectedVoiceIdentifier = voiceIdentifier

        if childMode {
            childWords = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            nextChildWordIndex = 0
            childWordPause = wordPause
            childAccent = accent
            childSpeed = speed
            isChildSequenceActive = true
            speakNextChildWord()
        } else {
            startNormalSpeech(content, accent: accent, speed: speed, baseWordIndex: 0)
        }
    }

    func updatePlaybackSettings(accent: EnglishAccent, speed: Double, wordPause: Double, voiceIdentifier: String?) {
        guard isSpeaking else { return }
        selectedVoiceIdentifier = voiceIdentifier

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
            startNormalSpeech(remaining, accent: accent, speed: speed, baseWordIndex: baseWordIndex)
        }
    }

    func speakWord(_ word: String, accent: EnglishAccent, voiceIdentifier: String? = nil) {
        resetChildSequence()
        isNormalSequenceActive = false
        wordAudioTask?.cancel()
        wordAudioPlayer?.pause()
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        isPaused = false
        currentSpokenWordIndex = nil
        selectedVoiceIdentifier = voiceIdentifier
        let utterance = makeChildUtterance(
            word,
            followingWord: nil,
            accent: accent,
            speed: 0.42
        )
        activeUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    func togglePause() {
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

    func stop() {
        wordAudioTask?.cancel()
        wordAudioPlayer?.pause()
        resetChildSequence()
        isNormalSequenceActive = false
        activeUtterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        currentSpokenWordIndex = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.finish(utterance)
        }
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
        let utterance = AVSpeechUtterance(string: text)
        if let selectedVoiceIdentifier,
           let selected = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier),
           selected.language == accent.languageCode {
            utterance.voice = selected
        } else {
            let best = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language == accent.languageCode }
                .max { $0.quality.rawValue < $1.quality.rawValue }
            utterance.voice = best ?? AVSpeechSynthesisVoice(language: accent.languageCode)
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
                isNormalSequenceActive = false
                isSpeaking = false
                isPaused = false
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
        case "to": ipa = "tə"
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
            utterance.voice = AVSpeechSynthesisVoice(language: accent.languageCode)
        }
        utterance.rate = Float(speed)
        utterance.pitchMultiplier = 1.0
        return utterance
    }
}
