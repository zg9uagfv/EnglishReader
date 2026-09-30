import SwiftUI
import UniformTypeIdentifiers

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
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            NavigationStack {
                ZStack {
                    ReaderTheme.canvas.ignoresSafeArea()
                    VStack(spacing: 20) {
                        header
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
                audio.setPlaybackRate(audioPlaybackRate)
                applyLiveSettings(debounced: true)
            }
            .onChange(of: wordPause) { _ in
                applyLiveSettings(debounced: true)
            }
            .onChange(of: childMode) { enabled in
                if enabled && audio.isPlaying {
                    audio.pause()
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
                guard isEditingText,
                      audio.hasAudio,
                      updatedText != audioTranscriptText else { return }
                // The source text has diverged from the audio transcript. Keeping
                // the old player here would make the play button use stale audio.
                audio.unload()
                speech.stop()
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
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: childMode ? "figure.and.child.holdinghands" : "book.closed.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(ReaderTheme.heroGradient, in: Circle())
                .shadow(color: ReaderTheme.primary.opacity(0.25), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(childMode ? "一起读英语吧！" : "英语阅读小伙伴")
                    .font(.title3.weight(.bold))
                Text("粘贴内容，或选择文本、Markdown、音频文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(wordCount) 个单词 · \(childMode ? "儿童逐词模式" : "自由阅读模式")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ReaderTheme.primary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button {
                    if isEditingText {
                        text = EnglishTextFormatter.formatArticle(text)
                    }
                    isEditingText.toggle()
                } label: {
                    Label(
                        isEditingText ? "进入阅读" : "编辑文本",
                        systemImage: isEditingText ? "play.circle.fill" : "square.and.pencil"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(ReaderTheme.primary)

                Button {
                    isImporting = true
                } label: {
                    Label("选择文件", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    text = EnglishTextFormatter.formatArticle(text)
                } label: {
                    Label("自动排版", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: ReaderTheme.primary.opacity(0.10), radius: 14, y: 6)
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
                    let tokens = tokens(for: formattedSentences[sentenceIndex])
                    let sentenceOffset = tokenOffset(for: sentenceIndex)
                    WrappingLayout(spacing: max(3, fontSize * 0.18)) {
                        ForEach(tokens.indices, id: \.self) { tokenIndex in
                            readingTokenView(
                                tokens[tokenIndex],
                                id: "\(sentenceIndex)-\(tokenIndex)",
                                wordIndex: sentenceOffset + tokenIndex
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private func readingTokenView(_ token: ReadingToken, id: String, wordIndex: Int) -> some View {
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
                            guard let word else { return }
                            selectedWord = WordSelection(id: id, word: word)
                        case .second(_):
                            guard word != nil else { return }
                            if highlightedTokens.contains(id) {
                                highlightedTokens.remove(id)
                            } else {
                                highlightedTokens.insert(id)
                            }
                        }
                    }
            )
            .popover(item: wordSelectionBinding(for: id), arrowEdge: .bottom) { selection in
                WordDetailView(word: selection.word, accent: accent) {
                    speech.speakWord(selection.word, accent: accent, voiceIdentifier: selectedVoice)
                }
            }
            .help(word == nil ? "" : "双击查看音标和词义，单击高亮")
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
        let completedWords = min(max(0, (activeSpokenWordIndex ?? -1) + 1), wordCount)
        let progress = wordCount == 0 ? 0 : Double(completedWords) / Double(wordCount)
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
            Slider(value: .constant(progress), in: 0...1)
                .tint(.accentColor)
                .allowsHitTesting(false)
                .accessibilityValue("已朗读 \(completedWords)，共 \(wordCount) 个单词")
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
                    speech.speak(
                        text,
                        accent: accent,
                        speed: speed,
                        childMode: childMode,
                        wordPause: wordPause,
                        voiceIdentifier: selectedVoice
                    )
                }
            } label: {
                Label(
                    speech.isSpeaking ? "关闭阅读" : "开始阅读",
                    systemImage: speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(speech.isSpeaking ? .red : .accentColor)
            .disabled(!speech.isSpeaking && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                speech.togglePause()
            } label: {
                Label(speech.isPaused ? "继续" : "暂停", systemImage: speech.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!speech.isSpeaking)

            if llmConfiguration.isConfigured {
                Button("大模型生成音频") {
                    Task {
                        do {
                            let url = try await LLMService.synthesize(text: text, configuration: llmConfiguration)
                            audio.load(url: url, localeIdentifier: accent.languageCode, playbackRate: audioPlaybackRate, shouldTranscribe: false)
                        } catch {
                            errorMessage = "大模型语音生成失败：\(error.localizedDescription)"
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Text(String(format: "%.2g×", audio.playbackRate))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            if audio.isTranscribing {
                ProgressView()
                    .progressViewStyle(.linear)
                Label("模型正在处理音频，完成后会自动整理为段落。", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            HStack(spacing: 24) {
                Button { audio.skip(by: -15) } label: {
                    Label("后退 15 秒", systemImage: "gobackward.15")
                }
                .buttonStyle(.bordered)

                if childMode {
                    Button {
                        if speech.isSpeaking {
                            speech.stop()
                        } else {
                            audio.pause()
                            speech.speak(
                                text,
                                accent: accent,
                                speed: speed,
                                childMode: true,
                                wordPause: wordPause,
                                voiceIdentifier: selectedVoice
                            )
                        }
                    } label: {
                        Label(
                            speech.isSpeaking ? "停止儿童跟读" : "儿童逐词跟读",
                            systemImage: speech.isSpeaking ? "stop.fill" : "figure.and.child.holdinghands"
                        )
                        .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button { audio.togglePlayback() } label: {
                        Label(audio.isPlaying ? "暂停音频" : "播放音频", systemImage: audio.isPlaying ? "pause.fill" : "play.fill")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button { audio.skip(by: 15) } label: {
                    Label("前进 15 秒", systemImage: "goforward.15")
                }
                .buttonStyle(.bordered)
            }
            .disabled(audio.isTranscribing)

            if childMode {
                Label("儿童模式使用已识别文本逐词朗读；原始音频会暂停。", systemImage: "text.word.spacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private var selectedVoice: String? {
        selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
    }

    private var activeSpokenWordIndex: Int? {
        speech.isSpeaking ? speech.currentSpokenWordIndex : (audio.hasAudio ? audio.currentSpokenWordIndex : nil)
    }

    private var audioPlaybackRate: Float {
        Float(min(2.0, max(0.5, speed / 0.45)))
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
                let usesRemoteWhisper = !usesLocalWhisper && configuration.isConfigured
                audio.load(
                    url: url,
                    localeIdentifier: accent.languageCode,
                    playbackRate: audioPlaybackRate,
                    // A chosen Whisper service owns the transcript lifecycle, so
                    // playback only becomes available after it has completed.
                    shouldTranscribe: !usesLocalWhisper && !usesRemoteWhisper
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
                } else if usesRemoteWhisper {
                    audio.beginTranscription(status: "正在使用大模型转写音频…")
                    Task {
                        do {
                            audio.apply(transcription: try await LLMService.transcribe(url: url, configuration: configuration))
                        } catch {
                            audio.startSystemTranscription(url: url, localeIdentifier: accent.languageCode)
                            errorMessage = "大模型转写失败，已回退系统识别：\(transcriptionErrorMessage(error))"
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
