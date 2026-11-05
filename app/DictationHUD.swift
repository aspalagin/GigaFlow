import AppKit

/// A nonactivating panel's content view. Feed microphone level (0...1) at ~30 Hz.
/// The waveform expresses measured amplitude; its decorative shape is not a spectrum.
final class DictationHUDView: NSView {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    // A preference lets later size changes avoid rebuilding the signed app.
    private let displayScale: CGFloat = {
        let configured = UserDefaults.standard.object(forKey: "HUDScale") as? Double ?? (1.0 / 3.0)
        return CGFloat(configured.isFinite ? min(1, max(0.15, configured)) : (1.0 / 3.0))
    }()

    private var state = "info"
    private var message = "GigaFlow"
    private var elapsed: Double = 0
    private var amplitude: Double = 0
    private var phase: Double = 0
    private var lastUpdate = ProcessInfo.processInfo.systemUptime
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let captionLabel = NSTextField(labelWithString: "ЗАПИСЬ")
    private let messageLabel = NSTextField(wrappingLabelWithString: "GigaFlow")
    private let stopButton = HUDIconButton(kind: .stop)
    private let cancelButton = HUDIconButton(kind: .cancel)

    var preferredSize: NSSize {
        let size = designSize
        return NSSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    private var designSize: NSSize {
        if state == "recording" || state == "processing" { return NSSize(width: 360, height: 72) }
        if state == "success" && displayMessage.count < 42 { return NSSize(width: 360, height: 64) }
        let width: CGFloat = 420
        let rect = (displayMessage as NSString).boundingRect(
            with: NSSize(width: width - 102, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        return NSSize(width: width, height: max(72, min(144, ceil(rect.height) + 36)))
    }

    override var intrinsicContentSize: NSSize { preferredSize }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Scale the view's coordinate system, including subviews and hit testing.
        super.setBoundsSize(NSSize(width: newSize.width / displayScale, height: newSize.height / displayScale))
        needsLayout = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.setBoundsSize(NSSize(width: frameRect.width / displayScale, height: frameRect.height / displayScale))
        wantsLayer = true
        layer?.masksToBounds = false
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timerLabel.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        timerLabel.setAccessibilityLabel("Длительность записи")
        captionLabel.font = .systemFont(ofSize: 8, weight: .semibold)
        captionLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        captionLabel.setAccessibilityElement(false)
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        messageLabel.maximumNumberOfLines = 6
        messageLabel.lineBreakMode = .byWordWrapping
        for label in [timerLabel, captionLabel, messageLabel] {
            label.isSelectable = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            addSubview(label)
        }
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.toolTip = "Завершить запись и вставить текст"
        stopButton.setAccessibilityLabel("Завершить запись и вставить текст")
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.toolTip = "Отменить диктовку"
        cancelButton.setAccessibilityLabel("Отменить диктовку")
        addSubview(stopButton)
        addSubview(cancelButton)
        update(state: "info", message: "GigaFlow")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func update(state newState: String, level: Double = 0, elapsed: Double = 0, message: String = "") {
        let changed = state != newState || self.message != message
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastUpdate))
        lastUpdate = now
        state = newState
        self.message = message
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let target = level.isFinite ? min(1, max(0, level)) : 0
        let speed = target > amplitude ? 24.0 : 9.0
        amplitude += (target - amplitude) * (1 - exp(-speed * dt))
        if changed { reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        phase = reduceMotion ? 0 : now
        let seconds = Int(self.elapsed)
        timerLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        timerLabel.isHidden = state != "recording"
        captionLabel.isHidden = state != "recording"
        messageLabel.isHidden = state == "recording"
        messageLabel.stringValue = displayMessage
        stopButton.isHidden = state != "recording"
        cancelButton.isHidden = state == "success"
        cancelButton.toolTip = state == "recording" || state == "processing" ? "Отменить диктовку" : "Закрыть"
        cancelButton.setAccessibilityLabel(cancelButton.toolTip)
        if changed { invalidateIntrinsicContentSize(); needsLayout = true }
        needsDisplay = true
    }

    private var displayMessage: String {
        if !message.isEmpty { return message }
        switch state {
        case "processing": return "Распознаю…"
        case "success": return "Текст вставлен"
        case "error": return "Не удалось завершить диктовку"
        case "recording": return "Запись"
        default: return "GigaFlow"
        }
    }

    override func layout() {
        super.layout()
        let center = bounds.midY
        timerLabel.frame = NSRect(x: 35, y: center - 1, width: 58, height: 21)
        captionLabel.frame = NSRect(x: 36, y: center - 15, width: 64, height: 11)
        stopButton.frame = NSRect(x: bounds.width - 108, y: center - 18, width: 36, height: 36)
        cancelButton.frame = NSRect(x: bounds.width - 55, y: center - 16, width: 32, height: 32)
        if state == "processing" {
            messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
            messageLabel.frame = NSRect(x: 104, y: center - 10, width: bounds.width - 170, height: 21)
        } else {
            messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
            let width = bounds.width - (cancelButton.isHidden ? 84 : 108)
            let textHeight = (displayMessage as NSString).boundingRect(
                with: NSSize(width: width, height: 110),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: messageLabel.font!]).height
            let height = min(bounds.height - 28, max(20, ceil(textHeight) + 2))
            messageLabel.frame = NSRect(x: 55, y: center - height / 2, width: width, height: height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 25, yRadius: 25)
        let top = NSColor(calibratedRed: 0.13, green: 0.135, blue: 0.15, alpha: 0.985)
        let bottom = NSColor(calibratedRed: 0.065, green: 0.07, blue: 0.08, alpha: 0.985)
        NSGradient(starting: bottom, ending: top)?.draw(in: capsule, angle: 90)
        NSColor.white.withAlphaComponent(0.15).setStroke()
        capsule.lineWidth = 0.75
        capsule.stroke()
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 24, yRadius: 24)
        NSColor.black.withAlphaComponent(0.22).setStroke()
        inner.lineWidth = 0.5
        inner.stroke()
        switch state {
        case "recording":
            drawRecording()
        case "processing":
            drawProcessing()
        case "success":
            drawStatusSymbol("checkmark", tint: NSColor(calibratedRed: 0.36, green: 0.89, blue: 0.64, alpha: 1))
        case "error":
            drawStatusSymbol("exclamationmark", tint: NSColor(calibratedRed: 1, green: 0.57, blue: 0.42, alpha: 1))
        default:
            drawStatusSymbol("waveform", tint: NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.84, alpha: 1))
        }
    }

