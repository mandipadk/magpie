// The one engine in the extension's process, shared by every extension
// instance, the enumerators and the service the app talks to.
import FileProvider
import Foundation
import Mobile
import os

let log = Logger(subsystem: "dev.mandip.magpie", category: "files")

final class EngineHost: NSObject, MobileListenerProtocol {
    static let shared = EngineHost()

    private let lock = NSLock()
    private var engine: MobileEngine?
    private var domain: NSFileProviderDomain?

    /// The engine, opened and started on first use. Throws when this device
    /// hasn't joined a Magpie yet.
    func get(domain: NSFileProviderDomain? = nil) throws -> MobileEngine {
        lock.lock()
        defer { lock.unlock() }
        if let domain { self.domain = domain }
        if let engine { return engine }
        guard let config = ConfigStore.load() else {
            throw NSFileProviderError(.notAuthenticated)
        }
        try FileManager.default.createDirectory(at: Magpie.engineDir, withIntermediateDirectories: true)
        var err: NSError?
        guard let e = MobileOpen(config, Magpie.engineDir.path, &err) else {
            throw err ?? NSFileProviderError(.serverUnreachable)
        }
        e.setListener(self)
        e.start()
        engine = e
        log.info("engine started as \(e.deviceID(), privacy: .public)")
        return e
    }

    /// The engine, waiting briefly for the server's list on a cold start so
    /// the first enumeration isn't empty.
    func ready(domain: NSFileProviderDomain? = nil) throws -> MobileEngine {
        let e = try get(domain: domain)
        _ = e.waitReady(8000)
        return e
    }

    func stop() {
        lock.lock()
        let e = engine
        engine = nil
        lock.unlock()
        e?.stop()
    }

    // MARK: MobileListener

    func onChange(_ kind: Int, paths: String?) {
        guard let domain = currentDomain(), let manager = NSFileProviderManager(for: domain) else { return }
        // Finder and Files re-read the working set; changes come from ChangesSince.
        manager.signalEnumerator(for: .workingSet) { _ in }
        if kind == 0, let data = paths?.data(using: .utf8),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            refreshKept(list, manager: manager)
        }
    }

    private func currentDomain() -> NSFileProviderDomain? {
        lock.lock()
        defer { lock.unlock() }
        return domain
    }

    /// Kept-downloaded files that changed on another device come down again.
    private func refreshKept(_ paths: [String], manager: NSFileProviderManager) {
        guard let e = try? get() else { return }
        for p in paths where e.pinned(p) {
            guard let json = try? e.stat(p), let en = try? engineDecoder.decode(Entry.self, from: Data(json.utf8)), !en.Dir else { continue }
            requestDownload(manager, path: p)
        }
    }
}

func requestDownload(_ manager: NSFileProviderManager, path: String) {
    if #available(macOS 13.0, iOS 16.0, *) {
        manager.requestDownloadForItem(withIdentifier: identifier(for: path)) { err in
            if let err { log.error("download \(path, privacy: .private): \(err.localizedDescription, privacy: .public)") }
        }
    }
}

func identifier(for path: String) -> NSFileProviderItemIdentifier {
    path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(rawValue: path)
}

func path(for identifier: NSFileProviderItemIdentifier) -> String? {
    switch identifier {
    case .rootContainer: return ""
    case .trashContainer, .workingSet: return nil
    default: return identifier.rawValue
    }
}

/// Maps the engine's errors (prefixed codes, see lib/magpie/mobile) to the
/// ones Finder and Files understand.
func fileProviderError(_ error: Error) -> Error {
    let msg = (error as NSError).localizedDescription
    if msg.hasPrefix("notfound:") { return NSFileProviderError(.noSuchItem) }
    if msg.hasPrefix("offline:") || msg.hasPrefix("paused:") { return NSFileProviderError(.serverUnreachable) }
    if msg.hasPrefix("changed:") { return NSFileProviderError(.cannotSynchronize) }
    if let e = error as? NSFileProviderError { return e }
    return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: msg])
}

extension MobileEngine {
    func entry(_ path: String) throws -> Entry {
        let json = try stat(path)
        return try engineDecoder.decode(Entry.self, from: Data(json.utf8))
    }

    func entries(_ dir: String) -> [Entry] {
        (try? engineDecoder.decode([Entry].self, from: Data(list(dir).utf8))) ?? []
    }
}
