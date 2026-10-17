import AVFoundation
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
    static let openAIModel = "gpt-4o-mini"
    private static let didApplyOpenAIServiceDefaultsKey = "didApplyOpenAIServiceDefaults"

    @Published var baseURL: String { didSet { save() } }
    @Published var model: String { didSet { save() } }
    @Published var apiKey: String {
        didSet {
            guard !isRestoringAPIKey else { return }
            let value = apiKey
            keychainSaveQueue.async { Keychain.save(value) }
        }
    }
    private var isRestoringAPIKey = false
    private let keychainSaveQueue = DispatchQueue(label: "ReadAlong.LLM.KeychainSave", qos: .utility)
    @Published var localWhisperEnabled: Bool { didSet { save() } }
    @Published var localWhisperModel: String { didSet { save() } }
    @Published var localWhisperModelDirectory: String { didSet { save() } }
    @Published var localWhisperPythonPath: String { didSet { save() } }

    var isConfigured: Bool { !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty }
    var isTranslationConfigured: Bool { isConfigured }

    init() {
        let defaults = UserDefaults.standard
        let shouldApplyOpenAIDefaults = !defaults.bool(forKey: Self.didApplyOpenAIServiceDefaultsKey)
        baseURL = shouldApplyOpenAIDefaults
            ? Self.openAIBaseURL
            : defaults.string(forKey: "llmBaseURL") ?? Self.openAIBaseURL
        model = shouldApplyOpenAIDefaults
            ? Self.openAIModel
            : defaults.string(forKey: "llmModel")
                ?? defaults.string(forKey: "llmTranslationModel")
                ?? Self.openAIModel
        apiKey = ""
        localWhisperEnabled = defaults.bool(forKey: "localWhisperEnabled")
        localWhisperModel = defaults.string(forKey: "localWhisperModel") ?? "mlx-community/whisper-large-v3-turbo"
        localWhisperModelDirectory = defaults.string(forKey: "localWhisperModelDirectory") ?? ""
        let savedRuntime = defaults.string(forKey: "localWhisperPythonPath") ?? ""
        localWhisperPythonPath = FileManager.default.isExecutableFile(atPath: savedRuntime)
            ? savedRuntime
            : Self.detectLocalWhisperRuntime()
        if localWhisperPythonPath != savedRuntime {
            defaults.set(localWhisperPythonPath, forKey: "localWhisperPythonPath")
        }
        if shouldApplyOpenAIDefaults {
            defaults.set(baseURL, forKey: "llmBaseURL")
            defaults.set(model, forKey: "llmModel")
            defaults.set(true, forKey: Self.didApplyOpenAIServiceDefaultsKey)
        }
        Task.detached(priority: .utility) { [weak self] in
            let savedKey = Keychain.load()
            await MainActor.run {
                guard let self, let savedKey, self.apiKey.isEmpty else { return }
                self.isRestoringAPIKey = true
                self.apiKey = savedKey
                self.isRestoringAPIKey = false
            }
        }
    }

    func useOpenAIDefaults() {
        baseURL = Self.openAIBaseURL
        model = Self.openAIModel
    }

    private func save() {
        UserDefaults.standard.set(baseURL, forKey: "llmBaseURL")
        UserDefaults.standard.set(model, forKey: "llmModel")
        UserDefaults.standard.set(localWhisperEnabled, forKey: "localWhisperEnabled")
        UserDefaults.standard.set(localWhisperModel, forKey: "localWhisperModel")
        UserDefaults.standard.set(localWhisperModelDirectory, forKey: "localWhisperModelDirectory")
        UserDefaults.standard.set(localWhisperPythonPath, forKey: "localWhisperPythonPath")
    }

    private static func detectLocalWhisperRuntime() -> String {
        let candidates = [
            NSHomeDirectory() + "/.local/share/readalong-whisper/bin/python",
            NSHomeDirectory() + "/Library/Application Support/ReadAlong/whisper/bin/python",
            // Keep existing local runtimes usable after upgrading from EnglishReader.
            NSHomeDirectory() + "/.local/share/englishreader-whisper/bin/python",
            NSHomeDirectory() + "/Library/Application Support/EnglishReader/whisper/bin/python",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}

@MainActor
enum LLMService {
    static func translateToChinese(_ passages: [String], configuration: LLMConfiguration) async throws -> [String] {
        guard !passages.isEmpty else { return [] }
        var request = try request(path: "chat/completions", configuration: configuration)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let numberedText = passages.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "Translate each numbered English passage into natural Simplified Chinese. Return only a JSON array of translated strings, in exactly the same order and count. Do not include the numbers."],
                ["role": "user", "content": numberedText]
            ]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "LLMService", code: 2, userInfo: [NSLocalizedDescriptionKey: "翻译服务未返回有效内容。"])
        }
        let jsonText = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = jsonText.data(using: .utf8),
              let translations = try JSONSerialization.jsonObject(with: jsonData) as? [String],
              translations.count == passages.count else {
            throw NSError(domain: "LLMService", code: 3, userInfo: [NSLocalizedDescriptionKey: "翻译结果与原文段落数量不一致，请重试。"])
        }
        return translations
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
            return "找不到大模型接口：请确认服务支持 /chat/completions。"
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

}

