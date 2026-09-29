import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var speech = SpeechController()
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PreferencesView(
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
                applyLiveSettings(debounced: true)
            }
            .onChange(of: wordPause) { _ in
                applyLiveSettings(debounced: true)
            }
            .navigationTitle("英文文章朗读")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.plainText, .utf8PlainText],
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
                Text("粘贴英文内容，或导入文本文件")
                    .font(.headline)
                Text("当前共 \(wordCount) 个单词")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Label(
                    columnVisibility == .detailOnly ? "显示偏好" : "隐藏偏好",
                    systemImage: "sidebar.left"
                )
            }
            .buttonStyle(.bordered)

            Button {
                if isEditingText {
                    text = EnglishTextFormatter.formatArticle(text)
                }
                isEditingText.toggle()
            } label: {
                Label(
                    isEditingText ? "完成编辑" : "编辑内容",
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
            .onChange(of: speech.currentSpokenWordIndex) { index in
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
        let isCurrentlySpoken = speech.currentSpokenWordIndex == wordIndex
        return Text(token.display)
            .font(.system(size: fontSize, design: fontStyle.design))
            .fontWeight(isCurrentlySpoken ? .bold : .regular)
            .foregroundStyle(word == nil ? Color.primary : Color.blue)
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
        HStack(spacing: 12) {
            Button {
                if speech.isSpeaking {
                    speech.stop()
                } else {
                    isEditingText = false
                    columnVisibility = .detailOnly
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

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = EnglishTextFormatter.formatArticle(content)
            } else if let content = try? String(contentsOf: url, encoding: .ascii) {
                text = EnglishTextFormatter.formatArticle(content)
            } else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            speech.stop()
            isEditingText = false
        } catch {
            errorMessage = error.localizedDescription
        }
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
