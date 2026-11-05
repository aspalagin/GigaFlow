import AppKit
import ApplicationServices

/// Pure decision layer, independently testable without Accessibility permission.
struct FocusPolicyFacts {
    var fallback = false
    var sameInteraction = true
    var authorized = true
    var sameApp = true
    var captureUsable = true
    var captureReason = "focused_element_read_failed"
    var secureField = false
    var originalHasWindow = true
    var currentHasWindow = true
    var sameWindow = true
    var originalHasElement = true
    var currentHasElement = true
    var sameElement = true
    var permitsAbsentElement = false
}

enum FocusPolicy {
    static func rejection(_ facts: FocusPolicyFacts) -> String? {
        if facts.fallback && !facts.sameInteraction { return "user_navigation_since_capture" }
        guard facts.authorized else { return "accessibility_not_authorized" }
        guard facts.sameApp else { return "foreground_application_changed" }
        guard facts.captureUsable else { return facts.captureReason }
        guard !facts.secureField else { return "secure_field" }
        if facts.originalHasWindow {
            guard facts.currentHasWindow else { return "focused_window_unavailable" }
            guard facts.sameWindow else { return "focused_window_changed" }
        }
        if !facts.fallback {
            guard facts.originalHasElement && facts.currentHasElement else { return "focused_element_unavailable" }
            return facts.sameElement ? nil : "focused_element_changed"
        }
        guard !facts.currentHasElement else { return "focused_element_became_available" }
        guard facts.permitsAbsentElement else { return "focused_element_read_failed" }
        guard facts.originalHasWindow else { return "original_window_unavailable" }
        return nil
    }
}

/// The normal path requires the original AX field. Codex sometimes exposes no
/// field for its composer; that narrow fallback additionally requires no user
/// navigation since capture and the identical AX window. It cannot prove absence
/// of a programmatic, same-window focus change while the AX field is unavailable.
struct InputTarget {
    private enum Strategy: String { case element, codexWindowWithoutElement }
    private let pid: pid_t
    private let bundleID: String
    let element: AXUIElement?
    private let window: AXUIElement?
    private let strategy: Strategy
    private let initialInteractionSerial: UInt64
    private let initialMetadata: [String: Any]

    static func capture(interactionSerial: UInt64) -> InputTarget? {
        let snapshot = FocusSnapshot.current()
        guard snapshot.canUse, let pid = snapshot.pid else { return nil }
        if let element = snapshot.element {
            guard !snapshot.secure else { return nil }
            return InputTarget(pid: pid, bundleID: snapshot.bundleID, element: element,
                window: snapshot.window, strategy: .element,
                initialInteractionSerial: interactionSerial, initialMetadata: snapshot.metadata)
        }
        guard snapshot.bundleID == "com.openai.codex", snapshot.window != nil,
              snapshot.permitsAbsentElementFallback else { return nil }
        return InputTarget(pid: pid, bundleID: snapshot.bundleID, element: nil,
            window: snapshot.window, strategy: .codexWindowWithoutElement,
            initialInteractionSerial: interactionSerial, initialMetadata: snapshot.metadata)
    }

    /// nil means the original destination is still acceptable. A reason token
    /// intentionally contains no UI contents and is safe for the focus audit.
    func checkCurrent(interactionSerial: UInt64) -> String? {
        if strategy == .codexWindowWithoutElement && interactionSerial != initialInteractionSerial {
            return "user_navigation_since_capture"
        }
        let current = FocusSnapshot.current()
        var facts = FocusPolicyFacts()
        facts.fallback = strategy == .codexWindowWithoutElement
        facts.sameInteraction = interactionSerial == initialInteractionSerial
        facts.authorized = current.trusted
        facts.sameApp = current.pid == pid && current.bundleID == bundleID
        facts.captureUsable = current.canUse
        facts.captureReason = current.captureReason
        facts.secureField = current.secure
        facts.originalHasWindow = window != nil
        facts.currentHasWindow = current.window != nil
        if let before = window, let after = current.window { facts.sameWindow = CFEqual(before, after) }
        facts.originalHasElement = element != nil
        facts.currentHasElement = current.element != nil
        if let before = element, let after = current.element { facts.sameElement = CFEqual(before, after) }
        facts.permitsAbsentElement = current.permitsAbsentElementFallback
        return FocusPolicy.rejection(facts)
    }

    static func diagnoseCurrent() -> [String: Any] { FocusSnapshot.current().metadata }

    func metadata() -> [String: Any] {
        var result = initialMetadata
        result["strategy"] = strategy.rawValue
        result["initialInteractionSerial"] = initialInteractionSerial
        return result
    }
}

