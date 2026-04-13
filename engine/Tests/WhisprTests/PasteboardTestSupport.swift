#if os(macOS)
import AppKit
import Foundation

enum PasteboardTestSupport {
    private actor Lock {
        private var isHeld = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !isHeld {
                isHeld = true
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            if waiters.isEmpty {
                isHeld = false
                return
            }

            let next = waiters.removeFirst()
            next.resume()
        }
    }

    private static let lock = Lock()

    @MainActor
    static func withPreservedPasteboard(
        _ body: @MainActor (NSPasteboard) async throws -> Void
    ) async rethrows {
        await lock.acquire()

        let pasteboard = NSPasteboard.general
        let preserved = snapshot(pasteboard)
        do {
            try await body(pasteboard)
            restore(preserved, to: pasteboard)
            await lock.release()
        } catch {
            restore(preserved, to: pasteboard)
            await lock.release()
            throw error
        }
    }

    @MainActor
    static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            return entry
        }
    }

    @MainActor
    static func restore(_ snapshot: [[String: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let items = snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    @MainActor
    static func makePasteboardItem(_ values: [String: Data]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in values {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        return item
    }
}
#endif
