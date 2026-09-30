import Foundation

struct WordDefinition {
    let word: String
    let phonetic: String
    let meanings: [Meaning]
    var chineseDefinition: String
    let sourceName: String
    let sourceURL: URL

    struct Meaning: Identifiable {
        let partOfSpeech: String
        let definitions: [String]
        let examples: [String]
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
        guard key.range(of: "^[a-z]+(?:['’-][a-z]+)*$", options: .regularExpression) != nil else {
            throw DictionaryError.invalidWord
        }

        let result: WordDefinition
        do {
            let url = longmanURL(for: key)
            result = try parseLongman(try await fetchHTML(url), word: key, url: url)
        } catch {
            let url = bingSearchURL(query: "\(key) definition")
            result = try parseBing(try await fetchHTML(url), word: key, url: url)
        }
        cache[key] = result
        return result
    }

    func loadChineseDefinition(for definition: WordDefinition) async -> String {
        do {
            let html = try await fetchHTML(bingSearchURL(query: "\(definition.word) 中文释义"))
            let snippets = bingSnippets(in: html)
            guard !snippets.isEmpty else { throw DictionaryError.notFound }
            return snippets.prefix(2).joined(separator: "\n\n")
        } catch {
            return "Bing 暂未返回中文释义；请稍后重试。"
        }
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { throw DictionaryError.invalidResponse }
        return html
    }

    private func parseLongman(_ html: String, word: String, url: URL) throws -> WordDefinition {
        let definitions = matches(#"class\s*=\s*[\"'][^\"']*\bDEF\b[^\"']*[\"'][^>]*>(.*?)</(?:span|div)>"#, in: html)
            .map(cleanHTML)
            .filter { !$0.isEmpty }
        guard !definitions.isEmpty else { throw DictionaryError.notFound }
        let phonetic = matches(#"class\s*=\s*[\"'][^\"']*\bPRON\b[^\"']*[\"'][^>]*>(.*?)</span>"#, in: html)
            .map(cleanHTML)
            .first
            .map { "/\($0)/" } ?? "朗文未提供音标"
        let partOfSpeech = matches(#"class\s*=\s*[\"'][^\"']*\bPOS\b[^\"']*[\"'][^>]*>(.*?)</span>"#, in: html)
            .map(cleanHTML)
            .first ?? "definition"
        return WordDefinition(
            word: word,
            phonetic: phonetic,
            meanings: [
                WordDefinition.Meaning(
                    partOfSpeech: partOfSpeech,
                    definitions: Array(definitions.prefix(4)),
                    examples: Array(longmanExamples(in: html).prefix(2))
                )
            ],
            chineseDefinition: "正在通过 Bing 查询中文释义…",
            sourceName: "朗文词典",
            sourceURL: url
        )
    }

    private func parseBing(_ html: String, word: String, url: URL) throws -> WordDefinition {
        let snippets = bingSnippets(in: html)
        guard !snippets.isEmpty else { throw DictionaryError.notFound }
        return WordDefinition(
            word: word,
            phonetic: "Bing 搜索未提供音标",
            meanings: [
                WordDefinition.Meaning(
                    partOfSpeech: "Bing 搜索结果",
                    definitions: Array(snippets.prefix(3)),
                    examples: Array(snippets.dropFirst(3).prefix(2))
                )
            ],
            chineseDefinition: "正在通过 Bing 查询中文释义…",
            sourceName: "Bing 搜索",
            sourceURL: url
        )
    }

    private func bingSnippets(in html: String) -> [String] {
        matches(#"<li[^>]*class\s*=\s*[\"'][^\"']*\bb_algo\b[^\"']*[\"'][^>]*>.*?<p[^>]*>(.*?)</p>"#, in: html)
            .map(cleanHTML)
            .filter { $0.count > 12 }
    }

    private func longmanExamples(in html: String) -> [String] {
        matches(#"class\s*=\s*[\"'][^\"']*\bEXAMPLE\b[^\"']*[\"'][^>]*>(.*?)</(?:span|div)>"#, in: html)
            .map(cleanHTML)
            .filter { !$0.isEmpty }
    }

    private func matches(_ pattern: String, in html: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
    }

    private func cleanHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func longmanURL(for word: String) -> URL {
        URL(string: "https://www.ldoceonline.com/dictionary/\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!
    }

    private func bingSearchURL(query: String) -> URL {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}
