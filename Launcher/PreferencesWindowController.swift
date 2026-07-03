import AppKit

/// A tiny window with a text field + stepper for the focus delay (ms) and a
/// Set button that applies the value and closes the window.
final class PreferencesWindowController: NSWindowController {
    private let onChange: (Int) -> Void
    private let field = NSTextField()
    private let stepper = NSStepper()

    init(initialMs: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AutoRaise Preferences"
        super.init(window: window)
        window.center()
        buildUI(initialMs: DelayConversion.clampMs(initialMs))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI(initialMs: Int) {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString:
            "Focus delay after crossing a display (ms):")
        label.frame = NSRect(x: 20, y: 102, width: 320, height: 18)
        content.addSubview(label)

        field.frame = NSRect(x: 20, y: 64, width: 90, height: 24)
        field.integerValue = initialMs
        field.target = self
        field.action = #selector(fieldEdited)
        content.addSubview(field)

        stepper.frame = NSRect(x: 114, y: 62, width: 20, height: 28)
        stepper.minValue = 0
        stepper.maxValue = Double(DelayConversion.maxDelayMs)
        stepper.increment = Double(DelayConversion.pollMillis)
        stepper.integerValue = initialMs
        stepper.target = self
        stepper.action = #selector(stepperEdited)
        content.addSubview(stepper)

        let hint = NSTextField(labelWithString:
            "0–\(DelayConversion.maxDelayMs) ms, in \(DelayConversion.pollMillis) ms steps.")
        hint.frame = NSRect(x: 20, y: 40, width: 320, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        // Set applies the value and closes the window. Return also triggers it.
        let setButton = NSButton(title: "Set", target: self, action: #selector(setAndClose))
        setButton.bezelStyle = .rounded
        setButton.keyEquivalent = "\r"
        setButton.frame = NSRect(x: 260, y: 8, width: 80, height: 30)
        content.addSubview(setButton)
    }

    // Editing only keeps the field and stepper in sync + clamps for display;
    // nothing is applied until Set is pressed.
    @objc private func fieldEdited() { sync(field.integerValue) }
    @objc private func stepperEdited() { sync(stepper.integerValue) }

    private func sync(_ raw: Int) {
        let ms = DelayConversion.clampMs(raw)
        field.integerValue = ms
        stepper.integerValue = ms
    }

    @objc private func setAndClose() {
        let ms = DelayConversion.clampMs(field.integerValue)
        sync(ms)
        onChange(ms)        // writes config + restarts engine
        window?.close()
    }
}
