import Foundation
import Security

struct AzureSpeechSettings: Sendable {
    let region: String
    let apiKey: String
    let voice: String
    let languageCode: String
}

@MainActor
final class AzureSpeechConfiguration: ObservableObject {
    @Published var isEnabled: Bool { didSet { save() } }
    @Published var region: String { didSet { save() } }
    @Published var americanVoice: String { didSet { save() } }
    @Published var britishVoice: String { didSet { save() } }
    @Published var apiKey: String { didSet { AzureSpeechKeychain.save(apiKey) } }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "azureSpeechEnabled")
        region = defaults.string(forKey: "azureSpeechRegion") ?? "eastus"
        americanVoice = defaults.string(forKey: "azureSpeechAmericanVoice") ?? "en-US-JennyNeural"
        britishVoice = defaults.string(forKey: "azureSpeechBritishVoice") ?? "en-GB-SoniaNeural"
        apiKey = AzureSpeechKeychain.load() ?? ""
    }

    var isConfigured: Bool {
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func settings(for accent: EnglishAccent) -> AzureSpeechSettings? {
        guard isEnabled, isConfigured else { return nil }
        let voice = (accent == .american ? americanVoice : britishVoice)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return nil }
        return AzureSpeechSettings(
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            voice: voice,
            languageCode: accent.languageCode
        )
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: "azureSpeechEnabled")
        defaults.set(region, forKey: "azureSpeechRegion")
        defaults.set(americanVoice, forKey: "azureSpeechAmericanVoice")
        defaults.set(britishVoice, forKey: "azureSpeechBritishVoice")
    }
}

enum AzureSpeechService {
    static func synthesize(text: String, speed: Double, settings: AzureSpeechSettings) async throws -> Data {
        guard let url = URL(string: "https://\(settings.region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw AzureSpeechError.invalidRegion
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(settings.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("EnglishReader", forHTTPHeaderField: "User-Agent")
        let rate = Int((((speed / 0.45) - 1) * 100).rounded()).clamped(to: -50...100)
        let rateText = rate >= 0 ? "+\(rate)%" : "\(rate)%"
        let escapedText = escapeXML(text)
        let escapedVoice = escapeXML(settings.voice)
        request.httpBody = """
        <speak version="1.0" xml:lang="\(settings.languageCode)"><voice name="\(escapedVoice)"><prosody rate="\(rateText)">\(escapedText)</prosody></voice></speak>
        """.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AzureSpeechError.invalidResponse }
        guard 200..<300 ~= http.statusCode, !data.isEmpty else {
            throw AzureSpeechError.service(statusCode: http.statusCode)
        }
        return data
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum AzureSpeechError: LocalizedError {
    case invalidRegion, invalidResponse, service(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRegion: return "Azure Speech 区域无效。"
        case .invalidResponse: return "Azure Speech 未返回有效音频。"
        case .service(let statusCode):
            if statusCode == 401 || statusCode == 403 { return "Azure Speech 密钥无效，或无权使用该区域。" }
            if statusCode == 429 { return "Azure Speech 请求过于频繁或额度不足。" }
            return "Azure Speech 请求失败（HTTP \(statusCode)）。"
        }
    }
}

private enum AzureSpeechKeychain {
    private static let service = "EnglishReader.AzureSpeech"
    private static let account = "apiKey"

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
