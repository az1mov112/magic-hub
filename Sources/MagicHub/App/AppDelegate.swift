import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var logo: LogoStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotchManager.shared.start()
        logo = LogoStatusItem()
        StatusBarController.shared.start()
        AwakeController.shared.start()
        NowPlayingModel.shared.start()
        ClipboardWatcher.shared.start()
        JarvisMonitor.shared.start()
        ClaudeUsageMonitor.shared.start()
        Updater.shared.start()
        MediaKeyInterceptor.shared.start()
        PermissionsCenter.shared.onboardIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Важно: вернуть Mac обычный сон, иначе после выхода он так и не будет засыпать.
        AwakeController.shared.shutdown()
        FanController.shared.restoreAutomatic()
        NowPlayingModel.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
