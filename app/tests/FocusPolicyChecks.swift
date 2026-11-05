import Foundation
import AppKit

@main
enum FocusPolicyChecks {
    static func main() {
        var checked = 0
        func expect(_ name: String, _ facts: FocusPolicyFacts, _ reason: String?) {
            let actual = FocusPolicy.rejection(facts)
            precondition(actual == reason, "\(name): expected \(String(describing: reason)); got \(String(describing: actual))")
            checked += 1
        }
        let strict = FocusPolicyFacts()
        expect("same AX field", strict, nil)
        var f = strict; f.sameElement = false
        expect("different AX field", f, "focused_element_changed")
        f = strict; f.currentHasElement = false
        expect("valid baseline never falls back to a window", f, "focused_element_unavailable")
        f = strict; f.sameInteraction = false
        expect("strict field path retains existing behavior", f, nil)
        f = strict; f.originalHasWindow = false; f.currentHasWindow = false
        expect("strict element alone remains usable when window was unavailable", f, nil)

        var fallback = strict
        fallback.fallback = true
        fallback.originalHasElement = false
        fallback.currentHasElement = false
        fallback.permitsAbsentElement = true
        expect("unchanged Codex window and no navigation", fallback, nil)
        f = fallback; f.sameInteraction = false
        expect("Codex user navigation", f, "user_navigation_since_capture")
        f = fallback; f.currentHasElement = true
        expect("Codex now exposes a field", f, "focused_element_became_available")
        f = fallback; f.permitsAbsentElement = false
        expect("Codex transient AX read failure", f, "focused_element_read_failed")
        f = fallback; f.originalHasWindow = false
        expect("Codex missing original window", f, "original_window_unavailable")

        for (name, baseline) in [("strict", strict), ("Codex", fallback)] {
            f = baseline; f.authorized = false
            expect(name + " permission removed", f, "accessibility_not_authorized")
            f = baseline; f.sameApp = false
            expect(name + " changed PID or bundle", f, "foreground_application_changed")
            f = baseline; f.captureUsable = false; f.captureReason = "foreground_changed_during_capture"
            expect(name + " foreground changed during read", f, "foreground_changed_during_capture")
            f = baseline; f.secureField = true
            expect(name + " secure field", f, "secure_field")
            f = baseline; f.currentHasWindow = false
            expect(name + " missing current window", f, "focused_window_unavailable")
            f = baseline; f.sameWindow = false
            expect(name + " changed window", f, "focused_window_changed")
        }
        func counters(_ name: String, _ current: InputEventCounts, _ baseline: InputEventCounts,
                      _ allowed: InputEventCounts, _ expected: Bool) {
            precondition(current.matches(baseline: baseline, allowed: allowed) == expected, name)
            checked += 1
        }
        let baseline = InputEventCounts(left: 100, right: 200, keys: 300)
        let none = InputEventCounts()
        counters("unchanged system input", baseline, baseline, none, true)
        counters("queued left click", InputEventCounts(left: 101, right: 200, keys: 300), baseline, none, false)
        counters("queued right click", InputEventCounts(left: 100, right: 201, keys: 300), baseline, none, false)
        counters("queued key", InputEventCounts(left: 100, right: 200, keys: 301), baseline, none, false)
        counters("confirmed HUD click", InputEventCounts(left: 101, right: 200, keys: 300), baseline,
                 InputEventCounts(left: 1), true)
        counters("confirmed F18", InputEventCounts(left: 100, right: 200, keys: 301), baseline,
                 InputEventCounts(keys: 1), true)
        counters("HUD click does not hide another click", InputEventCounts(left: 102, right: 200, keys: 300), baseline,
                 InputEventCounts(left: 1), false)
        counters("F18 does not hide another key", InputEventCounts(left: 100, right: 200, keys: 302), baseline,
                 InputEventCounts(keys: 1), false)
        counters("unused allowance rejects", baseline, baseline, InputEventCounts(keys: 1), false)
        counters("UInt32 counter wrap", InputEventCounts(), InputEventCounts(left: UInt32.max),
                 InputEventCounts(left: 1), true)
        func shortcut(_ name: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                      _ primary: Bool, _ f18: Bool, _ expected: Bool) {
            precondition(DictationShortcut.matches(keyCode: keyCode, flags: flags,
                primaryAvailable: primary, f18Available: f18) == expected, name)
            checked += 1
        }
        shortcut("registered Ctrl Shift Space", 49, [.control, .shift], true, true, true)
        shortcut("ordinary space is navigation", 49, [], true, true, false)
        shortcut("extra Command is navigation", 49, [.control, .shift, .command], true, true, false)
        shortcut("missing Shift is navigation", 49, [.control], true, true, false)
        shortcut("unregistered primary is navigation", 49, [.control, .shift], false, true, false)
        shortcut("Caps Lock does not alter the shortcut", 49, [.control, .shift, .capsLock], true, true, true)
        shortcut("registered F18", 79, [], true, true, true)
        shortcut("unregistered F18 is navigation", 79, [], true, false, false)
        shortcut("modified F18 is navigation", 79, [.control], true, true, false)
        print("Focus policy: \(checked) checks passed")
    }
}
