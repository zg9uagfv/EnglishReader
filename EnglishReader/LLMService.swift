import Foundation
import Security

struct TimedTranscriptWord: Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct LLMTranscription: Sendable {
    let text: String
    let words: [TimedTranscriptWord]
}

@MainActor
final class LLMConfiguration: ObservableObject {
    static let openAIBaseURL = "https://api.openai.com/v1"
    static let openAITranscriptionModel = "gpt-4o-mini-transcribe"
    static let openAISpeechModel = "gpt-4o-mini-tts"
    private static let didApplyOpenAIServiceDefaultsKey = "didApplyOpenAIServiceDefaults"

    @Published var baseURL: String { didSet { save() } }
    @Published var transcriptionModel: String { didSet { save() } }
    @Published var speechModel: String { didSet { save() } }
    @Published var apiKey: String { didSet { Keychain.save(apiKey) } }
    @Published var localWhisperEnabled: Bool { didSet { save() } }
    @Published var localWhisperModel: String { didSet { save() } }
    @Published var localWhisperModelDirectory: String { didSet { save() } }
    @Published var localWhisperPythonPath: String { didSet { save() } }

    var isConfigured: Bool { !baseURL.isEmpty && !transcriptionModel.isEmpty && !apiKey.isEmpty }

    init() {
        let defaults = UserDefaults.standard
        let shouldApplyOpenAIDefaults = !defaults.bool(forKey: Self.didApplyOpenAIServiceDefaultsKey)
        baseURL = shouldApplyOpenAIDefaults
            ? Self.openAIBaseURL
            : defaults.string(forKey: "llmBaseURL") ?? Self.openAIBaseURL
        transcriptionModel = shouldApplyOpenAIDefaults
            ? Self.openAITranscriptionModel
            : defaults.string(forKey: "llmTranscriptionModel") ?? Self.openAITranscriptionModel
        speechModel = shouldApplyOpenAIDefaults
            ? Self.openAISpeechModel
            : defaults.string(forKey: "llmSpeechModel") ?? Self.openAISpeechModel
        apiKey = Keychain.load() ?? ""
        localWhisperEnabled = defaults.bool(forKey: "localWhisperEnabled")
        localWhisperModel = defaults.string(forKey: "localWhisperModel") ?? "mlx-community/whisper-large-v3-turbo"
        localWhisperModelDirectory = defaults.string(forKey: "localWhisperModelDirectory") ?? ""
        let savedRuntime = defaults.string(forKey: "localWhisperPythonPath") ?? ""
        localWhisperPythonPath = savedRuntime.isEmpty ? Self.detectLocalWhisperRuntime() : savedRuntime
        if shouldApplyOpenAIDefaults {
            defaults.set(baseURL, forKey: "llmBaseURL")
            defaults.set(transcriptionModel, forKey: "llmTranscriptionModel")
            defaults.set(speechModel, forKey: "llmSpeechModel")
            defaults.set(true, forKey: Self.didApplyOpenAIServiceDefaultsKey)
        }
    }

    func useOpenAIDefaults() {
        baseURL = Self.openAIBaseURL
        transcriptionModel = Self.openAITranscriptionModel
        speechModel = Self.openAISpeechModel
    }

    private func save() {
        UserDefaults.standard.set(baseURL, forKey: "llmBaseURL")
        UserDefaults.standard.set(transcriptionModel, forKey: "llmTranscriptionModel")
        UserDefaults.standard.set(speechModel, forKey: "llmSpeechModel")
        UserDefaults.standard.set(localWhisperEnabled, forKey: "localWhisperEnabled")
        UserDefaults.standard.set(localWhisperModel, forKey: "localWhisperModel")
        UserDefaults.standard.set(localWhisperModelDirectory, forKey: "localWhisperModelDirectory")
        UserDefaults.standard.set(localWhisperPythonPath, forKey: "localWhisperPythonPath")
    }

