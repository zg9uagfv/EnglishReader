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
        var result: [String] = []
        for paragraph in paragraphs(in: text) {
            let lines = paragraph
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            if isList(lines) || (lines.count >= 3 && lines[0].hasSuffix(":") && lines.dropFirst().allSatisfy(isLikelyListEntry)) {
                result.append(contentsOf: lines.map(normalizeLine))
                continue
            }

            let cleaned = cleanWhitespace(lines.joined(separator: " "))
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = cleaned
            tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
                let sentence = cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                return true
            }
        }
        return result
    }

    static func formatArticle(_ text: String) -> String {
        return paragraphs(in: text).map(formatParagraph).joined(separator: "\n\n")
    }

    private static func cleanWhitespace(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "([,.;:!?])(?=[A-Za-z])", with: "$1 ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paragraphs(in text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Pasted text often contains spaces on visually blank lines. Treat those
            // as paragraph separators too, rather than merging the two paragraphs.
            .replacingOccurrences(of: "\\n[\\t ]*\\n+", with: "\n\n", options: .regularExpression)

        let rawParagraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var index = 0
        while index < rawParagraphs.count {
            let paragraph = rawParagraphs[index]
            let lines = paragraph
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // A pasted vocabulary heading commonly has a blank line before its
            // entries. Keep it with the following block so every entry remains a
            // separate row instead of becoming one prose sentence.
            if lines.count == 1, lines[0].hasSuffix(":"), index + 1 < rawParagraphs.count {
                result.append(paragraph + "\n" + rawParagraphs[index + 1])
                index += 2
            } else {
                result.append(paragraph)
                index += 1
            }
        }
        return result
    }

    /// Keep intentional paragraph and vocabulary/list breaks.  The previous formatter
    /// flattened the entire article before re-grouping sentences, which merged lists
    /// into prose and discarded paragraph boundaries supplied by the reader.
    private static func formatParagraph(_ paragraph: String) -> String {
        let lines = paragraph
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        if isList(lines) {
            return lines.map(normalizeLine).joined(separator: "\n")
        }

        // A label such as "Vocabulary:" introduces entries even when the entries
        // were pasted without bullets.  Preserve those entries one per line.
        if lines.count >= 3, lines[0].hasSuffix(":"), lines.dropFirst().allSatisfy(isLikelyListEntry) {
            return ([normalizeLine(lines[0])] + lines.dropFirst().map(normalizeLine)).joined(separator: "\n")
        }

        return normalizeLine(lines.joined(separator: " "))
    }

    private static func normalizeLine(_ line: String) -> String {
        cleanWhitespace(line)
    }

    private static func isList(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        return lines.allSatisfy { line in
            line.range(of: "^(?:[-*•]|\\d+[.)])\\s+", options: .regularExpression) != nil
        }
    }

    private static func isLikelyListEntry(_ line: String) -> Bool {
        let normalized = normalizeLine(line)
        guard !normalized.isEmpty, normalized.count <= 48 else { return false }
        return normalized.range(of: "[.!?]$", options: .regularExpression) == nil
    }
}
