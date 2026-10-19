import FileProvider
import Mobile

/// Lists a folder, or (for the working set) everything, and reports what
/// changed since an anchor from the engine's change log.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain

    init(container: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) {
        self.container = container
        self.domain = domain
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let e = try EngineHost.shared.ready(domain: domain)
            var items: [Item] = []
            if container == .workingSet {
                walk(e, "", into: &items)
            } else if let dir = path(for: container) {
                items = e.entries(dir).map { e.item($0) }
            }
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(fileProviderError(error))
        }
    }

    private func walk(_ e: MobileEngine, _ dir: String, into items: inout [Item]) {
        for en in e.entries(dir) {
            items.append(e.item(en))
            if en.Dir { walk(e, en.Path, into: &items) }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        do {
            let e = try EngineHost.shared.get(domain: domain)
            let since = String(data: anchor.rawValue, encoding: .utf8) ?? ""
            struct Changes: Decodable { var paths: [String]; var next: String; var ok: Bool }
            let c = try JSONDecoder().decode(Changes.self, from: Data(e.changesSince(since).utf8))
            guard c.ok else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            let mine = path(for: container)
            var updated: [Item] = []
            var deleted: [NSFileProviderItemIdentifier] = []
            for p in c.paths {
                // a folder's enumerator reports only its own children
                if container != .workingSet, let dir = mine, (p as NSString).deletingLastPathComponent != dir {
                    continue
                }
                if let en = try? e.entry(p) {
                    updated.append(e.item(en))
                } else {
                    deleted.append(identifier(for: p))
                }
            }
            if !updated.isEmpty { observer.didUpdate(updated) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(c.next.utf8)), moreComing: false)
        } catch {
            observer.finishEnumeratingWithError(fileProviderError(error))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let e = try? EngineHost.shared.get(domain: domain) else {
            completionHandler(nil)
            return
        }
        completionHandler(NSFileProviderSyncAnchor(Data(e.anchor().utf8)))
    }
}
