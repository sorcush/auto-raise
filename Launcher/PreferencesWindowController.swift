import AppKit

/// A tiny window with a text field + stepper for the focus delay (ms).
final class PreferencesWindowController: NSWindowController {
    private let onChange: (Int) -> Void
    private let field = NSTextField()
    private let stepper = NSStepper()

    init(initialMs: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
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
        label.frame = NSRect(x: 20, y: 72, width: 320, height: 18)
        content.addSubview(label)

        field.frame = NSRect(x: 20, y: 34, width: 90, height: 24)
        field.integerValue = initialMs
        field.target = self
        field.action = #selector(fieldChanged)
        content.addSubview(field)

        stepper.frame = NSRect(x: 114, y: 32, width: 20, height: 28)
        stepper.minValue = 0
        stepper.maxValue = Double(DelayConversion.maxDelayMs)
        stepper.increment = Double(DelayConversion.pollMillis)
        stepper.integerValue = initialMs
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        content.addSubview(stepper)

        let hint = NSTextField(labelWithString:
            "0–\(DelayConversion.maxDelayMs) ms, in \(DelayConversion.pollMillis) ms steps.")
        hint.frame = NSRect(x: 20, y: 8, width: 320, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
    }

    @objc private func fieldChanged() { apply(field.integerValue) }
    @objc private func stepperChanged() { apply(stepper.integerValue) }

    private func apply(_ raw: Int) {
        let ms = DelayConversion.clampMs(raw)
        field.integerValue = ms   // revert invalid/out-of-range to a valid value
        stepper.integerValue = ms
        onChange(ms)
    }
}
