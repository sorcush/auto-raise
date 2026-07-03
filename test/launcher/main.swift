import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL: \(msg)"); failures += 1 } else { print("ok:   \(msg)") }
}

// DelayConversion
check(DelayConversion.delayUnits(fromMs: 0) == 1, "0ms -> 1 unit")
check(DelayConversion.delayUnits(fromMs: 50) == 2, "50ms -> 2 units")
check(DelayConversion.delayUnits(fromMs: 200) == 5, "200ms -> 5 units")
check(DelayConversion.delayUnits(fromMs: 5000) == 41, "5000ms clamps to 2000 -> 41 units")
check(DelayConversion.clampMs(70) == 50, "70ms snaps to 50")
check(DelayConversion.clampMs(-10) == 0, "negative clamps to 0")

// ConfigFile.settingDelay preserves other lines
let input = "#AutoRaise config file\nignoreApps=\"WebStorm\"\ndelay=1\npollMillis=50"
let out = ConfigFile.settingDelay(5, in: input)
check(out.contains("ignoreApps=\"WebStorm\""), "preserves ignoreApps")
check(out.contains("pollMillis=50"), "preserves pollMillis")
check(out.contains("delay=5") && !out.contains("delay=1"), "delay replaced 1 -> 5")

// appends when delay absent
let out2 = ConfigFile.settingDelay(3, in: "ignoreApps=\"X\"")
check(out2.contains("ignoreApps=\"X\"") && out2.contains("delay=3"), "appends delay, keeps line")

// empty input gets a header + delay
let out3 = ConfigFile.settingDelay(2, in: "")
check(out3.contains("#AutoRaise config file") && out3.contains("delay=2"), "empty -> header + delay")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL PASS")