private struct FocusSnapshot {
    var trusted = false
    var pid: pid_t?
    var bundleID = ""
    var element: AXUIElement?
    var window: AXUIElement?
    var elementError = AXError.noValue
    var windowError = AXError.noValue
    var elementTypeValid = true
    var role = ""
    var subrole = ""
    var captureReason = "foreground_application_unavailable"
    var canUse = false

    var secure: Bool { subrole == "AXSecureTextField" }
    var permitsAbsentElementFallback: Bool {
        guard element == nil, elementTypeValid else { return false }
        return elementError == .success || elementError == .noValue ||
            elementError == .attributeUnsupported || elementError == .notImplemented
    }

    var metadata: [String: Any] {
        var result: [String: Any] = [
            "axTrusted": trusted, "bundleID": bundleID,
            "focusedElementStatus": elementError.rawValue,
            "focusedWindowStatus": windowError.rawValue,
            "elementExists": element != nil, "windowExists": window != nil,
            "elementTypeValid": elementTypeValid, "role": role, "subrole": subrole,
            "secure": secure, "captureReason": captureReason
        ]
        if let pid = pid { result["pid"] = pid }
        return result
    }

    private static func elementAttribute(_ source: AXUIElement, _ attribute: CFString)
        -> (AXUIElement?, AXError, Bool) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(source, attribute, &value)
        guard error == .success, let value = value else { return (nil, error, true) }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error, false) }
        return ((value as! AXUIElement), error, true)
    }

    private static func stringAttribute(_ source: AXUIElement, _ attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    static func current() -> FocusSnapshot {
        var result = FocusSnapshot()
        result.trusted = AXIsProcessTrusted()
        guard result.trusted else { result.captureReason = "accessibility_not_authorized"; return result }
        guard let app = NSWorkspace.shared.frontmostApplication else { return result }
        result.pid = app.processIdentifier
        result.bundleID = app.bundleIdentifier ?? ""
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            result.captureReason = "gigaflow_is_foreground"; return result
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let focus = elementAttribute(application, kAXFocusedUIElementAttribute as CFString)
        result.element = focus.0; result.elementError = focus.1; result.elementTypeValid = focus.2
        let window = elementAttribute(application, kAXFocusedWindowAttribute as CFString)
        result.window = window.0; result.windowError = window.1
        if let element = result.element {
            result.role = stringAttribute(element, kAXRoleAttribute as CFString)
            result.subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            result.captureReason = "foreground_changed_during_capture"; return result
        }
        result.canUse = true
        if result.secure { result.captureReason = "secure_field" }
        else if result.element != nil { result.captureReason = "element_available" }
        else if result.permitsAbsentElementFallback { result.captureReason = "element_absent" }
        else { result.captureReason = "focused_element_read_failed" }
        return result
    }
}

/// Bounded, metadata-only diagnostics. Unknown fields are discarded so callers
/// cannot accidentally persist a transcript, field value, window title or URL.
enum FocusAudit {
    private static let lock = NSLock()
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GigaFlow", isDirectory: true)
    private static let file = directory.appendingPathComponent("focus-events.json")
    private static let allowedKeys: Set<String> = [
        "reason", "requestID", "attempt", "interactionSerial", "initialInteractionSerial",
        "currentInteractionSerial", "target", "current", "stage", "pid", "bundleID",
        "mode", "focusedElementStatus", "focusedWindowStatus", "elementExists", "windowExists",
        "elementTypeValid", "role", "subrole", "strategy", "windowMatches", "elementMatches",
        "secure", "axTrusted", "captureReason", "targetExists", "sameApp", "sameWindow",
        "durationSeconds", "outcome"
    ]
    private static var entries: [[String: Any]] = {
        guard let data = try? Data(contentsOf: file), data.count <= 512_000,
              let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return Array(records.suffix(49))
    }()

    private static func sanitized(_ details: [String: Any]) -> [String: Any] {
        var result = [String: Any]()
        for (key, value) in details where allowedKeys.contains(key) {
            if let nested = value as? [String: Any] { result[key] = sanitized(nested) }
            else if let string = value as? String { result[key] = String(string.prefix(128)) }
            else if let number = value as? NSNumber, number.doubleValue.isFinite { result[key] = number }
        }
        return result
    }

    static func record(event: String, details: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let safeEvent = String(event.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }.prefix(64).map(Character.init))
        entries.append(["timestamp": ISO8601DateFormatter().string(from: Date()),
                        "event": safeEvent, "details": sanitized(details)])
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // A failed diagnostic write must not interrupt dictation.
        }
    }
}
