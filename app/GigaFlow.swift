import AppKit
import AVFoundation
import ApplicationServices
import Carbon

let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/gigaam-pilot")
let selfTesting = CommandLine.arguments.contains("--self-test")

final class Recognizer {
    var onEvent: (([String: Any]) -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "GigaFlow.worker-output")
    func start(audioDir: URL) {
        stop()
        let token = UUID(); generation = token
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = runtime.appendingPathComponent(".venv/bin/python")
        child.arguments = ["-u", Bundle.main.resourceURL!.appendingPathComponent("worker.py").path,
                           "--base", runtime.path, "--audio-dir", audioDir.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        child.environment = env
        child.standardInput = stdin; child.standardOutput = stdout
        // Diagnostics only; the worker never logs transcripts or audio.
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GigaFlow")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logDir.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        child.standardError = try? FileHandle(forWritingTo: log)
        process = child; input = stdin
        child.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                self.onEvent?(["type": "fatal", "message": "Распознавание остановилось (код \(p.terminationStatus)). Нажмите «Перезапустить модель»."])
            }
        }
        do {
            try child.run()
            queue.async { [weak self] in
                var buffer = Data()
                while true {
                    let data = stdout.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    if buffer.count > 1_048_576 { break }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                        DispatchQueue.main.async {
                            guard let self = self, self.generation == token else { return }
                            self.onEvent?(event)
                        }
                    }
                }
            }
        } catch { onEvent?(["type": "fatal", "message": "Не удалось запустить модель: \(error.localizedDescription)"]) }
    }
    func transcribe(_ url: URL, id: String) throws {
        guard let process = process, process.isRunning, let input = input else {
            throw NSError(domain: "GigaFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Модель не запущена"])
        }
        var data = try JSONSerialization.data(withJSONObject: ["type": "transcribe", "id": id, "path": url.path])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func stop() {
        generation = UUID()
        try? input?.fileHandleForWriting.close(); input = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }
}

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    static func capture(_ board: NSPasteboard) -> ClipboardSnapshot? {
        var result = [[NSPasteboard.PasteboardType: Data]](), count = 0
        for item in board.pasteboardItems ?? [] {
            var values = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                count += data.count
                if count > 16 * 1024 * 1024 { return nil }
                values[type] = data
            }
            result.append(values)
        }
        return ClipboardSnapshot(items: result)
    }
    func restore(_ board: NSPasteboard, ifUnchanged count: Int) {
        guard board.changeCount == count else { return }
        let objects = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        if !objects.isEmpty { board.writeObjects(objects) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    enum Mode { case loading, ready, recording, processing, failed }
    var mode: Mode = .loading
    let recognizer = Recognizer()
    var statusItem: NSStatusItem!
    var infoItem: NSMenuItem!, toggleItem: NSMenuItem!, copyItem: NSMenuItem!
    var hotKey: EventHotKeyRef?, eventHandler: EventHandlerRef?
    var hotkeyAvailable = false
    var ready = false, held = false
    var recorder: AVAudioRecorder?, recordingURL: URL?
    var recordingStarted: TimeInterval = 0
    var insertionGeneration = UUID()
    var target: InputTarget?, requestID: String?
    var lastText = "", message = "Подготавливаю модель…"
    var audioDir: URL!
    var timer: Timer?, deadline: DispatchWorkItem?
    var hud: NSPanel!, hudView: DictationHUDView!
    var hudMessage = ""
    var setup: NSWindow?, setupStatus: NSTextField?, micButton: NSButton?, axButton: NSButton?
    var resultWindow: NSWindow?
    var pasteRestore: (() -> Void)?
    var startupDeadline: DispatchWorkItem?
    var previousStatus: Data?
    var completedDictations = 0
    var outcome = "none"
    var lastPermissionCheck: TimeInterval = 0
    var triggerCount = 0
    var interactionSerial: UInt64 = 0
    let inputCounterGuard = InputCounterGuard()
    var globalInputMonitor: Any?, localInputMonitor: Any?, activationMonitor: NSObjectProtocol?
    var interactionMonitoringAvailable = false
    var dictationAuditID = ""
    var readyMessage: String { "Готово · нажмите Forward" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        audioDir = FileManager.default.temporaryDirectory.appendingPathComponent("GigaFlow-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { fatalError("Cannot create private audio directory: \(error)") }
        buildMenu(); buildHUD(); registerHotKey()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(bridgeStart), name: .init("local.arseniy.gigaflow.start"), object: "org.hammerspoon.Hammerspoon", suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(bridgeStop), name: .init("local.arseniy.gigaflow.stop"), object: "org.hammerspoon.Hammerspoon", suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(bridgePing), name: .init("local.arseniy.gigaflow.ping"), object: "org.hammerspoon.Hammerspoon", suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(bridgeToggle), name: .init("local.arseniy.gigaflow.toggle"), object: "org.hammerspoon.Hammerspoon", suspensionBehavior: .deliverImmediately)
        recognizer.onEvent = { [weak self] event in self?.workerEvent(event) }
        if selfTesting { runSelfTest(); return }
        installInteractionMonitoring()
        startRecognizer()
        timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !AXIsProcessTrusted() { showSetup(nil) }
    }

    func installInteractionMonitoring() {
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.trackInteraction(event)
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            if let self = self {
                if event.window === self.hud && (event.type == .leftMouseDown || event.type == .rightMouseDown) {
                    self.inputCounterGuard.allowHUDClick(event)
                } else { self.trackInteraction(event) }
            }
            return event
        }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.interactionSerial &+= 1 }
        interactionMonitoringAvailable = globalInputMonitor != nil && localInputMonitor != nil
    }

    func trackInteraction(_ event: NSEvent) {
        // Forward is the dictation command; all other input invalidates window-only fallback.
        if event.type == .otherMouseDown && event.buttonNumber == 4 { return }
        if event.type == .keyDown && event.keyCode == UInt16(kVK_F18) { return }
        interactionSerial &+= 1
    }

    func registerHotKey() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { app.mouseTrigger(down: down) }
            return noErr
        }, 2, &specs, pointer, &eventHandler)
        let id = EventHotKeyID(signature: 0x4749464C, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_F18), 0, id, GetApplicationEventTarget(), 0, &hotKey)
        hotkeyAvailable = installed == noErr && registered == noErr
        if installed != noErr || registered != noErr {
            message = "Резервная клавиша F18 занята. Forward работает через Hammerspoon."
        }
    }

    func mouseTrigger(down: Bool) {
        triggerCount += 1
        if down {
            guard !held else { return }; held = true
            if mode == .recording || mode == .processing { inputCounterGuard.allowF18Press() }
            toggleRecording()
        } else {
            held = false
        }
    }
    @objc func bridgeStart() { DispatchQueue.main.async { if self.mode == .ready { self.startRecording() } } }
    @objc func bridgeStop() { DispatchQueue.main.async { if self.mode == .recording { self.finishRecording() } } }
    @objc func bridgeToggle() { DispatchQueue.main.async { self.triggerCount += 1; self.toggleRecording() } }
    @objc func bridgePing() {
        DistributedNotificationCenter.default().postNotificationName(.init("local.arseniy.gigaflow.pong"), object: "local.arseniy.gigaflow", userInfo: nil, deliverImmediately: true)
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        infoItem = NSMenuItem(title: message, action: nil, keyEquivalent: ""); menu.addItem(infoItem)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Начать запись", action: #selector(toggleRecording), keyEquivalent: "")
        toggleItem.target = self; menu.addItem(toggleItem)
        let cancel = NSMenuItem(title: "Отменить запись / результат", action: #selector(cancelRecording), keyEquivalent: "")
        cancel.target = self; menu.addItem(cancel)
        menu.addItem(.separator())
        copyItem = NSMenuItem(title: "Скопировать последний текст", action: #selector(copyLast), keyEquivalent: "")
        copyItem.target = self; menu.addItem(copyItem)
        for (title, action) in [("Показать последний текст…", #selector(showResult)),
                                ("Настройка и разрешения…", #selector(showSetup(_:))),
                                ("Перезапустить модель", #selector(restartWorker)),
                                ("Выйти из GigaFlow", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
    }

    func buildHUD() {
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hudView = DictationHUDView(frame: hud.contentView!.bounds)
        hudView.onStop = { [weak self] in self?.finishRecording() }
        hudView.onCancel = { [weak self] in self?.cancelRecording() }
        hud.contentView = hudView
    }

    func showHUD(_ text: String, seconds: Double? = nil) {
        hudMessage = text
        let state = mode == .recording ? "recording" : mode == .processing ? "processing" : text == "Готово" ? "success" : mode == .failed ? "error" : "info"
        hudView.update(state: state, message: text)
        hud.setContentSize(hudView.preferredSize)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame { hud.setFrameOrigin(NSPoint(x: f.midX - hud.frame.width / 2, y: f.minY + 28)) }
        hud.orderFrontRegardless()
        if let seconds = seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self = self, self.mode != .recording, self.mode != .processing else { return }
                if self.hudMessage == text { self.hud.orderOut(nil) }
            }
        }
    }

    func refresh() {
        infoItem?.title = message
        toggleItem?.title = mode == .recording ? "Завершить запись" : "Начать запись"
        toggleItem?.isEnabled = mode == .ready || mode == .recording
        copyItem?.isEnabled = !lastText.isEmpty
        let symbol = mode == .recording ? "mic.fill" : (mode == .processing ? "ellipsis.circle" : "waveform")
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GigaFlow")
        statusItem?.button?.contentTintColor = mode == .recording ? .systemRed : nil
        statusItem?.button?.toolTip = "GigaFlow — \(message)"
    }

    func tick() {
        if mode == .recording, let recorder = recorder {
            recorder.updateMeters()
            let level = max(0, min(1, Double(recorder.averagePower(forChannel: 0) + 55) / 55))
            hudView.update(state: "recording", level: level, elapsed: recorder.currentTime)
        } else if mode == .processing { hudView.update(state: "processing") }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPermissionCheck >= 1 else { return }
        lastPermissionCheck = now
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        setupStatus?.stringValue = "\(mic ? "✓" : "○") Микрофон   ·   \(ax ? "✓" : "○") Вставка текста\n\(message)"
        micButton?.isEnabled = !mic; axButton?.isEnabled = !ax
        // Minimal local diagnostics, never audio or recognized text.
        let state: [String: Any] = ["mode": String(describing: mode), "ready": ready,
            "microphone": mic, "accessibility": ax, "hotkey": hotkeyAvailable,
            "completedDictations": completedDictations, "lastOutcome": outcome,
            "triggerCount": triggerCount, "message": message,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != previousStatus {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GigaFlow")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("status.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            previousStatus = data
        }
    }

    @objc func toggleRecording() {
        if mode == .recording { finishRecording() }
        else if mode == .ready { startRecording() }
        else if mode == .loading { showHUD("Модель ещё готовится…", seconds: 2) }
        else if mode == .failed { showHUD(message, seconds: 4) }
    }

    func startRecording() {
        guard mode == .ready else { return }
        insertionGeneration = UUID()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            message = "Нужно разрешение на микрофон"; refresh(); showSetup(nil); return
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            showHUD("Нет аудиовхода. Подключите микрофон.", seconds: 4); return
        }
        dictationAuditID = UUID().uuidString
        inputCounterGuard.beginCapture()
        target = InputTarget.capture(interactionSerial: interactionSerial)
        if !interactionMonitoringAvailable && target?.element == nil { target = nil }
        FocusAudit.record(event: "recording_start", details: ["requestID": dictationAuditID,
            "target": target?.metadata() ?? InputTarget.diagnoseCurrent(), "interactionSerial": interactionSerial])
        let url = audioDir.appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self; r.isMeteringEnabled = true
            guard r.prepareToRecord(), r.record(forDuration: 119) else {
                throw NSError(domain: "GigaFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
            }
            recorder = r; recordingURL = url; recordingStarted = ProcessInfo.processInfo.systemUptime
            mode = .recording; outcome = "recording"; message = "Идёт запись"
            showHUD("Запись · нажмите Forward для вставки"); refresh()
        } catch {
            try? FileManager.default.removeItem(at: url)
            showHUD("Ошибка микрофона: \(error.localizedDescription)", seconds: 5)
        }
    }

    func finishRecording() {
        guard mode == .recording, let recorder = recorder, let url = recordingURL else { return }
        let duration = max(recorder.currentTime, ProcessInfo.processInfo.systemUptime - recordingStarted)
        FocusAudit.record(event: "recording_stop", details: ["requestID": dictationAuditID,
            "current": InputTarget.diagnoseCurrent(), "interactionSerial": interactionSerial])
        mode = .processing; outcome = "processing"; recorder.stop(); self.recorder = nil
        if duration < 0.25 { resetAudio(); mode = .ready; message = readyMessage; hud.orderOut(nil); refresh(); return }
        let id = UUID().uuidString; requestID = id
        message = "Распознаю…"; showHUD(message); refresh()
        do { try recognizer.transcribe(url, id: id) }
        catch { failRequest(error.localizedDescription) }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.requestID == id else { return }
            self.recognizer.stop(); self.ready = false
            self.failRequest("Распознавание не ответило. Перезапустите модель из меню.")
        }
        deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard self.recorder === recorder else { return }
        if mode == .recording {
            if flag { finishRecording() }
            else { cancelRecording(); showHUD("Запись прервалась. Проверьте микрофон.", seconds: 4) }
        }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard self.recorder === recorder else { return }
        cancelRecording(); showHUD("Не удалось записать звук: \(error?.localizedDescription ?? "ошибка аудио")", seconds: 4)
    }
    func resetAudio() {
        deadline?.cancel(); deadline = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil; requestID = nil
    }
    @objc func cancelRecording() {
        insertionGeneration = UUID()
        let wasProcessing = mode == .processing
        mode = ready ? .ready : .loading
        recorder?.stop(); recorder = nil
        resetAudio(); target = nil
        outcome = "cancelled"; message = "Отменено"; hud.orderOut(nil); refresh()
        // Ignore the result by UUID; worker remains loaded for the next recording.
        if wasProcessing { message = "Отменено · модель завершает текущий запрос"; refresh() }
    }
    func failRequest(_ text: String) {
        resetAudio(); target = nil; mode = ready ? .ready : .failed
        outcome = "error"; message = text; showHUD(text, seconds: 6); refresh()
    }

    func workerEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if type == "ready" {
            startupDeadline?.cancel(); startupDeadline = nil
            ready = true; mode = .ready; message = readyMessage; refresh()
            if selfTesting {
                try? recognizer.transcribe(runtime.appendingPathComponent("samples/official-example.wav"), id: "875b091e-5927-4d93-bbfd-27dc7776b29a")
            }
        } else if type == "fatal" {
            startupDeadline?.cancel(); startupDeadline = nil
            if selfTesting { print("SELFTEST FAIL: \(event)"); exit(1) }
            ready = false
            recorder?.stop(); recorder = nil
            failRequest(event["message"] as? String ?? "Ошибка модели")
        } else if selfTesting && (type == "result" || type == "error") {
            let expected = "Ничьих не требуя похвал, Счастлив уж я надеждой сладкой, Что дева с трепетом любви Посмотрит, может быть, украдкой На песни грешные мои. У лукоморья дуб зелёный."
            let ok = (event["text"] as? String) == expected
            print("SELFTEST \(ok ? "PASS" : "FAIL"): native app → persistent MLX worker → exact reference; elapsed=\(event["elapsed"] ?? "?")")
            recognizer.stop(); exit(ok ? 0 : 1)
        } else if let id = event["id"] as? String, id == requestID {
            if type == "error" { failRequest(event["message"] as? String ?? "Ошибка распознавания"); return }
            guard type == "result" else { return }
            var text = (event["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove the model's final sentence period; preserve internal punctuation and ellipses.
            if text.hasSuffix(".") && !text.hasSuffix("..") { text.removeLast() }
            let destination = target
            resetAudio(); mode = .ready; target = nil
            if text.isEmpty { outcome = "empty_audio"; message = "Речь не обнаружена"; showHUD(message, seconds: 3); refresh(); return }
            completedDictations += 1; lastText = text; refresh()
            let token = UUID(); insertionGeneration = token
            insert(text, target: destination, token: token)
        }
    }

    func insert(_ text: String, target: InputTarget?, token: UUID, attempt: Int = 0) {
        guard token == insertionGeneration, mode == .ready else { return }
        let focusReason = target?.checkCurrent(interactionSerial: interactionSerial) ?? (target == nil ? "no_initial_target" : nil)
        guard let target = target, focusReason == nil, AXIsProcessTrusted() else {
            outcome = "copy_available"
            let reason = AXIsProcessTrusted() ? (focusReason ?? "no_initial_target") : "accessibility_denied"
            FocusAudit.record(event: "paste_blocked", details: ["requestID": dictationAuditID, "reason": reason,
                "target": target?.metadata() ?? [:], "current": InputTarget.diagnoseCurrent(), "interactionSerial": interactionSerial])
            if reason == "no_initial_target" { message = "Не удалось определить поле в начале записи. Текст доступен в меню." }
            else if reason == "accessibility_denied" { message = "Нужно разрешение на вставку. Текст доступен в меню." }
            else if reason == "user_navigation_since_capture" { message = "После начала записи был ввод или переключение. Текст доступен в меню." }
            else if reason == "focused_element_unavailable" { message = "Приложение не возвращает поле ввода. Текст доступен в меню." }
            else { message = "Фокус или окно изменились во время записи. Текст доступен в меню." }
            showHUD(message, seconds: 7); refresh(); return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.insert(text, target: target, token: token, attempt: attempt + 1) }
            } else { outcome = "copy_available"; message = "Текст готов — отпустите клавиши и скопируйте его через меню"; showHUD(message, seconds: 5); refresh() }
            return
        }
        pasteRestore?(); pasteRestore = nil
        let board = NSPasteboard.general
        guard let snapshot = ClipboardSnapshot.capture(board) else {
            outcome = "copy_available"; message = "Текст готов. Скопируйте его через меню GigaFlow."; showHUD(message, seconds: 5); refresh(); return
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return }
        let finalFocusReason = target.checkCurrent(interactionSerial: interactionSerial)
            ?? (target.element == nil ? inputCounterGuard.rejection() : nil)
        guard finalFocusReason == nil, token == insertionGeneration else {
            outcome = "copy_available"
            FocusAudit.record(event: "paste_blocked", details: ["requestID": dictationAuditID,
                "reason": finalFocusReason ?? "superseded",
                "target": target.metadata(), "current": InputTarget.diagnoseCurrent(), "interactionSerial": interactionSerial])
            message = "Фокус изменился. Текст доступен для копирования в меню."; showHUD(message, seconds: 5); refresh(); return
        }
        board.clearContents(); board.setString(text, forType: .string)
        let count = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        // Pasteboard providers can block the main thread too. Check immediately
        // before sending the paste, after all AX and clipboard operations.
        if target.element == nil, let reason = inputCounterGuard.rejection() {
            snapshot.restore(board, ifUnchanged: count)
            outcome = "copy_available"
            FocusAudit.record(event: "paste_blocked", details: ["requestID": dictationAuditID,
                "reason": reason, "target": target.metadata(), "interactionSerial": interactionSerial])
            message = "После начала записи был ввод или переключение. Текст доступен в меню."
            showHUD(message, seconds: 5); refresh(); return
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        outcome = "paste_sent"
        FocusAudit.record(event: "paste_sent", details: ["requestID": dictationAuditID,
            "target": target.metadata(), "interactionSerial": interactionSerial])
        let restore = { snapshot.restore(board, ifUnchanged: count) }
        pasteRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { restore() }
        message = "Текст передан в поле · готово"; showHUD("Готово", seconds: 1.5); refresh()
    }

    @objc func copyLast() {
        insertionGeneration = UUID()
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc func showResult() {
        guard !lastText.isEmpty else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 330), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Последняя диктовка · GigaFlow"; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.string = lastText; text.font = .systemFont(ofSize: 17)
        text.isEditable = false; text.textContainerInset = NSSize(width: 18, height: 18)
        text.autoresizingMask = [.width]; scroll.documentView = text
        window.contentView = scroll; resultWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSetup(_ sender: Any?) {
        if setup == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "GigaFlow"; window.isReleasedWhenClosed = false
            let view = window.contentView!
            func label(_ text: String, _ y: CGFloat, _ height: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSTextField {
                let l = NSTextField(wrappingLabelWithString: text); l.frame = NSRect(x: 28, y: y, width: 484, height: height)
                l.font = .systemFont(ofSize: size, weight: weight); view.addSubview(l); return l
            }
            _ = label("Голос → текст. На твоём Mac.", 308, 40, 24, .semibold)
            _ = label("Нажми Forward на MX Master 3S и говори.\nНажми ещё раз — текст появится в исходном поле.", 242, 56, 15)
            _ = label("Распознавание работает локально. Запись удаляется после обработки. Максимум — 119 секунд за раз.", 180, 48, 13)
            setupStatus = label("", 116, 56, 14)
            micButton = NSButton(title: "Разрешить микрофон", target: self, action: #selector(allowMicrophone))
            micButton!.frame = NSRect(x: 24, y: 62, width: 238, height: 34); micButton!.bezelStyle = .rounded; view.addSubview(micButton!)
            axButton = NSButton(title: "Разрешить вставку", target: self, action: #selector(allowAccessibility))
            axButton!.frame = NSRect(x: 278, y: 62, width: 238, height: 34); axButton!.bezelStyle = .rounded; view.addSubview(axButton!)
            _ = label("После выдачи разрешений закрой это окно и выбери поле для ввода.", 18, 32, 12)
            setup = window; window.center()
        }
        tick(); setup?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func allowMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.tick() } }
        } else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    }
    @objc func allowAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func restartWorker() {
        cancelRecording(); ready = false; mode = .loading; message = "Подготавливаю модель…"; refresh()
        startRecognizer()
    }
    func startRecognizer() {
        startupDeadline?.cancel()
        recognizer.start(audioDir: audioDir)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.ready else { return }
            self.recognizer.stop()
            self.failRequest("Модель не загрузилась за 90 секунд. Перезапустите её из меню.")
        }
        startupDeadline = work; DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalInputMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localInputMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = activationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(monitor) }
        DistributedNotificationCenter.default().removeObserver(self)
        recorder?.stop(); recognizer.stop(); timer?.invalidate(); deadline?.cancel(); startupDeadline?.cancel()
        pasteRestore?()
        if let key = hotKey { UnregisterEventHotKey(key) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
        if let dir = audioDir { try? FileManager.default.removeItem(at: dir) }
    }
    func runSelfTest() {
        guard hotKey != nil else { print("SELFTEST FAIL: F18 registration"); exit(1) }
        let board = NSPasteboard(name: .init("GigaFlow.selftest.\(UUID().uuidString)"))
        board.setString("original", forType: .string)
        let snapshot = ClipboardSnapshot.capture(board)!
        board.clearContents(); board.setString("temporary", forType: .string)
        snapshot.restore(board, ifUnchanged: board.changeCount)
        guard board.string(forType: .string) == "original" else { print("SELFTEST FAIL: clipboard restoration"); exit(1) }
        let stale = board.changeCount; board.clearContents(); board.setString("new user copy", forType: .string)
        snapshot.restore(board, ifUnchanged: stale)
        guard board.string(forType: .string) == "new user copy" else { print("SELFTEST FAIL: clipboard race"); exit(1) }
        board.releaseGlobally()
        print("SELFTEST PASS: hotkey registration and clipboard preservation")
        recognizer.start(audioDir: runtime.appendingPathComponent("samples"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("SELFTEST FAIL: worker timeout"); exit(1) }
    }
}

@main
enum GigaFlowMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
