import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL: \(msg)"); failures += 1 } else { print("ok:   \(msg)") }
}

// DelayConversion (pollMillis = 5 => 5ms steps; delay unit N = (N-1)*5 ms)
check(DelayConversion.delayUnits(fromMs: 0) == 1, "0ms -> 1 unit")
check(DelayConversion.delayUnits(fromMs: 5) == 2, "5ms -> 2 units")
check(DelayConversion.delayUnits(fromMs: 50) == 11, "50ms -> 11 units")
check(DelayConversion.delayUnits(fromMs: 200) == 41, "200ms -> 41 units")
check(DelayConversion.delayUnits(fromMs: 5000) == 401, "5000ms clamps to 2000 -> 401 units")
check(DelayConversion.clampMs(72) == 70, "72ms snaps to 70")
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

// generic setter works for other keys and preserves the delay line
let out4 = ConfigFile.setting("pollMillis", 5, in: "delay=11\nignoreApps=\"X\"")
check(out4.contains("pollMillis=5"), "sets pollMillis")
check(out4.contains("delay=11") && out4.contains("ignoreApps=\"X\""), "generic setter preserves others")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL PASS")
