import AppKit
import MemopilaCore
import MemopilaServices
import UniformTypeIdentifiers

/// Dragging a card into another app, as in Pasta. Data is loaded from the store only when the drop
/// target asks for a type; file cards drag as their file.
enum DragSupport {
    /// Stack drag-out: current dealt while armed (clipboard), else first UI member. Card face stays first.
    /// Empty stacks still register plain text (title) so in-app pinboard reorder can start a drag session.
    static func provider(for stack: StackCard, store: ClipboardStore, armedMemberID: UUID?) -> NSItemProvider {
        let memberID = (armedMemberID.flatMap { id in stack.memberIDs.contains(id) ? id : nil })
            ?? stack.previewRecordID
            ?? stack.memberIDs.first
        let provider = NSItemProvider()
        let title = stack.title.isEmpty ? "Stack" : stack.title
        if let memberID {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                let reply = Transfer(value: completion)
                Task {
                    do {
                        let payload = try await store.payload(for: memberID)
                        reply.value(payload.text.map { Data($0.utf8) }, nil)
                    } catch {
                        reply.value(Data(title.utf8), nil)
                    }
                }
                return nil
            }
        } else {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                completion(Data(title.utf8), nil)
                return nil
            }
        }
        return provider
    }

    static func provider(for card: HistoryCard, store: ClipboardStore) -> NSItemProvider {
        if card.displayType == .file, let path = card.filePaths.first {
            let url = URL(fileURLWithPath: path)
            // A network file drags as its address: reading it could block the drag (review finding).
            guard FileVolumes.isLocal(path) else { return NSItemProvider(object: url as NSURL) }
            if let provider = NSItemProvider(contentsOf: url) { return provider }
        }
        let provider = NSItemProvider()
        let id = card.id
        var types = card.storedTypes.filter { type in
            let pasteboardType = PasteboardType(type)
            return !pasteboardType.isFileReference && !pasteboardType.isMetadataOnly
                && !type.contains(" ") && UTType(type) != nil
        }
        let plainText = UTType.utf8PlainText.identifier
        if card.hasText, !types.contains(plainText) { types.append(plainText) }
        for type in types {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                let reply = Transfer(value: completion)
                Task {
                    do {
                        let payload = try await store.payload(for: id)
                        reply.value(data(of: type, in: payload), nil)
                    } catch {
                        reply.value(nil, error)
                    }
                }
                return nil
            }
        }
        return provider
    }

    private static func data(of type: String, in payload: RestorePayload) -> Data? {
        if let bytes = payload.items.lazy.flatMap(\.representations).first(where: { $0.type.rawValue == type })?.bytes {
            return bytes
        }
        return type == UTType.utf8PlainText.identifier ? payload.text.map { Data($0.utf8) } : nil
    }
}
