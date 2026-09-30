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
                text = transcription
                isEditingText = false
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
            .sheet(item: $selectedWord) { selection in
                WordDetailView(word: selection.word, accent: accent) {
                    speech.speakWord(selection.word, accent: accent, voiceIdentifier: selectedVoice)
                }
            }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("粘贴英文内容，或选择文本、Markdown、音频文件")
                    .font(.headline)
                Text("当前共 \(wordCount) 个单词")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if isEditingText {
                    text = EnglishTextFormatter.formatArticle(text)
                }
                isEditingText.toggle()
            } label: {
                Label(
                    isEditingText ? "进入阅读" : "编辑文本",
                    systemImage: isEditingText ? "checkmark.circle.fill" : "square.and.pencil"
                )
            }
            .buttonStyle(.borderedProminent)

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

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize, design: fontStyle.design))
            .lineSpacing(max(2, fontSize * 0.22))
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 1)
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
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1)
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
                            guard word != nil else { return }
                            if highlightedTokens.contains(id) {
                                highlightedTokens.remove(id)
                            } else {
                                highlightedTokens.insert(id)
                            }
                        case .second(_):
                            guard let word else { return }
                            speech.speakWord(word, accent: accent, voiceIdentifier: selectedVoice)
                            selectedWord = WordSelection(word: word)
                        }
                    }
            )
            .help(word == nil ? "" : "单击查词，双击高亮")
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
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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

            Slider(
                value: Binding(
                    get: { audio.currentTime },
                    set: { audio.seek(to: $0) }
                ),
                in: 0...max(audio.duration, 0.01)
            )
            .tint(.accentColor)

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

            if childMode {
                Label("儿童模式使用已识别文本逐词朗读；原始音频会暂停。", systemImage: "text.word.spacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
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
                    // Keep system recognition running as an immediate preview while
                    // a local Whisper model downloads/decodes. The local result
                    // replaces this preview when it completes.
                    shouldTranscribe: !usesRemoteWhisper
                )
                speech.stop()
                if usesLocalWhisper {
                    audio.setTranscriptionStatus("正在使用本地 Whisper 高精度转写…")
                    Task {
                        do {
                            audio.apply(transcription: try await LocalWhisperService.transcribe(url: url, configuration: configuration))
                        } catch {
                            audio.setTranscriptionStatus("本地 Whisper 不可用，已使用系统识别结果")
                            errorMessage = "本地 Whisper 转写失败：\(error.localizedDescription)"
                        }
                    }
                } else if usesRemoteWhisper {
                    Task {
                        do {
                            audio.apply(transcription: try await LLMService.transcribe(url: url, configuration: configuration))
                        } catch {
                            audio.startSystemTranscription(url: url, localeIdentifier: accent.languageCode)
                            errorMessage = "大模型转写失败，已回退系统识别：\(error.localizedDescription)"
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
}

private enum FileImportError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "无法识别该文件格式。请上传文本或 Markdown 文件（.txt、.md、.markdown），或音频文件（如 .mp3、.m4a、.wav）。"
    }
}

private struct WordSelection: Identifiable {
    let word: String
    var id: String { word.lowercased() }
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
