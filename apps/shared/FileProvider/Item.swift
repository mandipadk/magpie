import FileProvider
import Mobile
import UniformTypeIdentifiers

/// One file or folder as Finder and Files see it.
final class Item: NSObject, NSFileProviderItem {
    let entry: Entry
    let kept: Bool

    init(_ entry: Entry, kept: Bool = false) {
        self.entry = entry
        self.kept = kept
    }

    /// The top folder, "Magpie".
    static func root() -> Item {
        Item(Entry(Path: "", Dir: true, Size: 0, Modified: Date(), Version: "root", OnHub: true, ModifiedBy: ""))
    }

    var itemIdentifier: NSFileProviderItemIdentifier { identifier(for: entry.Path) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { entry.Path.isEmpty ? .rootContainer : identifier(for: entry.parent) }
    var filename: String { entry.Path.isEmpty ? "Magpie" : entry.name }

    var contentType: UTType {
        if entry.Dir { return .folder }
        return UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if entry.Dir {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
    }

    var itemVersion: NSFileProviderItemVersion {
        let v = Data(entry.Version.utf8)
        return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
    }

    var documentSize: NSNumber? { entry.Dir ? nil : NSNumber(value: entry.Size) }
    var contentModificationDate: Date? { entry.Modified }
    var creationDate: Date? { entry.Modified }
    var isUploaded: Bool { entry.OnHub }
    var isUploading: Bool { !entry.OnHub }

    /// Read by the Finder and Files action rules in project.yml.
    var userInfo: [AnyHashable: Any]? { ["kept": kept, "dir": entry.Dir] }

    // Keeping something downloaded is a content policy on the Mac (macOS 15);
    // iOS has no such policy, so there the extension fetches kept items itself.
    var contentPolicy: NSFileProviderContentPolicy {
        #if os(macOS)
        if #available(macOS 15.0, *), kept { return .downloadEagerlyAndKeepDownloaded }
        #endif
        return .inherited
    }
}

extension MobileEngine {
    func item(_ entry: Entry) -> Item { Item(entry, kept: pinned(entry.Path)) }
}
