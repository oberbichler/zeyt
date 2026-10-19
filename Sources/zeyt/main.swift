import AppKit

// Before AppDelegate() reads any setting. The UI test build has its own settings and takes nothing over.
#if !ZEYT_UITEST
Migration.run()
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
