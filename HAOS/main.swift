import AppKit

// Top-level code isn't @MainActor-isolated, but process startup runs on the
// main thread, so this assumption always holds.
MainActor.assumeIsolated {
    // Opt out of Tahoe's automatic menu-item icons (gear on "Settings…" etc.).
    // Registered before NSApplication builds any menus.
    UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only — no Dock icon (paired with LSUIElement in Info.plist).
    app.setActivationPolicy(.accessory)
    app.run()
}
