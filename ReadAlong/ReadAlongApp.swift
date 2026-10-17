import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct ReadAlongApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(ReadAlongAppDelegate.self) private var appDelegate
#endif

    init() {
        LegacySettingsMigration.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 680, minHeight: 560)
        }
    }
}

private enum LegacySettingsMigration {
    private static let migrationKey = "didMigrateEnglishReaderSettings"
    private static let legacyBundleIdentifier = "com.example.EnglishReader"
    private static let keys = [
        "childModeEnabled",
        "childWordPause",
        "showsChineseTranslation",
        "didApplyOpenAIServiceDefaults",
        "llmBaseURL",
        "llmModel",
        "llmTranslationModel",
        "localWhisperEnabled",
        "localWhisperModel",
        "localWhisperModelDirectory",
        "localWhisperPythonPath",
        "elevenLabsSpeechEnabled",
        "elevenLabsSpeechModelID",
        "elevenLabsAmericanVoiceID",
        "elevenLabsBritishVoiceID",
    ]

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey),
              let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier) else { return }

        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacyDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}

#if os(macOS)
final class ReadAlongAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }
            .first

        guard let existingInstance else { return }
        existingInstance.activate(options: [])
        NSApp.terminate(nil)
    }
}
#endif
