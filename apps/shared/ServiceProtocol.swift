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

    // Version history (lib/magpie/history.go)
    /// [Entry] in a folder, as JSON.
    func list(dir: String, reply: @escaping (Data) -> Void)
    /// [OldVersion] of a file, newest first, as JSON; or an error message.
    func versions(path: String, reply: @escaping (Data?, String?) -> Void)
    /// [OldVersion] of deleted files the server still keeps; or an error message.
    func deleted(reply: @escaping (Data?, String?) -> Void)
    /// Writes a version into the shared container for previewing and returns
    /// its path; or an error message.
    func preview(id: String, reply: @escaping (String?, String?) -> Void)
    /// Puts a version back in place, or beside the file as a copy.
    func restore(id: String, asCopy: Bool, reply: @escaping (String?) -> Void)
}

func makeServiceInterface() -> NSXPCInterface {
    NSXPCInterface(with: MagpieService.self)
}