    private static func detectLocalWhisperRuntime() -> String {
        let candidates = [
            "/private/tmp/englishreader-whisper312/bin/python",
            NSHomeDirectory() + "/Library/Application Support/EnglishReader/whisper/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}

@MainActor
enum LLMService {
    static func transcribe(url: URL, configuration: LLMConfiguration) async throws -> LLMTranscription {
        let boundary = UUID().uuidString
        var request = try request(path: "audio/transcriptions", configuration: configuration)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let audio = try Data(contentsOf: url)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", configuration.transcriptionModel)
        field("response_format", "verbose_json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(url.pathExtension)\"\r\nContent-Type: \(audioMIMEType(for: url))\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = json?["text"] as? String ?? ""
        let words = (json?["words"] as? [[String: Any]] ?? []).compactMap { item -> TimedTranscriptWord? in
            guard let word = item["word"] as? String, let start = item["start"] as? Double, let end = item["end"] as? Double else { return nil }
            return TimedTranscriptWord(text: word, start: start, end: end)
        }
        return LLMTranscription(text: text, words: words)
    }

    static func synthesize(text: String, configuration: LLMConfiguration) async throws -> URL {
        var request = try request(path: "audio/speech", configuration: configuration)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": configuration.speechModel, "input": text, "voice": "alloy", "response_format": "mp3"])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        try data.write(to: output)
        return output
    }

    private static func request(path: String, configuration: LLMConfiguration) throws -> URLRequest {
        let root = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/" + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LLMService", code: 1, userInfo: [NSLocalizedDescriptionKey: "大模型服务未返回有效响应。"])
        }
        guard 200..<300 ~= http.statusCode else {
            throw NSError(
                domain: "LLMService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: serviceErrorMessage(statusCode: http.statusCode, data: data)]
            )
        }
    }

    private static func serviceErrorMessage(statusCode: Int, data: Data) -> String {
        if statusCode == 401 || statusCode == 403 {
            return "认证失败：API Key 无效，或与当前服务地址不匹配。"
        }
        if statusCode == 404 {
            return "找不到语音接口：请确认服务支持 /audio/transcriptions 或 /audio/speech。"
        }
        if statusCode == 429 {
            if let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = response["error"] as? [String: Any],
               let code = error["code"] as? String,
               code == "credit_balance_exhausted" {
                return "OpenAI API 账户额度已用尽，请充值后再试。"
            }
            return "请求过于频繁或账户额度不足，请稍后重试。"
        }
        if let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "服务请求失败：\(message)"
        }
        return "服务请求失败（HTTP \(statusCode)），且未返回详细错误。"
    }

    private static func audioMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        default: return "audio/mpeg"
        }
    }
}

@MainActor
enum LocalWhisperService {
    static func transcribe(url: URL, configuration: LLMConfiguration) async throws -> LLMTranscription {
        let runtimePath = configuration.localWhisperPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimePath.isEmpty else {
            throw LocalWhisperError.runtimeNotConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            throw LocalWhisperError.runtimeUnavailable
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnglishReader-Whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var arguments = [
            "-m", "whispermlx", url.path,
            "--model", configuration.localWhisperModel,
            "--language", "en",
            "--output_dir", outputDirectory.path,
            "--output_format", "json",
            "--verbose", "False",
            "--log-level", "warning",
            "--print_progress", "False"
        ]
        let modelDirectory = configuration.localWhisperModelDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelDirectory.isEmpty {
            arguments += ["--model_dir", modelDirectory]
        }

        let result = try await run(executable: runtimePath, arguments: arguments)
        guard result.status == 0 else {
            throw LocalWhisperError.processFailed(summary(of: result.error.isEmpty ? result.output : result.error))
        }
        let jsonURL = try findJSON(in: outputDirectory)
            .unwrap(or: LocalWhisperError.outputMissing)
        let data = try Data(contentsOf: jsonURL)
        return try parse(data: data)
    }

    private static func parse(data: Data) throws -> LLMTranscription {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalWhisperError.outputInvalid
        }
        let segments = json["segments"] as? [[String: Any]] ?? []
        let words = segments.flatMap { segment -> [TimedTranscriptWord] in
            (segment["words"] as? [[String: Any]] ?? []).compactMap { word in
                guard let text = (word["word"] as? String) ?? (word["text"] as? String),
                      let start = number(word["start"]),
                      let end = number(word["end"]) else { return nil }
                return TimedTranscriptWord(text: text, start: start, end: end)
            }
        }
        let segmentText = segments.compactMap { $0["text"] as? String }.joined(separator: " ")
        let text = (json["text"] as? String) ?? segmentText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalWhisperError.outputInvalid
        }
        return LLMTranscription(text: text, words: words)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func findJSON(in directory: URL) throws -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.pathExtension.lowercased() == "json" else { continue }
            let values = try candidate.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true { return candidate }
        }
        return nil
    }

    private static func summary(of output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
        if let error = lines.last(where: { $0.localizedCaseInsensitiveContains("error:") }) {
            return String(error)
        }
        return String(lines.last ?? "未知错误")
    }

    private static func run(executable: String, arguments: [String]) async throws -> (status: Int32, output: String, error: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                // The app may inherit a SOCKS proxy from the shell. httpx used by
                // the model downloader cannot use it without socksio, so let the
                // local Whisper process use a direct connection.
                var environment = ProcessInfo.processInfo.environment
                for key in ["ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"] {
                    environment.removeValue(forKey: key)
                }
                process.environment = environment
                process.standardOutput = output
                process.standardError = error
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: (
                        process.terminationStatus,
                        String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                        String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum LocalWhisperError: LocalizedError {
    case runtimeNotConfigured
    case runtimeUnavailable
    case outputMissing
    case outputInvalid
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotConfigured: return "请在偏好设置中填写 Python / Whisper 运行时路径。"
        case .runtimeUnavailable: return "指定的 Python / Whisper 运行时不可执行。"
        case .outputMissing: return "本地 Whisper 未生成转写文件。"
        case .outputInvalid: return "本地 Whisper 的转写文件格式无效。"
        case .processFailed(let message): return "本地 Whisper 运行失败：\(message)"
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

private enum Keychain {
    static func save(_ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "EnglishReader.LLM", kSecAttrAccount as String: "apiKey"]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "EnglishReader.LLM", kSecAttrAccount as String: "apiKey", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
