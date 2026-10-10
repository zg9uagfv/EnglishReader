import SwiftUI
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

struct ContentView: View {
    @StateObject private var speech = SpeechController()
    @StateObject private var audio = AudioPlaybackController()
    @StateObject private var llmConfiguration = LLMConfiguration()
    @State private var text = ""
    @State private var accent: EnglishAccent = .american
    @State private var speed = 0.45
    @State private var settingsUpdateTask: Task<Void, Never>?
    @State private var childMode = false
    @State private var wordPause = 1.0
    @State private var fontSize = 20.0
    @State private var fontStyle = DisplayFontStyle.system
    @State private var highlightedTokens: Set<String> = []
    @State private var selectedVoiceIdentifier = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isEditingText = true
    @State private var audioTranscriptText = ""
    @State private var selectedWord: WordSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isScrubbingReadingProgress = false
    @State private var pendingReadingWordIndex = 0.0
    @State private var isAudioProgressVisible = true
    @State private var audioPlaybackRate = 1.0
    @State private var audioPlaybackRateInput = "1.0"
    @AppStorage("showsChineseTranslation") private var showsChineseTranslation = false
    @State private var chineseTranslations: [Int: String] = [:]
    @State private var isTranslating = false
    @State private var translationStatus = ""
    @State private var translationError: String?
    @State private var translationTask: Task<Void, Never>?
    @State private var appleTranslationPassages: [String] = []
    @State private var appleTranslationRequestID = UUID()
    @FocusState private var isAudioPlaybackRateFocused: Bool

    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PreferencesView(
                llmConfiguration: llmConfiguration,
                accent: $accent,
                selectedVoiceIdentifier: $selectedVoiceIdentifier,
                speed: $speed,
                childMode: $childMode,
                wordPause: $wordPause,
                fontStyle: $fontStyle,
                fontSize: $fontSize
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            NavigationStack {
                ZStack {
                    ReaderTheme.canvas.ignoresSafeArea()
                    VStack(spacing: 20) {
                        header
                        translationOption
                        if isEditingText {
                            editor
                        } else {
                            readingView
                        }
                        controls
                    }
                    .padding(24)
                }
            .onChange(of: accent) { _ in
                if !EnglishVoiceOption.available(for: accent).contains(where: { $0.identifier == selectedVoiceIdentifier }) {
                    selectedVoiceIdentifier = ""
                }
                applyLiveSettings(debounced: false)
            }
            .onChange(of: selectedVoiceIdentifier) { _ in
                applyLiveSettings(debounced: false)
            }
            .onChange(of: speed) { _ in
                applyLiveSettings(debounced: true)
            }
            .onChange(of: audioPlaybackRate) { value in
                audio.setPlaybackRate(Float(value))
                if !isAudioPlaybackRateFocused {
                    audioPlaybackRateInput = String(format: "%.1f", value)
                }
            }
            .onChange(of: wordPause) { _ in
                applyLiveSettings(debounced: true)
            }
            .onChange(of: childMode) { enabled in
                if enabled && audio.isPlaying {
                    audio.pause()
                }
            }
            .onChange(of: speech.isSpeaking) { isSpeaking in
                // The system synthesizer clears its active word when the final
                // utterance completes. Reset the slider's stored
                // position too, so a finished article visibly returns home.
                if !isSpeaking {
                    isScrubbingReadingProgress = false
                    pendingReadingWordIndex = 0
                }
            }
            .onChange(of: audio.transcriptionText) { transcription in
                guard !transcription.isEmpty else { return }
                let formattedTranscript = EnglishTextFormatter.formatArticle(transcription)
                audioTranscriptText = formattedTranscript
                text = formattedTranscript
                isEditingText = false
            }
            .onChange(of: text) { updatedText in
                scheduleTranslation(for: updatedText)
                guard isEditingText,
                      audio.hasAudio,
                      updatedText != audioTranscriptText else { return }
                // The source text has diverged from the audio transcript. Keeping
                // the old player here would make the play button use stale audio.
                audio.unload()
                speech.stop()
            }
            .onChange(of: showsChineseTranslation) { enabled in
                if enabled { scheduleTranslation(for: text, immediately: true) }
                else {
                    translationTask?.cancel()
                    isTranslating = false
                    translationStatus = ""
                    translationError = nil
                }
            }
            .background {
                appleTranslationRunner
            }
            .navigationTitle("英文文章朗读")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false,
                onCompletion: importFile
            )
            .alert("无法读取文件", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ReaderTheme.primary)
        // This reader uses a deliberately light paper-like canvas. Keeping the
        // complete split view in light appearance prevents macOS Form labels
        // from becoming white against that canvas.
        .preferredColorScheme(.light)
    }

