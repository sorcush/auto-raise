import Foundation

/// Owns ~/.config/AutoRaise/config. Only ever rewrites the `delay=` line,
/// leaving every other line (ignoreApps, ignoreTitles, etc.) untouched.
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/AutoRaise/config")
    }

    /// Pure: return `contents` with `key=` set to `value`, preserving other lines.
    static func setting(_ key: String, _ value: Int, in contents: String) -> String {
        var lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("\(key)=") {
                lines[i] = "\(key)=\(value)"
                replaced = true
                break
            }
        }
        if !replaced {
            if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
                lines = ["#AutoRaise config file", "\(key)=\(value)"]
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Pure: return `contents` with `delay=` set to `units`, preserving other lines.
    static func settingDelay(_ units: Int, in contents: String) -> String {
        setting("delay", units, in: contents)
    }

    /// Read current file (or empty), set delay + pollMillis, write back (creating dirs).
    /// pollMillis is written so the engine's delay resolution matches the UI step.
    static func writeDelay(_ units: Int) throws {
        let fm = FileManager.default
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var updated = setting("delay", units, in: existing)
        updated = setting("pollMillis", DelayConversion.pollMillis, in: updated)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
