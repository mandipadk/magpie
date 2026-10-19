// What the apps ask the File Provider extension, where the engine runs.
// The app connects through FileManager's File Provider services, which also
// keeps the extension (and so the connection to the server) alive while the
// app is open.
import Foundation

@objc protocol MagpieService {
    /// EngineStatus as JSON.
    func status(reply: @escaping (Data) -> Void)
    /// [Conflict] as JSON.
    func conflicts(reply: @escaping (Data) -> Void)
    /// [DeviceInfo] as JSON.
    func devices(reply: @escaping (Data) -> Void)
    func resolve(copyPath: String, keep: Int, reply: @escaping (String?) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping () -> Void)
    /// A single-use join link for a new device, or an error message.
    func invite(reply: @escaping (String?, String?) -> Void)
    /// Keep a path downloaded (or not).
    func setKeepDownloaded(path: String, on: Bool, reply: @escaping (String?) -> Void)
    /// Paths kept downloaded, as a JSON array.
    func keptDownloaded(reply: @escaping (Data) -> Void)
}

func makeServiceInterface() -> NSXPCInterface {
    NSXPCInterface(with: MagpieService.self)
}
