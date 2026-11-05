import AppKit
import CoreGraphics

/// Aggregate system counters, never key codes, characters or field contents.
/// These counters advance even while the main thread is waiting for an AX reply.
struct InputEventCounts: Equatable {
    var left: UInt32 = 0
    var right: UInt32 = 0
    var keys: UInt32 = 0

    static func current() -> InputEventCounts {
        InputEventCounts(
            left: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown),
            right: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown),
            keys: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))
    }

    func matches(baseline: InputEventCounts, allowed: InputEventCounts) -> Bool {
        // Exact equality prevents an unused allowance from hiding another input.
        left &- baseline.left == allowed.left && right &- baseline.right == allowed.right &&
            keys &- baseline.keys == allowed.keys
    }
}

/// Supplements the main-thread NSEvent monitor for Codex's missing-field fallback.
/// Forward is an otherMouse event and needs no allowance here; the existing event
/// monitor still checks other buttons and application changes.
final class InputCounterGuard {
    private var baseline: InputEventCounts?
    private var allowed = InputEventCounts()

    func beginCapture() {
        allowed = InputEventCounts()
        baseline = .current()
    }

    // Called only for a Carbon-confirmed dictation hotkey press after capture.
    func allowF18Press() {
        guard baseline != nil else { return }
        allowed.keys &+= 1
    }

    // Called from the local monitor, before the nonactivating HUD handles the click.
    func allowHUDClick(_ event: NSEvent) {
        guard baseline != nil else { return }
        if event.type == .leftMouseDown { allowed.left &+= 1 }
        else if event.type == .rightMouseDown { allowed.right &+= 1 }
    }

    func rejection() -> String? {
        guard let baseline = baseline else { return "input_counter_baseline_missing" }
        return InputEventCounts.current().matches(baseline: baseline, allowed: allowed)
            ? nil : "user_navigation_since_capture"
    }
}
