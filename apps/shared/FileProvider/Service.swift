// The XPC service the Magpie app connects to: status, conflicts, devices,
// pause, invites and keep-downloaded, answered by the engine here.
import FileProvider
import Foundation
import Mobile

final class ServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, MagpieService {
    let serviceName = Magpie.serviceName
    private weak var ext: FileProviderExtension?
    private let listener = NSXPCListener.anonymous()

    init(ext: FileProviderExtension) {
        self.ext = ext
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { listener.endpoint }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        #if os(macOS)
        // Any process that can see a Magpie item could otherwise ask for an
        // invite; messages from anything but the Magpie app are refused.
        c.setCodeSigningRequirement(Magpie.appRequirement)
        #endif
        c.exportedInterface = makeServiceInterface()
        c.exportedObject = self
        c.resume()
        return true
    }

    private var engine: MobileEngine? { try? EngineHost.shared.get(domain: ext?.domain) }

    func status(reply: @escaping (Data) -> Void) {
        reply(Data((engine?.status() ?? "{}").utf8))
    }

    func conflicts(reply: @escaping (Data) -> Void) {
        reply(Data((engine?.conflicts() ?? "[]").utf8))
    }

    func devices(reply: @escaping (Data) -> Void) {
        reply(Data((engine?.devices() ?? "[]").utf8))
    }

    func resolve(copyPath: String, keep: Int, reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.engine?.resolve(copyPath, keep: keep)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func setPaused(_ paused: Bool, reply: @escaping () -> Void) {
        if paused { engine?.pause() } else { engine?.resume() }
        reply()
    }

    func invite(reply: @escaping (String?, String?) -> Void) {
        do {
            guard let e = engine else { return reply(nil, "Magpie isn't set up on this device.") }
            reply(try goCall { e.invite($0) }, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func setKeepDownloaded(path: String, on: Bool, reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let e = self.engine, let ext = self.ext else { return reply("Magpie isn't running.") }
                try ext.setKept(e, path: path, on: on)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func keptDownloaded(reply: @escaping (Data) -> Void) {
        reply(Data((engine?.pinnedPaths() ?? "[]").utf8))
    }

    // MARK: Version history

    func list(dir: String, reply: @escaping (Data) -> Void) {
        reply(Data((engine?.list(dir) ?? "[]").utf8))
    }

    func versions(path: String, reply: @escaping (Data?, String?) -> Void) {
        background(reply) { e in Data(try goCall { e.versions(path, error: $0) }.utf8) }
    }

    func deleted(reply: @escaping (Data?, String?) -> Void) {
        background(reply) { e in Data(try goCall { e.deleted($0) }.utf8) }
    }

    func preview(id: String, reply: @escaping (String?, String?) -> Void) {
        background(reply) { e in
            let dir = Magpie.containerURL.appendingPathComponent("previews", isDirectory: true)
            try? FileManager.default.removeItem(at: dir) // one preview at a time
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(UUID().uuidString)
            let json = try goCall { e.fetchVersion(id, dst: tmp.path, error: $0) }
            let v = try engineDecoder.decode(OldVersion.self, from: Data(json.utf8))
            // Under the file's own name, so Quick Look knows what it is.
            let named = dir.appendingPathComponent(v.name)
            try FileManager.default.moveItem(at: tmp, to: named)
            return named.path
        }
    }

    func restore(id: String, asCopy: Bool, reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let e = self.engine else { return reply("Magpie isn't running.") }
                if asCopy {
                    _ = try goCall { e.restoreCopy(id, error: $0) }
                } else {
                    _ = try goCall { e.restore(id, error: $0) }
                }
                reply(nil)
            } catch {
                reply(friendlyError(error))
            }
        }
    }

    private func background<T>(_ reply: @escaping (T?, String?) -> Void, _ work: @escaping (MobileEngine) throws -> T) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let e = self.engine else { return reply(nil, "Magpie isn't running.") }
                reply(try work(e), nil)
            } catch {
                reply(nil, friendlyError(error))
            }
        }
    }
}
