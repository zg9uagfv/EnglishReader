import Foundation
import NaturalLanguage
import SwiftUI

enum DisplayFontStyle: String, CaseIterable, Identifiable {
    case system = "系统"
    case serif = "衬线"
    case rounded = "圆体"
    case monospaced = "等宽"

    var id: Self { self }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }
}

enum EnglishTextFormatter {
    static func sentences(in text: String) -> [String] {
        let cleaned = cleanWhitespace(text)
        guard !cleaned.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        var result: [String] = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let sentence = cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [cleaned] : result
    }

    static func formatArticle(_ text: String) -> String {
        let items = sentences(in: text)
        return stride(from: 0, to: items.count, by: 3).map { start in
            items[start..<min(start + 3, items.count)].joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    private static func cleanWhitespace(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "([,.;:!?])(?=[A-Za-z])", with: "$1 ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
