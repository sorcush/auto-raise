import Foundation

/// Owns ~/.config/AutoRaise/config. Only ever rewrites the `delay=` line,
/// leaving every other line (ignoreApps, ignoreTitles, etc.) untouched.
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/AutoRaise/config")
    }

    /// Pure: return `contents` with `delay=` set to `units`, preserving other lines.
    static func settingDelay(_ units: Int, in contents: String) -> String {
        var lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("delay=") {
                lines[i] = "delay=\(units)"
                replaced = true
                break
            }
        }
        if !replaced {
            if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
                lines = ["#AutoRaise config file", "delay=\(units)"]
            } else {
                lines.append("delay=\(units)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Read current file (or empty), set delay, write back (creating dirs).
    static func writeDelay(_ units: Int) throws {
        let fm = FileManager.default
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = settingDelay(units, in: existing)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
