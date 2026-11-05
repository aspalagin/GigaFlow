import AppKit

/// A complete snapshot of one pasteboard generation. Lazy providers may run
/// arbitrary code while their data is read, so never accept a mixed snapshot.
struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int

    static func capture(_ board: NSPasteboard) -> ClipboardSnapshot? {
        let generation = board.changeCount
        let sourceItems = board.pasteboardItems ?? []
        if sourceItems.isEmpty && !(board.types ?? []).isEmpty { return nil }
        var result = [[NSPasteboard.PasteboardType: Data]]()
        var byteCount = 0
        let limit = 16 * 1024 * 1024
        for item in sourceItems {
            let types = item.types
            guard !types.isEmpty else { return nil }
            var values = [NSPasteboard.PasteboardType: Data]()
            for type in types {
                guard let data = item.data(forType: type), board.changeCount == generation,
                      data.count <= limit - byteCount else { return nil }
                byteCount += data.count
                values[type] = data
            }
            result.append(values)
        }
        guard board.changeCount == generation else { return nil }
        return ClipboardSnapshot(items: result, changeCount: generation)
    }

    /// Returns the generation owned by the temporary text, or nil without
    /// replacing a newer copy. The writer is injectable for service-failure tests.
    func writeTemporaryText(_ text: String, to board: NSPasteboard,
        writer: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) }) -> Int? {
        guard board.changeCount == changeCount else { return nil }
        let temporaryGeneration = board.clearContents()
        guard board.changeCount == temporaryGeneration,
              writer(board, text), board.changeCount == temporaryGeneration else {
            restore(board, ifUnchanged: temporaryGeneration)
            return nil
        }
        return temporaryGeneration
    }

    func restore(_ board: NSPasteboard, ifUnchanged generation: Int) {
        guard board.changeCount == generation else { return }
        var objects = [NSPasteboardItem]()
        for values in items {
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else { return }
            }
            objects.append(item)
        }
        // Building large items can take time too. Preserve a copy made meanwhile.
        guard board.changeCount == generation else { return }
        let restoredGeneration = board.clearContents()
        if !objects.isEmpty && board.changeCount == restoredGeneration {
            board.writeObjects(objects)
        }
    }
}
