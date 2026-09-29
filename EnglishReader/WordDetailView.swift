import SwiftUI

struct WordDetailView: View {
    let word: String
    let accent: EnglishAccent
    let speak: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var definition: WordDefinition?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
            .navigationTitle(accent.rawValue)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .task(id: word) {
            do {
                var result = try await DictionaryService.shared.lookup(word)
                definition = result
                result.chineseDefinition = await DictionaryService.shared.loadChineseDefinition(for: result)
                definition = result
            } catch {
                if let urlError = error as? URLError,
                   urlError.code == .timedOut || urlError.code == .cannotConnectToHost || urlError.code == .notConnectedToInternet {
                    errorMessage = "在线词典连接超时。当前词典服务位于境外，请检查网络后重试。"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let definition {
            definitionContent(definition)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text("查询失败").font(.headline)
                Text(errorMessage).foregroundStyle(.secondary)
            }
            .padding()
        } else {
            ProgressView("正在查询 \(word)…")
        }
    }

    private func definitionContent(_ definition: WordDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                wordHeader(definition)
                sectionTitle("英英释义")
                ForEach(definition.meanings) { meaning in
                    meaningView(meaning)
                }
                sectionTitle("英汉释义")
                Text(definition.chineseDefinition)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(24)
        }
    }

    private func wordHeader(_ definition: WordDefinition) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(definition.word).font(.largeTitle.bold())
                Text(definition.phonetic).font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: speak) {
                Image(systemName: "speaker.wave.2.fill").font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("朗读单词")
        }
    }

    private func meaningView(_ meaning: WordDefinition.Meaning) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(meaning.partOfSpeech).font(.headline).foregroundStyle(.blue)
            ForEach(meaning.definitions.indices, id: \.self) { index in
                Text("\(index + 1). \(meaning.definitions[index])")
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title2.bold())
    }
}