@MainActor
enum LocalWhisperService {
    private final class CancellableProcess: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    static func transcribe(
        url: URL,
        configuration: LLMConfiguration,
        onChunk: @MainActor (LLMTranscription, Int, Int) -> Void
    ) async throws {
        let runtimePath = configuration.localWhisperPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimePath.isEmpty else {
            throw LocalWhisperError.runtimeNotConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            throw LocalWhisperError.runtimeUnavailable
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadAlong-Whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw LocalWhisperError.invalidDuration
        }
        let chunkLength = 60.0
        let chunkCount = Int(ceil(duration / chunkLength))
        var hasReadableChunk = false

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let start = Double(chunkIndex) * chunkLength
            let length = min(chunkLength, duration - start)
            let inputURL = chunkCount == 1
                ? url
                : try await exportChunk(from: asset, start: start, duration: length, index: chunkIndex, to: outputDirectory)
            defer { if chunkCount > 1 { try? FileManager.default.removeItem(at: inputURL) } }

            var arguments = [
                "-m", "whispermlx", inputURL.path,
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

            let result = try await run(
                executable: runtimePath,
                arguments: arguments,
                background: hasReadableChunk
            )
            try Task.checkCancellation()
            guard result.status == 0 else {
                throw LocalWhisperError.processFailed(summary(of: result.output))
            }
            let jsonURL = outputDirectory
                .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: jsonURL.path) else {
                throw LocalWhisperError.outputMissing
            }
            let transcription = try parse(data: Data(contentsOf: jsonURL))
            let shifted = LLMTranscription(
                text: transcription.text,
                words: transcription.words.map {
                    TimedTranscriptWord(text: $0.text, start: start + $0.start, end: start + $0.end)
                }
            )
            onChunk(shifted, chunkIndex + 1, chunkCount)
            if !shifted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !shifted.words.isEmpty {
                hasReadableChunk = true
            }
        }
    }

    private static func exportChunk(from asset: AVAsset, start: Double, duration: Double, index: Int, to directory: URL) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw LocalWhisperError.exportUnavailable
        }
        let outputURL = directory.appendingPathComponent(String(format: "chunk_%04d.m4a", index))
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        try await exporter.export(to: outputURL, as: .m4a)
        return outputURL
    }

    private static func parse(data: Data) throws -> LLMTranscription {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["text"] is String || json["segments"] is [[String: Any]] else {
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
        return LLMTranscription(text: text, words: words)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func summary(of output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
        if let error = lines.last(where: { $0.localizedCaseInsensitiveContains("error:") }) {
            return String(error)
        }
        return String(lines.last ?? "未知错误")
    }

    private static func run(
        executable: String,
        arguments: [String],
        background: Bool
    ) async throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        let cancellable = CancellableProcess()
        let process = cancellable.process
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: background ? .utility : .userInitiated).async {
                    do {
                        let logURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ReadAlong-Whisper-log-\(UUID().uuidString)")
                        FileManager.default.createFile(atPath: logURL.path, contents: nil)
                        let log = try FileHandle(forWritingTo: logURL)
                        defer {
                            try? log.close()
                            try? FileManager.default.removeItem(at: logURL)
                        }
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = arguments
                        // The model downloader cannot use an inherited SOCKS proxy
                        // without socksio, so the subprocess uses a direct connection.
                        var environment = ProcessInfo.processInfo.environment
                        for key in ["ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"] {
                            environment.removeValue(forKey: key)
                        }
                        process.environment = environment
                        process.standardOutput = log
                        process.standardError = log
                        try cancellable.start()
                        process.waitUntilExit()
                        try log.synchronize()
                        let output = String(data: try Data(contentsOf: logURL), encoding: .utf8) ?? ""
                        continuation.resume(returning: (
                            process.terminationStatus,
                            output
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellable.cancel()
        }
    }
}

private enum LocalWhisperError: LocalizedError {
    case runtimeNotConfigured
    case runtimeUnavailable
    case invalidDuration
    case exportUnavailable
    case outputMissing
    case outputInvalid
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotConfigured: return "请在偏好设置中填写 Python / Whisper 运行时路径。"
        case .runtimeUnavailable: return "指定的 Python / Whisper 运行时不可执行。"
        case .invalidDuration: return "无法读取音频时长。"
        case .exportUnavailable: return "当前设备无法分段处理该音频。"
        case .outputMissing: return "本地 Whisper 未生成转写文件。"
        case .outputInvalid: return "本地 Whisper 的转写文件格式无效。"
        case .processFailed(let message): return "本地 Whisper 运行失败：\(message)"
        }
    }
}

private enum Keychain {
    private static let service = "ReadAlong.LLM"
    private static let legacyService = "EnglishReader.LLM"
    private static let account = "apiKey"

    static func save(_ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    static func load() -> String? {
        load(service: service) ?? load(service: legacyService)
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
