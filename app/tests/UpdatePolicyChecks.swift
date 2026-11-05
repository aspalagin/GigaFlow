import Foundation

@main
enum UpdatePolicyChecks {
    static func main() {
        var checked = 0
        var failures = [String]()

        func state(_ mode: RecordingMode = .ready, pending: Bool = false,
                   clipboard: Bool = false, unclaimed: Bool = false,
                   activity: TimeInterval = 60, idle: TimeInterval = 60) -> UpdateSafetyState {
            UpdateSafetyState(mode: mode, hasPendingRequest: pending,
                              clipboardInUse: clipboard, hasUnclaimedText: unclaimed,
                              secondsSinceActivity: activity, systemIdleSeconds: idle)
        }
        func expect(_ name: String, _ snapshot: UpdateSafetyState,
                    manual: Bool, allowed: Bool) {
            checked += 1
            if UpdatePolicy.canInstall(snapshot, manuallyRequested: manual) != allowed {
                failures.append(name)
            }
        }

        for manual in [false, true] {
            let kind = manual ? "manual" : "background"
            expect("\(kind): ready idle app may update", state(), manual: manual, allowed: true)
            expect("\(kind): failed model may be repaired by an update",
                   state(.failed), manual: manual, allowed: true)
            for mode in [RecordingMode.loading, .recording, .processing] {
                expect("\(kind): \(mode) must not be interrupted",
                       state(mode), manual: manual, allowed: false)
            }
            expect("\(kind): ready state does not override an outstanding request",
                   state(pending: true), manual: manual, allowed: false)
            expect("\(kind): temporary pasteboard must be restored first",
                   state(clipboard: true), manual: manual, allowed: false)
            expect("\(kind): recognized text awaiting action must be kept",
                   state(unclaimed: true), manual: manual, allowed: false)
            expect("\(kind): failure does not discard a pending request",
                   state(.failed, pending: true), manual: manual, allowed: false)
            expect("\(kind): failure does not discard a temporary clipboard",
                   state(.failed, clipboard: true), manual: manual, allowed: false)
            expect("\(kind): failure does not discard an unclaimed result",
                   state(.failed, unclaimed: true), manual: manual, allowed: false)
            for interval in [-1.0, -Double.infinity, Double.infinity, Double.nan] {
                expect("\(kind): invalid activity interval \(interval) is rejected",
                       state(activity: interval), manual: manual, allowed: false)
            }
        }

        expect("background: both thresholds are inclusive", state(activity: 30, idle: 30),
               manual: false, allowed: true)
        expect("background: application activity just before threshold postpones",
               state(activity: 30.0.nextDown, idle: 60), manual: false, allowed: false)
        expect("background: system activity just before threshold postpones",
               state(activity: 60, idle: 30.0.nextDown), manual: false, allowed: false)
        expect("background: elapsed app time alone is insufficient", state(activity: 3600, idle: 0),
               manual: false, allowed: false)
        expect("background: system idle alone is insufficient", state(activity: 0, idle: 3600),
               manual: false, allowed: false)
        for interval in [-1.0, -Double.infinity, Double.infinity, Double.nan] {
            expect("background: invalid system idle \(interval) is rejected",
                   state(idle: interval), manual: false, allowed: false)
        }

        expect("manual: two seconds after activity permits installation",
               state(activity: 2, idle: 0), manual: true, allowed: true)
        expect("manual: still waits for activity to settle",
               state(activity: 2.0.nextDown, idle: 3600), manual: true, allowed: false)
        expect("manual: immediate request cannot interrupt final work",
               state(activity: 0), manual: true, allowed: false)
        for interval in [0.0, -1.0, -Double.infinity, Double.infinity, Double.nan] {
            expect("manual: system idle counter \(interval) is not required",
                   state(activity: 2, idle: interval), manual: true, allowed: true)
        }

        for failure in failures { print("FAIL: \(failure)") }
        precondition(failures.isEmpty, "\(failures.count) update safety checks failed")
        print("Update safety: \(checked) checks passed")
    }
}
