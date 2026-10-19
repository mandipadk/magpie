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
}
