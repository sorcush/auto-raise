import Foundation
import AppKit

/// Runs the embedded AutoRaiseEngine binary as a subprocess.
final class EngineController {
    private var process: Process?
    private(set) var lastError: String?

    var isRunning: Bool { process?.isRunning ?? false }

    private var engineURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AutoRaiseEngine")
    }

    /// Write the delay into the config file, then launch the engine ARGLESS so it
    /// reads ~/.config/AutoRaise/config in full (preserving the user's settings).
    func start(delayMs: Int) {
        stop()
        lastError = nil
        do {
            try ConfigFile.writeDelay(DelayConversion.delayUnits(fromMs: delayMs))
        } catch {
            lastError = "Could not write config: \(error.localizedDescription)"
            notifyChanged()
            return
        }
        guard FileManager.default.isExecutableFile(atPath: engineURL.path) else {
            lastError = "Engine binary missing or not executable"
            notifyChanged()
            return
        }
        let p = Process()
        p.executableURL = engineURL
        p.arguments = [] // argless => full config file is read
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if proc.terminationStatus != 0 {
                    self.lastError = "Engine exited unexpectedly (status \(proc.terminationStatus))"
                }
                self.notifyChanged()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            lastError = "Could not start engine: \(error.localizedDescription)"
            process = nil
        }
        notifyChanged()
    }

    func stop() {
        guard let p = process, p.isRunning else { process = nil; return }
        p.terminationHandler = nil
        p.terminate()
        // Bounded wait OFF the main thread; escalate to SIGKILL if it lingers.
        let pid = p.processIdentifier
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(pid, SIGKILL) }
        }
        process = nil
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .engineStateChanged, object: nil)
    }
}

extension Notification.Name {
    static let engineStateChanged = Notification.Name("engineStateChanged")
}
