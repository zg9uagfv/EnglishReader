import Foundation

struct WordDefinition {
    let word: String
    let phonetic: String
    let meanings: [Meaning]
    var chineseDefinition: String
    let audioURL: URL?

    struct Meaning: Identifiable {
        let partOfSpeech: String
        let definitions: [String]
        var id: String { partOfSpeech + definitions.joined() }
    }
}

enum DictionaryError: LocalizedError {
    case invalidWord
    case notFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidWord: return "无效的英文单词"
        case .notFound: return "词典中没有找到这个单词"
        case .invalidResponse: return "词典服务暂时不可用，请稍后重试"
        }
    }
}

actor DictionaryService {
    static let shared = DictionaryService()
    private var cache: [String: WordDefinition] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func lookup(_ word: String) async throws -> WordDefinition {
        let key = word.lowercased()
        if let cached = cache[key] { return cached }
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            throw DictionaryError.invalidWord
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DictionaryError.invalidResponse }
        guard http.statusCode != 404 else { throw DictionaryError.notFound }
        guard (200...299).contains(http.statusCode) else { throw DictionaryError.invalidResponse }

        let entries = try JSONDecoder().decode([APIEntry].self, from: data)
        guard let entry = entries.first else { throw DictionaryError.notFound }
        let meanings = entry.meanings.prefix(4).map { item in
            WordDefinition.Meaning(
                partOfSpeech: item.partOfSpeech,
                definitions: item.definitions.prefix(3).map(\.definition)
            )
        }
        let result = WordDefinition(
            word: entry.word,
            phonetic: entry.phonetic ?? entry.phonetics.compactMap(\.text).first ?? "暂无音标",
            meanings: meanings,
            chineseDefinition: "正在加载中文释义…",
            audioURL: entry.phonetics.compactMap(\.audioURL).first
        )
        cache[key] = result
        return result
    }

    func loadChineseDefinition(for definition: WordDefinition) async -> String {
        let englishText = definition.meanings.flatMap(\.definitions).prefix(6).joined(separator: "; ")
        do {
            return try await translateToChinese(englishText)
        } catch {
            return "中文释义加载失败；英英释义仍可正常使用。"
        }
    }

    func pronunciationURL(for word: String) async throws -> URL? {
        let key = word.lowercased()
        if let cached = cache[key] { return cached.audioURL }
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            throw DictionaryError.invalidWord
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DictionaryError.notFound
        }
        let entries = try JSONDecoder().decode([APIEntry].self, from: data)
        return entries.first?.phonetics.compactMap(\.audioURL).first
    }

    private func translateToChinese(_ text: String) async throws -> String {
        guard !text.isEmpty else { return "暂无中文释义" }
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "en|zh-CN")
        ]
        guard let url = components?.url else { throw DictionaryError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DictionaryError.invalidResponse
        }
        return try JSONDecoder().decode(TranslationResponse.self, from: data).responseData.translatedText
    }
}

private struct APIEntry: Decodable {
    let word: String
    let phonetic: String?
    let phonetics: [Phonetic]
    let meanings: [APIMeaning]

    struct Phonetic: Decodable {
        let text: String?
        let audio: String?

        var audioURL: URL? {
            guard let audio, !audio.isEmpty else { return nil }
            if audio.hasPrefix("//") { return URL(string: "https:\(audio)") }
            return URL(string: audio)
        }
    }
}

private struct APIMeaning: Decodable {
    let partOfSpeech: String
    let definitions: [APIDefinition]
}

private struct APIDefinition: Decodable { let definition: String }

private struct TranslationResponse: Decodable {
    let responseData: ResponseData
    struct ResponseData: Decodable { let translatedText: String }
}
