import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct EnglishReaderApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(EnglishReaderAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 680, minHeight: 560)
        }
    }
}

#if os(macOS)
final class EnglishReaderAppDelegate: NSObject, NSApplicationDelegate {
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