    private func drawRecording() {
        let center = bounds.midY
        let pink = NSColor(calibratedRed: 1, green: 0.30, blue: 0.43, alpha: 1)
        let pulse = reduceMotion ? 0.0 : (sin(phase * 3) + 1) / 2
        pink.withAlphaComponent(0.10 + pulse * 0.06).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: center - 8, width: 16, height: 16)).fill()
        pink.setFill()
        NSBezierPath(ovalIn: NSRect(x: 20, y: center - 4, width: 8, height: 8)).fill()
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: NSRect(x: 99, y: center - 14, width: 1, height: 28), xRadius: 0.5, yRadius: 0.5).fill()
        let count = 18
        let barWidth: CGFloat = 3
        let pitch: CGFloat = 6.7
        for index in 0..<count {
            let position = Double(index) / Double(count - 1)
            let envelope = 0.34 + 0.66 * pow(sin(position * .pi), 0.7)
            let oscillation = reduceMotion ? 0.72 : 0.48 + 0.52 * abs(sin(phase * 4.8 + Double(index) * 0.83))
            let height = CGFloat(3 + 30 * pow(amplitude, 0.72) * envelope * oscillation)
            let color = NSColor(calibratedWhite: 0.98, alpha: 0.50 + 0.48 * envelope)
            color.setFill()
            let rect = NSRect(x: 114 + CGFloat(index) * pitch, y: center - height / 2,
                              width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawProcessing() {
        let count = 9
        for index in 0..<count {
            let envelope = sin(Double(index + 1) / Double(count + 1) * .pi)
            let movement = reduceMotion ? 0.5 : (sin(phase * 4 - Double(index) * 0.65) + 1) / 2
            let height = CGFloat(4 + 17 * envelope * (0.3 + movement * 0.7))
            NSColor(calibratedWhite: 0.96, alpha: 0.38 + 0.58 * movement).setFill()
            let rect = NSRect(x: 24 + CGFloat(index) * 6, y: bounds.midY - height / 2, width: 3, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawStatusSymbol(_ symbol: String, tint: NSColor) {
        let rect = NSRect(x: 19, y: bounds.midY - 12, width: 24, height: 24)
        tint.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { destination in
            image.draw(in: destination)
            tint.setFill()
            destination.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14))
    }

    @objc private func stopPressed() { onStop?() }
    @objc private func cancelPressed() { onCancel?() }
}

private final class HUDIconButton: NSButton {
    enum Kind { case stop, cancel }
    private let kind: Kind
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        imagePosition = .imageOnly
    }

    required init?(coder: NSCoder) { fatalError("Use init(kind:)") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        switch kind {
        case .stop:
            NSColor(calibratedWhite: pressed ? 0.72 : (hovering ? 1 : 0.91), alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
            NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10),
                         xRadius: 2.1, yRadius: 2.1).fill()
        case .cancel:
            NSColor.white.withAlphaComponent(pressed ? 0.15 : (hovering ? 0.10 : 0.045)).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            let path = NSBezierPath()
            let inset: CGFloat = 11.5
            path.move(to: NSPoint(x: inset, y: inset))
            path.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
            path.move(to: NSPoint(x: inset, y: bounds.height - inset))
            path.line(to: NSPoint(x: bounds.width - inset, y: inset))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            NSColor.white.withAlphaComponent(hovering ? 0.92 : 0.58).setStroke()
            path.stroke()
        }
    }
}
