import AppKit
import Sparkle

/// Sparkle owns downloading, signature verification and atomic replacement.
/// GigaFlow only decides when a restart will not interrupt dictation.
final class UpdatesController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private let safety: () -> UpdateSafetyState
    private let enabled: Bool
    private let info = NSMenuItem(title: "Обновления готовятся…", action: nil, keyEquivalent: "")
    private let check = NSMenuItem(title: "Проверить обновления…", action: nil, keyEquivalent: "")
    private let automatic = NSMenuItem(title: "Обновлять автоматически", action: nil, keyEquivalent: "")
    private var backgroundInstall: (() -> Void)?
    private var postponedRelaunch: (() -> Void)?
    private var manualInstallRequested = false
    private var started = false
    private var pendingVersion: String?
    private(set) var isInstalling = false
    private(set) var status = "starting"

    init(menu: NSMenu, enabled: Bool, safety: @escaping () -> UpdateSafetyState) {
        self.safety = safety
        self.enabled = enabled
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        info.isEnabled = false
        check.target = self; check.action = #selector(checkNow)
        automatic.target = self; automatic.action = #selector(toggleAutomatic)
        menu.addItem(info); menu.addItem(check); menu.addItem(automatic)
        refreshMenu()
    }

    func start() {
        guard enabled else {
            status = "development_build"
            info.title = "Обновления доступны в готовой версии"
            refreshMenu(); return
        }
        do {
            try controller.updater.start()
            started = true
            status = "scheduled"; info.title = "Обновления: проверка каждые 6 часов"
            if controller.updater.automaticallyChecksForUpdates {
                // Sparkle permits this extra check only immediately after start.
                controller.updater.checkForUpdatesInBackground()
            }
        } catch {
            status = "configuration_error"
            info.title = "Обновления недоступны — проверьте установку"
        }
        refreshMenu()
    }

    @objc private func checkNow() {
        guard started else { return }
        if pendingVersion != nil, backgroundInstall != nil || postponedRelaunch != nil {
            if safety().hasUnclaimedText {
                let alert = NSAlert()
                alert.messageText = "Сначала сохраните последнюю диктовку"
                alert.informativeText = "Текст не был вставлен. Выберите «Скопировать последний текст» в меню GigaFlow, затем повторите обновление."
                alert.addButton(withTitle: "Понятно"); alert.runModal()
                return
            }
            manualInstallRequested = true
            tick()
        } else if controller.updater.canCheckForUpdates {
            controller.checkForUpdates(nil)
        }
    }

    @objc private func toggleAutomatic() {
        let next = !(controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates)
        controller.updater.automaticallyDownloadsUpdates = next
        controller.updater.automaticallyChecksForUpdates = next
        refreshMenu()
    }

    func tick() {
        refreshMenu()
        let automaticEnabled = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
        guard !isInstalling, manualInstallRequested || automaticEnabled,
              UpdatePolicy.canInstall(safety(), manuallyRequested: manualInstallRequested) else { return }
        if let install = postponedRelaunch {
            postponedRelaunch = nil
            isInstalling = true; status = "installing"
            install()
        } else if let install = backgroundInstall {
            backgroundInstall = nil
            status = "installing"
            // shouldPostponeRelaunchForUpdate rechecks the latest app state.
            install()
        }
    }

    private func refreshMenu() {
        automatic.isEnabled = enabled && started && !isInstalling
        automatic.state = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates ? .on : .off
        check.isEnabled = enabled && started && !isInstalling &&
            (controller.updater.canCheckForUpdates || backgroundInstall != nil || postponedRelaunch != nil)
        if let version = pendingVersion, backgroundInstall != nil || postponedRelaunch != nil {
            check.title = "Установить GigaFlow \(version)…"
            info.title = safety().hasUnclaimedText ? "Обновление ждёт сохранения диктовки" : "Обновление готово — ждёт паузы"
        } else {
            check.title = "Проверить обновления…"
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingVersion = item.displayVersionString
        backgroundInstall = immediateInstallHandler
        status = "waiting_for_idle"; refreshMenu()
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingVersion = item.displayVersionString
        let automaticEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        if (manualInstallRequested || automaticEnabled) && UpdatePolicy.canInstall(safety(), manuallyRequested: manualInstallRequested) {
            isInstalling = true; status = "installing"
            return false
        }
        postponedRelaunch = installHandler
        status = "waiting_for_idle"; refreshMenu()
        return true
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .install { manualInstallRequested = true }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingVersion = item.displayVersionString
        status = "update_available"; info.title = "Доступен GigaFlow \(item.displayVersionString)"
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = "downloading"; info.title = "Загружается GigaFlow \(item.displayVersionString)…"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Installation can fail after relaunch was approved. Never leave
        // recording disabled or retain callbacks from an ended Sparkle cycle.
        let available = pendingVersion
        backgroundInstall = nil; postponedRelaunch = nil
        manualInstallRequested = false; isInstalling = false; pendingVersion = nil
        if let error = error as NSError?,
           !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) {
            status = "check_failed"; info.title = "Не удалось обновить — повторим позже"
        } else if error == nil, let available = available {
            status = "update_available"; info.title = "Доступен GigaFlow \(available)"
        } else {
            status = "up_to_date"; info.title = "Установлена последняя версия"
        }
        refreshMenu()
    }

    // Scheduled checks must not take focus away from the text being dictated.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        pendingVersion = update.displayVersionString
        info.title = "Доступен GigaFlow \(update.displayVersionString) — открыть проверку обновлений"
        refreshMenu()
    }
}