    private var header: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 720
            Group {
                if isCompact {
                    HStack(spacing: 12) {
                        headerIcon
                        headerCompactText
                        Spacer(minLength: 4)
                        headerCompactActions
                    }
                } else {
                    HStack(spacing: 16) {
                        headerIcon
                        headerText
                        Spacer(minLength: 8)
                        headerActions
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.9), lineWidth: 1)
            }
            .shadow(color: ReaderTheme.primary.opacity(0.10), radius: 14, y: 6)
        }
        .frame(height: 84)
    }

    private var headerIcon: some View {
        Image(systemName: childMode ? "figure.and.child.holdinghands" : "book.closed.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(ReaderTheme.heroGradient, in: Circle())
            .shadow(color: ReaderTheme.primary.opacity(0.25), radius: 8, y: 4)
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(childMode ? "一起读英语吧！" : "英语阅读小伙伴")
                .font(.title3.weight(.bold))
            Text("粘贴内容，或选择文本、Markdown、音频文件")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(wordCount) 个单词 · \(childMode ? "儿童逐词模式" : "自由阅读模式")")
                .font(.caption.weight(.medium))
                .foregroundStyle(ReaderTheme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerCompactText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(childMode ? "一起读英语吧！" : "英语阅读小伙伴")
                .font(.headline)
                .lineLimit(1)
            Text("\(wordCount) 个单词 · \(childMode ? "儿童逐词模式" : "自由阅读模式")")
                .font(.caption.weight(.medium))
                .foregroundStyle(ReaderTheme.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { headerPrimaryAction; headerSecondaryActions }
            VStack(alignment: .leading, spacing: 8) {
                headerPrimaryAction
                headerSecondaryActions
            }
        }
    }

    private var headerCompactActions: some View {
        Menu {
            Button {
                if isEditingText { text = EnglishTextFormatter.formatArticle(text) }
                isEditingText.toggle()
            } label: {
                Label(isEditingText ? "进入阅读" : "编辑文本", systemImage: isEditingText ? "play.circle.fill" : "square.and.pencil")
            }

            Button { isImporting = true } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
            }

            Button { text = EnglishTextFormatter.formatArticle(text) } label: {
                Label("自动排版", systemImage: "text.alignleft")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(ReaderFilledButtonStyle())
        .accessibilityLabel("文章操作")
    }

    private var headerPrimaryAction: some View {
        Button {
            if isEditingText { text = EnglishTextFormatter.formatArticle(text) }
            isEditingText.toggle()
        } label: {
            Label(isEditingText ? "进入阅读" : "编辑文本", systemImage: isEditingText ? "play.circle.fill" : "square.and.pencil")
        }
        .buttonStyle(ReaderFilledButtonStyle())
    }

    private var headerSecondaryActions: some View {
        HStack(spacing: 8) {
            Button { isImporting = true } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
            }
            .buttonStyle(ReaderOutlinedButtonStyle())

            Button { text = EnglishTextFormatter.formatArticle(text) } label: {
                Label("自动排版", systemImage: "text.alignleft")
            }
            .buttonStyle(ReaderOutlinedButtonStyle())
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize, design: fontStyle.design))
            .lineSpacing(max(2, fontSize * 0.22))
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ReaderTheme.primary.opacity(0.14), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var translationOption: some View {
        HStack(spacing: 10) {
            Toggle("显示中文翻译", isOn: Binding(
                get: { showsChineseTranslation },
                set: { enabled in
                    showsChineseTranslation = enabled
                    if enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = EnglishTextFormatter.formatArticle(text)
                        isEditingText = false
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.subheadline.weight(.semibold))

            Text(showsChineseTranslation ? "已开启：使用苹果本地翻译，中文显示在英文下方" : "勾选后立即在本机翻译并显示中英对照")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ReaderTheme.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private var readingView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                readingContent
            }
            .onChange(of: activeSpokenWordIndex) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("spoken-word-\(index)", anchor: .center)
                }
            }
        }
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ReaderTheme.primary.opacity(0.14), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var readingContent: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed").font(.largeTitle).foregroundStyle(.secondary)
                Text("没有文章").font(.headline)
                Text("请切换到编辑模式输入内容或选择文件").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: max(12, fontSize * 0.65)) {
                ForEach(formattedSentences.indices, id: \.self) { sentenceIndex in
                    let sentence = formattedSentences[sentenceIndex]
                    let tokens = tokens(for: sentence)
                    let sentenceOffset = tokenOffset(for: sentenceIndex)
                    VStack(alignment: .leading, spacing: 6) {
                        WrappingLayout(spacing: max(3, fontSize * 0.18)) {
                            ForEach(tokens.indices, id: \.self) { tokenIndex in
                                readingTokenView(
                                    tokens[tokenIndex],
                                    id: "\(sentenceIndex)-\(tokenIndex)",
                                    wordIndex: sentenceOffset + tokenIndex,
                                    isSentenceStart: tokenIndex == 0
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if showsChineseTranslation, let translation = chineseTranslations[sentenceIndex] {
                            Text(translation)
                                .font(.system(size: max(14, fontSize * 0.82), design: fontStyle.design))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsChineseTranslation && isTranslating {
                    Label(translationStatus.isEmpty ? "正在翻译中文…" : translationStatus, systemImage: "character.book.closed")
                        .font(.callout)
                        .foregroundStyle(ReaderTheme.primary)
                } else if showsChineseTranslation, let translationError {
                    HStack(spacing: 10) {
                        Label(translationError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button("重试") {
                            scheduleTranslation(for: text, immediately: true)
                        }
                        .buttonStyle(ReaderOutlinedButtonStyle())
                    }
                }
            }
            .padding(16)
        }
    }

    private func readingTokenView(_ token: ReadingToken, id: String, wordIndex: Int, isSentenceStart: Bool) -> some View {
        let word = token.lookupWord
        let isCurrentlySpoken = activeSpokenWordIndex == wordIndex
        let hasBeenRead = (activeSpokenWordIndex ?? -1) >= wordIndex
        return Text(token.display)
            .font(.system(size: fontSize, design: fontStyle.design))
            .fontWeight(isCurrentlySpoken ? .bold : .regular)
            .foregroundStyle(hasBeenRead ? Color.blue : Color.primary)
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .background(
                isCurrentlySpoken
                    ? Color.green.opacity(0.60)
                    : (highlightedTokens.contains(id) ? Color.yellow.opacity(0.65) : Color.clear),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .scaleEffect(isCurrentlySpoken ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isCurrentlySpoken)
            .id("spoken-word-\(wordIndex)")
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { gesture in
                        switch gesture {
                        case .first(_):
                            // 双击始终是查词，包括句首的第一个单词。
                            guard let word else { return }
                            selectedWord = WordSelection(id: id, word: word)
                        case .second(_):
                            // 单击句首：从本句开头朗读并同步进度条；
                            // 单击其他单词：切换高亮。
                            if isSentenceStart {
                                readSentenceFromStart(at: wordIndex)
                            } else {
                                guard word != nil else { return }
                                if highlightedTokens.contains(id) {
                                    highlightedTokens.remove(id)
                                } else {
                                    highlightedTokens.insert(id)
                                }
                            }
                        }
                    }
            )
            .popover(item: wordSelectionBinding(for: id), arrowEdge: .bottom) { selection in
                WordDetailView(word: selection.word, accent: accent) {
                    speech.speakWord(selection.word, accent: accent, voiceIdentifier: selectedVoice)
                }
            }
            .help(tokenHelp(isSentenceStart: isSentenceStart, canLookUp: word != nil))
    }

    private func tokenHelp(isSentenceStart: Bool, canLookUp: Bool) -> String {
        guard canLookUp || isSentenceStart else { return "" }
        if isSentenceStart {
            return canLookUp ? "单击从本句开头朗读，双击查看音标和词义" : "单击从本句开头朗读"
        }
        return "双击查看音标和词义，单击高亮"
    }

    /// 单击句首单词：从该句的第一个词开始（或跳转继续）朗读，并把进度条同步到句首。
    private func readSentenceFromStart(at wordIndex: Int) {
        pendingReadingWordIndex = Double(wordIndex)
        if audio.hasAudio {
            audio.seek(toWordAt: wordIndex)
        } else {
            seekTextReading(to: wordIndex)
        }
    }

    private func wordSelectionBinding(for tokenID: String) -> Binding<WordSelection?> {
        Binding(
            get: { selectedWord?.id == tokenID ? selectedWord : nil },
            set: { selection in
                if selection == nil, selectedWord?.id == tokenID {
                    selectedWord = nil
                }
            }
        )
    }

    private var formattedSentences: [String] {
        EnglishTextFormatter.sentences(in: text)
    }

    private func tokens(for sentence: String) -> [ReadingToken] {
        sentence.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map(ReadingToken.init)
    }

    private func tokenOffset(for sentenceIndex: Int) -> Int {
        guard sentenceIndex > 0 else { return 0 }
        return formattedSentences[..<sentenceIndex].reduce(0) { total, sentence in
            total + tokens(for: sentence).count
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if audio.hasAudio {
                audioControls
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readingProgress
                ttsControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readingProgress: some View {
        let completedWords = min(
            max(0, speech.isSpeaking ? (activeSpokenWordIndex ?? -1) + 1 : Int(pendingReadingWordIndex.rounded())),
            wordCount
        )
        let maximumWordIndex = max(0, wordCount - 1)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("文章朗读进度", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(completedWords) / \(wordCount) 词")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if wordCount > 1 {
                Slider(
                    value: Binding(
                        get: {
                            if isScrubbingReadingProgress { return pendingReadingWordIndex }
                            if speech.isSpeaking {
                                return Double(min(maximumWordIndex, activeSpokenWordIndex ?? 0))
                            }
                            return min(Double(maximumWordIndex), pendingReadingWordIndex)
                        },
                        set: { pendingReadingWordIndex = $0 }
                    ),
                    in: 0...Double(maximumWordIndex),
                    step: 1,
                    onEditingChanged: { isEditing in
                        isScrubbingReadingProgress = isEditing
                        if isEditing {
                            pendingReadingWordIndex = Double(min(maximumWordIndex, activeSpokenWordIndex ?? 0))
                        } else if speech.isSpeaking {
                            seekTextReading(to: Int(pendingReadingWordIndex.rounded()))
                        }
                    }
                )
                .tint(.accentColor)
                .accessibilityValue("已定位到第 \(completedWords) 个词，共 \(wordCount) 个单词；拖动后从目标位置开始或继续朗读")
            }
        }
        .padding(14)
        .background(ReaderTheme.sunshine.opacity(0.20), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var ttsControls: some View {
        HStack(spacing: 12) {
            Button {
                if speech.isSpeaking {
                    speech.stop()
                } else {
                    isEditingText = false
                    startTextReading()
                }
            } label: {
                Label(
                    speech.isSpeaking ? "关闭阅读" : "开始阅读",
                    systemImage: speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                    .frame(minWidth: 110)
            }
            .buttonStyle(ReaderFilledButtonStyle(color: speech.isSpeaking ? .red : ReaderTheme.primary))
            .disabled(!speech.isSpeaking && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                speech.togglePause()
            } label: {
                Label(speech.isPaused ? "继续" : "暂停", systemImage: speech.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(ReaderOutlinedButtonStyle())
            .disabled(!speech.isSpeaking)

        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audio.fileName).font(.headline).lineLimit(1)
                        Text(audio.transcriptionStatus ?? "已识别音频文本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAudioProgressVisible.toggle()
                    }
                }
                .help(isAudioProgressVisible ? "点击隐藏播放进度" : "点击显示播放进度")

                TextField("倍率", text: $audioPlaybackRateInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
                    .focused($isAudioPlaybackRateFocused)
                    .onChange(of: audioPlaybackRateInput) { input in
                        updateAudioPlaybackRateInput(input)
                    }
                    .onChange(of: isAudioPlaybackRateFocused) { isFocused in
                        if !isFocused { commitAudioPlaybackRateInput() }
                    }
                    .onSubmit { commitAudioPlaybackRateInput() }
                    .accessibilityLabel("音频播放倍率，范围 0.1 到 4")
                Text("×")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            if audio.isTranscribing {
                ProgressView()
                    .progressViewStyle(.linear)
                Label("模型正在处理音频，完成后会自动整理为段落。", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isAudioProgressVisible {
                Slider(
                    value: Binding(
                        get: { audio.currentTime },
                        set: { audio.seek(to: $0) }
                    ),
                    in: 0...max(audio.duration, 0.01)
                )
                .tint(.accentColor)
                .disabled(audio.isTranscribing)

                HStack {
                    Text(audio.formattedTime(audio.currentTime)).monospacedDigit()
                    Spacer()
                    Text(audio.formattedTime(audio.duration)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button { audio.togglePlayback() } label: {
                Label(audio.isPlaying ? "暂停音频" : "播放音频", systemImage: audio.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(ReaderFilledButtonStyle())
            .disabled(audio.isTranscribing)
        }
        .padding(16)
        .background(ReaderTheme.mint.opacity(0.27), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ReaderTheme.mint.opacity(0.65), lineWidth: 1)
        }
    }

    private func applyLiveSettings(debounced: Bool) {
        guard speech.isSpeaking else { return }
        settingsUpdateTask?.cancel()
        let delay: UInt64 = debounced ? 220_000_000 : 0
        settingsUpdateTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            speech.updatePlaybackSettings(
                accent: accent,
                speed: speed,
                wordPause: wordPause,
                voiceIdentifier: selectedVoice
            )
        }
    }

    private func startTextReading() {
        if pendingReadingWordIndex.rounded() > 0 {
            seekTextReading(to: Int(pendingReadingWordIndex.rounded()))
        } else {
            speech.speak(
                text,
                accent: accent,
                speed: speed,
                childMode: childMode,
                wordPause: wordPause,
                voiceIdentifier: selectedVoice
            )
        }
    }

    private func seekTextReading(to wordIndex: Int) {
        speech.seek(
            toWordAt: wordIndex,
            in: text,
            accent: accent,
            speed: speed,
            childMode: childMode,
            wordPause: wordPause,
            voiceIdentifier: selectedVoice
        )
    }

    private func updateAudioPlaybackRateInput(_ input: String) {
        let sanitized = sanitizedAudioPlaybackRateInput(input)
        if sanitized != input {
            audioPlaybackRateInput = sanitized
            return
        }
        guard let rate = Double(sanitized), (0.1...4.0).contains(rate) else { return }
        audioPlaybackRate = rate
    }

    private func commitAudioPlaybackRateInput() {
        let rate = Double(audioPlaybackRateInput) ?? audioPlaybackRate
        audioPlaybackRate = min(4.0, max(0.1, rate))
        audioPlaybackRateInput = String(format: "%.1f", audioPlaybackRate)
    }

    private func sanitizedAudioPlaybackRateInput(_ input: String) -> String {
        var result = ""
        var hasDecimalSeparator = false
        var decimalDigitCount = 0

        for character in input {
            if character.isWholeNumber {
                if hasDecimalSeparator {
                    guard decimalDigitCount < 1 else { continue }
                    result.append(character)
                    decimalDigitCount += 1
                } else {
                    // The allowed range never needs more than one integer digit.
                    guard result.isEmpty, character <= "4" else { continue }
                    result.append(character)
                }
            } else if character == ".", !hasDecimalSeparator {
                if result.isEmpty { result = "0" }
                result.append(character)
                hasDecimalSeparator = true
            }
        }
        return result
    }

    private var selectedVoice: String? {
        selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
    }

    private var activeSpokenWordIndex: Int? {
        if speech.isSpeaking { return speech.currentSpokenWordIndex }
        return audio.hasAudio ? audio.currentSpokenWordIndex : nil
    }

    private func scheduleTranslation(for sourceText: String, immediately: Bool = false) {
        translationTask?.cancel()
        guard showsChineseTranslation else { return }
        let passages = EnglishTextFormatter.sentences(in: sourceText)
        chineseTranslations = [:]
        guard !passages.isEmpty else {
            chineseTranslations = [:]
            translationError = nil
            isTranslating = false
            translationStatus = ""
            return
        }
        translationTask = Task { @MainActor in
            if !immediately { try? await Task.sleep(nanoseconds: 550_000_000) }
            guard !Task.isCancelled else { return }
            isTranslating = true
            translationStatus = "正在检查本地中英文语言包…"
            translationError = nil
            if #available(macOS 15.0, iOS 18.0, *) {
                appleTranslationPassages = passages
                let requestID = UUID()
                appleTranslationRequestID = requestID
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled,
                      appleTranslationRequestID == requestID,
                      isTranslating else { return }
                isTranslating = false
                translationStatus = ""
                translationError = "本地翻译等待超时。请确认系统允许下载翻译语言包，然后重试。"
                return
            }
            guard llmConfiguration.isTranslationConfigured else {
                translationError = "苹果本地翻译需要 macOS 15 或 iOS 18；当前系统可在“大模型服务”中配置 API Key 作为回退。"
                isTranslating = false
                translationStatus = ""
                return
            }
            do {
                let values = try await LLMService.translateToChinese(passages, configuration: llmConfiguration)
                guard !Task.isCancelled else { return }
                chineseTranslations = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) })
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                translationError = "中文翻译失败：\(error.localizedDescription)"
            }
            isTranslating = false
            translationStatus = ""
        }
    }

    @ViewBuilder
    private var appleTranslationRunner: some View {
#if canImport(Translation)
        if #available(macOS 15.0, iOS 18.0, *) {
            AppleTranslationRunner(
                passages: appleTranslationPassages,
                requestID: appleTranslationRequestID,
                status: { requestID, status in
                    guard requestID == appleTranslationRequestID, showsChineseTranslation else { return }
                    translationStatus = status
                },
                completion: { requestID, result in
                guard requestID == appleTranslationRequestID, showsChineseTranslation else { return }
                switch result {
                case .success(let values):
                    chineseTranslations = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) })
                    translationError = nil
                case .failure(let error):
                    translationError = "苹果本地翻译失败：\(error.localizedDescription)"
                }
                isTranslating = false
                translationStatus = ""
            })
            .frame(width: 0, height: 0)
        }
#endif
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            guard resourceValues.isDirectory != true else {
                throw FileImportError.unsupportedFormat
            }

            let contentType = resourceValues.contentType ?? UTType(filenameExtension: url.pathExtension)
            let fileExtension = url.pathExtension.lowercased()
            if contentType?.conforms(to: .audio) == true {
                let configuration = llmConfiguration
                let usesLocalWhisper = configuration.localWhisperEnabled
                audio.load(
                    url: url,
                    localeIdentifier: accent.languageCode,
                    playbackRate: Float(audioPlaybackRate),
                    shouldTranscribe: !usesLocalWhisper
                )
                speech.stop()
                if usesLocalWhisper {
                    audio.beginTranscription(status: "正在使用本地 Whisper 高精度转写…")
                    Task {
                        do {
                            audio.apply(transcription: try await LocalWhisperService.transcribe(url: url, configuration: configuration))
                        } catch {
                            audio.finishTranscription(status: "本地 Whisper 转写失败")
                            errorMessage = "本地 Whisper 转写失败：\(transcriptionErrorMessage(error))"
                        }
                    }
                }
            } else if contentType?.conforms(to: .text) == true || ["txt", "md", "markdown"].contains(fileExtension) {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    text = EnglishTextFormatter.formatArticle(content)
                } else if let content = try? String(contentsOf: url, encoding: .ascii) {
                    text = EnglishTextFormatter.formatArticle(content)
                } else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                audio.unload()
                speech.stop()
                isEditingText = false
            } else {
                throw FileImportError.unsupportedFormat
            }
        } catch {
            errorMessage = error.localizedDescription.isEmpty ? FileImportError.unsupportedFormat.localizedDescription : error.localizedDescription
        }
    }

    private func transcriptionErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时，请检查服务地址和网络。"
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
                return "无法连接服务，请检查服务地址和网络。"
            default: break
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "服务未返回详细错误，请检查 API 地址、模型名和 API Key。" : message
    }
}

#if canImport(Translation)
@available(macOS 15.0, iOS 18.0, *)
private struct AppleTranslationRunner: View {
    let passages: [String]
    let requestID: UUID
    let status: (UUID, String) -> Void
    let completion: (UUID, Result<[String], Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .task(id: requestID) {
                guard !passages.isEmpty else { return }
                status(requestID, "正在准备本地翻译语言包…")
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: "zh-Hans")
                    )
                } else {
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { session in
                let activeRequestID = requestID
                do {
                    status(activeRequestID, "正在检查并下载所需语言包…")
                    try await session.prepareTranslation()
                    guard !Task.isCancelled else { return }
                    status(activeRequestID, "语言包已就绪，正在翻译中文…")
                    let requests = passages.enumerated().map {
                        TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                    }
                    let responses = try await session.translations(from: requests)
                    let ordered = responses.sorted {
                        Int($0.clientIdentifier ?? "0") ?? 0 < Int($1.clientIdentifier ?? "0") ?? 0
                    }
                    completion(activeRequestID, .success(ordered.map(\.targetText)))
                } catch {
                    completion(activeRequestID, .failure(error))
                }
            }
    }
}
#endif

private enum ReaderTheme {
    static let primary = Color(red: 0.29, green: 0.37, blue: 0.90)
    static let mint = Color(red: 0.55, green: 0.89, blue: 0.78)
    static let sunshine = Color(red: 1.00, green: 0.82, blue: 0.36)
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.31, green: 0.40, blue: 0.96), Color(red: 0.60, green: 0.35, blue: 0.92)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let canvas = LinearGradient(
        colors: [Color(red: 0.96, green: 0.98, blue: 1.00), Color(red: 1.00, green: 0.97, blue: 0.90)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Explicit button colors keep controls legible in both light and dark system appearances.
struct ReaderFilledButtonStyle: ButtonStyle {
    var color: Color = ReaderTheme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ReaderOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .fontWeight(.semibold)
            .foregroundStyle(ReaderTheme.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ReaderTheme.primary.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
            .overlay {
                Capsule().stroke(ReaderTheme.primary.opacity(0.75), lineWidth: 1)
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum FileImportError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "无法识别该文件格式。请上传文本或 Markdown 文件（.txt、.md、.markdown），或音频文件（如 .mp3、.m4a、.wav）。"
    }
}

private struct WordSelection: Identifiable {
    let id: String
    let word: String
}

private struct ReadingToken {
    let display: String

    init(_ value: String) {
        display = value + " "
    }

    var lookupWord: String? {
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'-’"))
        let cleaned = display.unicodeScalars.filter { allowed.contains($0) }
        let word = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: "'-’"))
        return word.range(of: "^[A-Za-z]+(?:['’-][A-Za-z]+)*$", options: .regularExpression) == nil ? nil : word
    }
}
