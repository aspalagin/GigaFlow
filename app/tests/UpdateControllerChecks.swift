import AppKit
import Sparkle

/// Construct the public NSSecureCoding model without calling Sparkle's private
/// initializer. No download or real updater session is involved in these tests.
private final class UpdateStateDecoder: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int {
        precondition(key == "SPUUserUpdateStateStage")
        return SPUUserUpdateStage.downloaded.rawValue
    }
    override func decodeBool(forKey key: String) -> Bool {
        precondition(key == "SPUUserUpdateStateUserInitiated")
        return true
    }
}

@main
enum UpdateControllerChecks {
    @MainActor static func main() {
        // The check script must wrap this executable in its own test bundle.
        // Refuse to run against GigaFlow's live preferences or installation.
        let domain = "org.gigaflow.tests.update-controller"
        precondition(Bundle.main.bundleIdentifier == domain, "An isolated test app bundle is required")
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Starting is deliberately false: no feed fetch, timers or installer.
        let dummy = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        let updater = dummy.updater
        let item = SUAppcastItem(dictionary: [
            "title": "Fixture update", "sparkle:version": "2", "sparkle:shortVersionString": "0.0.2",
            "enclosure": ["url": "https://invalid.example/update.dmg", "length": "1", "type": "application/octet-stream"]
        ])!
        let choiceState = SPUUserUpdateState(coder: UpdateStateDecoder())!
        let failure = NSError(domain: "org.gigaflow.tests.failure", code: 1)
        var checked = 0
        var failures = [String]()
        func expect(_ condition: Bool, _ description: String) {
            checked += 1
            if !condition { failures.append(description) }
        }
        func state(_ mode: RecordingMode = .ready, pending: Bool = false,
                   clipboard: Bool = false, unclaimed: Bool = false,
                   activity: TimeInterval = 60, idle: TimeInterval = 60) -> UpdateSafetyState {
            UpdateSafetyState(mode: mode, hasPendingRequest: pending, clipboardInUse: clipboard,
                hasUnclaimedText: unclaimed, secondsSinceActivity: activity, systemIdleSeconds: idle)
        }
        func settings(checks: Bool = true, downloads: Bool = true) {
            defaults.set(checks, forKey: "SUEnableAutomaticChecks")
            defaults.set(downloads, forKey: "SUAutomaticallyUpdate")
        }

        settings()
        let selectors = UpdatesController(menu: NSMenu(), enabled: true, safety: { state() })
        for selector in [
            "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
            "updater:userDidMakeChoice:forUpdate:state:",
            "updater:didFindValidUpdate:",
            "updater:willDownloadUpdate:withRequest:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
            "supportsGentleScheduledUpdateReminders",
            "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
            "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"
        ] {
            expect(selectors.responds(to: NSSelectorFromString(selector)), "Sparkle can call \(selector)")
        }

        let busyCases: [(String, UpdateSafetyState)] = [
            ("loading", state(.loading)), ("recording", state(.recording)),
            ("processing", state(.processing)), ("pending request", state(pending: true)),
            ("clipboard lease", state(clipboard: true)), ("unclaimed text", state(unclaimed: true))
        ]
        for (name, busy) in busyCases {
            var snapshot = busy
            let subject = UpdatesController(menu: NSMenu(), enabled: true, safety: { snapshot })
            var calls = 0
            let handled = subject.updater(updater, willInstallUpdateOnQuit: item,
                immediateInstallationBlock: { calls += 1 })
            expect(handled, "background \(name): controller owns scheduling")
            subject.tick()
            expect(calls == 0, "background \(name): does not start installation")
            snapshot = state()
            subject.tick(); subject.tick()
            expect(calls == 1, "background \(name): installs once after becoming idle")
            subject.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        }

        for cancellation in [false, true] {
            let endedWith: Error? = cancellation ? nil : failure
            for postponed in [false, true] {
                var snapshot = state(.recording)
                let subject = UpdatesController(menu: NSMenu(), enabled: true, safety: { snapshot })
                var calls = 0
                if postponed {
                    expect(subject.updater(updater, shouldPostponeRelaunchForUpdate: item,
                        untilInvokingBlock: { calls += 1 }), "busy relaunch is postponed")
                } else {
                    _ = subject.updater(updater, willInstallUpdateOnQuit: item,
                        immediateInstallationBlock: { calls += 1 })
                }
                subject.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: endedWith)
                snapshot = state()
                subject.tick(); subject.tick()
                expect(calls == 0, "ended cycle discards \(postponed ? "relaunch" : "background") callback (cancel=\(cancellation))")
                expect(!subject.isInstalling, "ended cycle releases recording gate")
            }
        }

        do {
            let subject = UpdatesController(menu: NSMenu(), enabled: true, safety: { state() })
            expect(!subject.updater(updater, shouldPostponeRelaunchForUpdate: item,
                untilInvokingBlock: {}), "idle relaunch is approved immediately")
            expect(subject.isInstalling, "approved relaunch blocks new dictation")
            subject.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: failure)
            expect(!subject.isInstalling, "installation failure restores ability to dictate")
            expect(subject.status == "check_failed", "installation failure remains visible")
        }

        for (checks, downloads) in [(false, true), (true, false), (false, false)] {
            settings(checks: checks, downloads: downloads)
            let subject = UpdatesController(menu: NSMenu(), enabled: true, safety: { state() })
            var calls = 0
            _ = subject.updater(updater, willInstallUpdateOnQuit: item,
                immediateInstallationBlock: { calls += 1 })
            subject.tick()
            expect(calls == 0, "background respects settings checks=\(checks), downloads=\(downloads)")
            subject.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        }

        settings(checks: false, downloads: false)
        for (name, busy) in busyCases {
            var snapshot = busy
            let subject = UpdatesController(menu: NSMenu(), enabled: true, safety: { snapshot })
            var calls = 0
            subject.updater(updater, userDidMake: .install, forUpdate: item, state: choiceState)
            expect(subject.updater(updater, shouldPostponeRelaunchForUpdate: item,
                untilInvokingBlock: { calls += 1 }), "manual \(name): postpones relaunch")
            subject.tick()
            expect(calls == 0, "manual \(name): cannot bypass pending work")
            snapshot = state(activity: 2, idle: 0)
            subject.tick(); subject.tick()
            expect(calls == 1 && subject.isInstalling,
                "manual \(name): installs once after work completes, without system idle")
            subject.updater(updater, didFinishUpdateCycleFor: .updates, error: failure)
            expect(!subject.isInstalling, "manual error releases recording gate")
            _ = subject.updater(updater, willInstallUpdateOnQuit: item,
                immediateInstallationBlock: { calls += 1 })
            snapshot = state()
            subject.tick()
            expect(calls == 1, "manual authorization does not leak into the next cycle")
            subject.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        }

        do {
            let subject = UpdatesController(menu: NSMenu(), enabled: true, safety: { state() })
            subject.updater(updater, didFindValidUpdate: item)
            subject.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
            expect(subject.status != "up_to_date", "dismissal must not claim latest version is installed")
            let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
            subject.updater(updater, didFinishUpdateCycleFor: .updates, error: noUpdate)
            expect(subject.status == "up_to_date", "no-update response reports current version")
        }

        for failure in failures { print("FAIL: \(failure)") }
        precondition(failures.isEmpty, "\(failures.count) update controller checks failed")
        withExtendedLifetime(dummy) {}
        print("Update controller: \(checked) checks passed (isolated preferences, no update sessions)")
    }
}
