import AppKit

private final class DeferredData: NSObject, NSPasteboardItemDataProvider {
    var calls = 0
    let provide: (NSPasteboard?, NSPasteboardItem, NSPasteboard.PasteboardType) -> Void

    init(_ provide: @escaping (NSPasteboard?, NSPasteboardItem, NSPasteboard.PasteboardType) -> Void) {
        self.provide = provide
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        calls += 1
        provide(pasteboard, item, type)
    }
}

@main
enum ClipboardChecks {
    static func main() {
        // These checks must never read or write the user's general pasteboard.
        let board = NSPasteboard(name: .init("GigaFlow.clipboard-checks.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let binary = NSPasteboard.PasteboardType("local.gigaflow.tests.binary")
        var checked = 0
        var failures = [String]()
        func expect(_ condition: Bool, _ description: String) {
            checked += 1
            if !condition { failures.append(description) }
        }
        func copy(_ text: String) {
            board.clearContents()
            precondition(board.setString(text, forType: .string))
        }

        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setData(Data([0, 1, 255]), forType: binary)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        board.clearContents()
        precondition(board.writeObjects([first, second]))
        let multiple = ClipboardSnapshot.capture(board)!
        let temporary = multiple.writeTemporaryText("dictation", to: board)!
        expect(board.string(forType: .string) == "dictation", "temporary text is written")
        multiple.restore(board, ifUnchanged: temporary)
        let restored = board.pasteboardItems ?? []
        expect(restored.count == 2, "all clipboard items are restored")
        expect(restored.first?.string(forType: .string) == "first" &&
            restored.last?.string(forType: .string) == "second", "clipboard item order is preserved")
        expect(restored.first?.data(forType: binary) == Data([0, 1, 255]),
            "secondary binary representation is preserved")

        copy("original")
        let stale = ClipboardSnapshot.capture(board)!
        copy("new copy before write")
        expect(stale.writeTemporaryText("dictation", to: board) == nil,
            "write rejects a snapshot from a stale generation")
        expect(board.string(forType: .string) == "new copy before write",
            "new copy before write remains intact")

        let current = ClipboardSnapshot.capture(board)!
        let owned = current.writeTemporaryText("dictation", to: board)!
        copy("new copy before restore")
        current.restore(board, ifUnchanged: owned)
        expect(board.string(forType: .string) == "new copy before restore",
            "delayed restoration preserves a newer copy")

        let changingProvider = DeferredData { _, item, type in
            copy("new copy during lazy read")
            item.setString("stale promised text", forType: type)
        }
        let changingItem = NSPasteboardItem()
        changingItem.setDataProvider(changingProvider, forTypes: [.string])
        board.clearContents()
        precondition(board.writeObjects([changingItem]))
        withExtendedLifetime(changingProvider) {
            expect(ClipboardSnapshot.capture(board) == nil, "mixed-generation lazy snapshot is rejected")
            expect(changingProvider.calls > 0, "lazy provider actually ran during capture")
        }
        expect(board.string(forType: .string) == "new copy during lazy read",
            "lazy snapshot read preserves the newer copy")

        let missingProvider = DeferredData { _, _, _ in }
        let missingItem = NSPasteboardItem()
        missingItem.setString("readable text", forType: .string)
        missingItem.setDataProvider(missingProvider, forTypes: [binary])
        board.clearContents()
        precondition(board.writeObjects([missingItem]))
        withExtendedLifetime(missingProvider) {
            expect(ClipboardSnapshot.capture(board) == nil,
                "an unavailable representation rejects the entire snapshot")
            expect(missingProvider.calls > 0, "unavailable representation was requested")
        }
        expect(board.string(forType: .string) == "readable text",
            "failed capture does not clear readable clipboard data")

        board.clearContents()
        precondition(board.setData(Data(repeating: 7, count: 16 * 1024 * 1024 + 1), forType: binary))
        expect(ClipboardSnapshot.capture(board) == nil, "oversized snapshot is rejected")

        board.clearContents()
        let empty = ClipboardSnapshot.capture(board)!
        let emptyOwned = empty.writeTemporaryText("dictation", to: board)!
        empty.restore(board, ifUnchanged: emptyOwned)
        expect((board.pasteboardItems ?? []).isEmpty && (board.types ?? []).isEmpty,
            "restoration preserves an originally empty clipboard")

        copy("original before failed write")
        let beforeFailure = ClipboardSnapshot.capture(board)!
        expect(beforeFailure.writeTemporaryText("dictation", to: board, writer: { _, _ in false }) == nil,
            "pasteboard write failure is returned to the caller")
        expect(board.string(forType: .string) == "original before failed write",
            "write failure restores the original clipboard")

        let beforeConcurrentFailure = ClipboardSnapshot.capture(board)!
        let failedResult = beforeConcurrentFailure.writeTemporaryText("dictation", to: board) { _, _ in
            copy("new copy during failed write")
            return false
        }
        expect(failedResult == nil, "failed concurrent write is rejected")
        expect(board.string(forType: .string) == "new copy during failed write",
            "write failure preserves a concurrent copy")

        let beforeConcurrentSuccess = ClipboardSnapshot.capture(board)!
        let replacedResult = beforeConcurrentSuccess.writeTemporaryText("dictation", to: board) { _, _ in
            copy("new copy during successful write")
            return true
        }
        expect(replacedResult == nil, "generation change rejects apparent write success")
        expect(board.string(forType: .string) == "new copy during successful write",
            "concurrent copy is preserved after apparent write success")

        for failure in failures { print("FAIL: \(failure)") }
        precondition(failures.isEmpty, "\(failures.count) clipboard checks failed")
        print("Clipboard: \(checked) checks passed (private pasteboard only)")
    }
}
