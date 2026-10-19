// Magpie in Finder and the Files app. The engine runs here: it lists what
// the server holds, fetches a file when it's opened and sends edits back.
import FileProvider
import Foundation
import Mobile

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing, NSFileProviderCustomAction {
    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        _ = try? EngineHost.shared.get(domain: domain)
    }

    func invalidate() {}

    private var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            if identifier == .rootContainer {
                completionHandler(Item.root(), nil)
            } else if let p = path(for: identifier) {
                let e = try EngineHost.shared.ready(domain: domain)
                completionHandler(e.item(try e.entry(p)), nil)
            } else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
        } catch {
            completionHandler(nil, fileProviderError(error))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        guard let p = path(for: itemIdentifier) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let e = try EngineHost.shared.ready(domain: self.domain)
                let dir = try self.manager?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
                let dst = dir.appendingPathComponent(UUID().uuidString)
                let json = try goCall { e.fetch(p, dst: dst.path, timeoutMs: 0, progress: ProgressBridge(progress), error: $0) }
                let en = try engineDecoder.decode(Entry.self, from: Data(json.utf8))
                completionHandler(dst, e.item(en), nil)
            } catch {
                completionHandler(nil, nil, fileProviderError(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let parent = path(for: itemTemplate.parentItemIdentifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        let target = parent.isEmpty ? itemTemplate.filename : parent + "/" + itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let e = try EngineHost.shared.ready(domain: self.domain)
                let json: String
                if isFolder {
                    json = try goCall { e.mkdir(target, error: $0) }
                } else if let url {
                    json = try goCall { e.put(target, src: url.path, base: "", error: $0) }
                } else {
                    // a symlink or alias: Magpie keeps files and folders only
                    completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
                    return
                }
                let en = try engineDecoder.decode(Entry.self, from: Data(json.utf8))
                progress.completedUnitCount = 1
                completionHandler(e.item(en), [], false, nil)
            } catch {
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard var p = path(for: item.itemIdentifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        let base = String(data: version.contentVersion, encoding: .utf8) ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let e = try EngineHost.shared.ready(domain: self.domain)
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    guard let parent = path(for: item.parentItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                    let to = parent.isEmpty ? item.filename : parent + "/" + item.filename
                    if to != p {
                        _ = try goCall { e.rename(p, newPath: to, base: base, error: $0) }
                        p = to
                    }
                }
                var refetch = false
                if changedFields.contains(.contents), let newContents {
                    let current = try e.entry(p).Version
                    let json = try goCall { e.put(p, src: newContents.path, base: changedFields.contains(.filename) ? current : base, error: $0) }
                    let saved = try engineDecoder.decode(Entry.self, from: Data(json.utf8))
                    // Edited elsewhere meanwhile: the edit became a conflict copy, and
                    // this item takes the other device's version.
                    refetch = saved.Path != p
                }
                progress.completedUnitCount = 1
                completionHandler(e.item(try e.entry(p)), [], refetch, nil)
            } catch {
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let p = path(for: identifier), !p.isEmpty else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }
        let base = String(data: version.contentVersion, encoding: .utf8) ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let e = try EngineHost.shared.ready(domain: self.domain)
                try e.delete(p, base: options.contains(.recursive) ? "" : base)
                completionHandler(nil)
            } catch {
                completionHandler(fileProviderError(error))
            }
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier != .trashContainer else { throw NSFileProviderError(.noSuchItem) }
        return Enumerator(container: containerItemIdentifier, domain: domain)
    }

    // MARK: Keep Downloaded / Remove Download

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        #if os(macOS)
        if actionIdentifier.rawValue == Magpie.historyRequest {
            // The window is the app's: hand it the file and let it open.
            if let first = itemIdentifiers.first, let p = path(for: first) {
                UserDefaults(suiteName: Magpie.appGroup)?.set(p, forKey: Magpie.historyRequest)
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                     CFNotificationName(Magpie.historyRequest as CFString), nil, nil, true)
            }
            completionHandler(nil)
            return Progress()
        }
        #endif
        let keep = actionIdentifier.rawValue == "dev.mandip.magpie.keep"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let e = try EngineHost.shared.ready(domain: self.domain)
                for id in itemIdentifiers {
                    guard let p = path(for: id) else { continue }
                    try self.setKept(e, path: p, on: keep)
                }
                self.manager?.signalEnumerator(for: .workingSet) { _ in }
                completionHandler(nil)
            } catch {
                completionHandler(fileProviderError(error))
            }
        }
        return Progress()
    }

    func setKept(_ e: MobileEngine, path p: String, on: Bool) throws {
        e.pin(p, on: on)
        guard let manager else { return }
        var files: [String] = []
        func collect(_ path: String) {
            if let en = try? e.entry(path), !en.Dir { files.append(path); return }
            for child in e.entries(path) {
                if child.Dir { collect(child.Path) } else { files.append(child.Path) }
            }
        }
        collect(p)
        for f in files {
            if on {
                requestDownload(manager, path: f)
            } else {
                manager.evictItem(identifier: identifier(for: f)) { _ in }
            }
        }
    }

    // MARK: The app's service

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler([ServiceSource(ext: self)], nil)
        return Progress()
    }
}

/// Reports fetch progress to the system.
final class ProgressBridge: NSObject, MobileProgressProtocol {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
    func onProgress(_ done: Int64, total: Int64) {
        guard total > 0 else { return }
        progress.completedUnitCount = Int64(Double(done) / Double(total) * 100)
    }
}
