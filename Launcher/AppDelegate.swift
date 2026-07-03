import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = EngineController()
    private var prefsWindow: PreferencesWindowController?
    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var delayMs: Int {
        get { defaults.object(forKey: "delayMs") as? Int ?? 200 }
        set { defaults.set(DelayConversion.clampMs(newValue), forKey: "delayMs") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildMenu),
            name: .engineStateChanged, object: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                   accessibilityDescription: "AutoRaise")
            button.image?.isTemplate = true
        }
        rebuildMenu()
        if enabled { engine.start(delayMs: delayMs) }
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Enable AutoRaise",
            action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = (enabled && engine.isRunning) ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        if let err = engine.lastError {
            let item = NSMenuItem(title: "⚠︎ \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let delayItem = NSMenuItem(title: "Delay: \(delayMs) ms…",
            action: #selector(openPreferences), keyEquivalent: "")
        delayItem.target = self
        menu.addItem(delayItem)

        let login = NSMenuItem(title: "Start at Login",
            action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AutoRaise",
            action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled { engine.start(delayMs: delayMs) } else { engine.stop() }
        rebuildMenu()
    }

    @objc private func openPreferences() {
        if prefsWindow == nil {
            prefsWindow = PreferencesWindowController(initialMs: delayMs) { [weak self] newMs in
                guard let self else { return }
                self.delayMs = newMs
                if self.enabled { self.engine.start(delayMs: self.delayMs) }
                self.rebuildMenu()
            }
        }
        prefsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        rebuildMenu()
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
}
