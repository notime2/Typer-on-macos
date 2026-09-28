// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit

@MainActor
final class ClipboardManager {
    struct PasteboardItemSnapshot: Sendable, Equatable {
        let dataByType: [String: Data]
    }

    struct PasteboardSnapshot: Sendable, Equatable {
        let items: [PasteboardItemSnapshot]
        let wasEmpty: Bool
    }

    private let pasteboard: NSPasteboard
    private var backupSnapshot: PasteboardSnapshot?
    private var backupChangeCount: Int = 0
    private var writeChangeCount: Int = 0

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var currentText: String? {
        pasteboard.string(forType: .string)
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func backup() {
        backupSnapshot = currentSnapshot()
        backupChangeCount = pasteboard.changeCount
        Log.clipboard.debug("Clipboard backed up (changeCount: \(self.backupChangeCount))")
    }

    func restore() {
        guard let backupSnapshot else { return }
        restore(snapshot: backupSnapshot)
        Log.clipboard.debug("Clipboard restored")
        self.backupSnapshot = nil
    }

    func restoreBackupIfUnchanged(expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else {
            Log.clipboard.warning("Clipboard changed externally during restore, skipping restore")
            return
        }
        restore()
    }

    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        writeChangeCount = pasteboard.changeCount
    }

    func hasExternalChange() -> Bool {
        // Check if clipboard was modified by something other than our write
        pasteboard.changeCount != writeChangeCount
    }

    func currentSnapshot() -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems ?? []
        let snapshots = items.compactMap { item -> PasteboardItemSnapshot? in
            let dataByType = item.types.reduce(into: [String: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type.rawValue] = data
                }
            }

            guard !dataByType.isEmpty else { return nil }
            return PasteboardItemSnapshot(dataByType: dataByType)
        }

        return PasteboardSnapshot(items: snapshots, wasEmpty: snapshots.isEmpty)
    }

    private func restore(snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()

        guard !snapshot.wasEmpty else { return }

        let items = snapshot.items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
