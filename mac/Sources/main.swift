import AppKit

// Top-level code always runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate() // app.delegate is weak; run() blocks, so this stays alive
    app.delegate = delegate
    app.run()
}
