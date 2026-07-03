import Foundation
import ServiceManagement

/// Start-at-login via ServiceManagement (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success; reflects ACTUAL registration state, not intent.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("AutoRaise: login item toggle failed: \(error)")
            return false
        }
    }
}
