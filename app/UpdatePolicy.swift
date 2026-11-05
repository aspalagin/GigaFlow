import Foundation

/// A snapshot of work that would be lost or interrupted by restarting the app.
struct UpdateSafetyState {
    let mode: RecordingMode
    let hasPendingRequest: Bool
    let clipboardInUse: Bool
    let hasUnclaimedText: Bool
    let secondsSinceActivity: TimeInterval
    let systemIdleSeconds: TimeInterval
}

enum UpdatePolicy {
    /// Manual installation skips the system-idle requirement, but never
    /// interrupts dictation or discards a result awaiting the user's action.
    static func canInstall(_ state: UpdateSafetyState, manuallyRequested: Bool) -> Bool {
        guard state.mode == .ready || state.mode == .failed,
              !state.hasPendingRequest,
              !state.clipboardInUse,
              !state.hasUnclaimedText,
              state.secondsSinceActivity.isFinite else { return false }

        if manuallyRequested {
            return state.secondsSinceActivity >= 2
        }
        return state.secondsSinceActivity >= 30 &&
            state.systemIdleSeconds.isFinite && state.systemIdleSeconds >= 30
    }
}
