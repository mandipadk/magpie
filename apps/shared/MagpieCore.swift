// The engine's types as the apps see them, and where the apps keep the
// device's Magpie config (the keychain, shared by the app and its File
// Provider extension).
import FileProvider
import Foundation
import Security

enum Magpie {
    /// Shared between the app and the extension.
    static let appGroup: String = {
        #if os(macOS)
        return "UK74VYMUP7.dev.mandip.magpie"
        #else
        return "group.dev.mandip.magpie"
        #endif
    }()
    static let keychainGroup = "UK74VYMUP7.dev.mandip.magpie.shared"
    static let domainID = "magpie"
    static let serviceName = NSFileProviderServiceName("dev.mandip.magpie.service")

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
    }
    /// The engine's state: device certificate, index, outbox.
    static var engineDir: URL { containerURL.appendingPathComponent("engine", isDirectory: true) }
}

struct Entry: Codable, Hashable {
    var Path: String
    var Dir: Bool
    var Size: Int64
    var Modified: Date
    var Version: String
    var OnHub: Bool
    var ModifiedBy: String

    var name: String { (Path as NSString).lastPathComponent }
    var parent: String {
        let p = (Path as NSString).deletingLastPathComponent
        return p == "/" ? "" : p
    }
}

struct EngineStatus: Codable, Equatable {
    var Connected = false
    var Accepted = false
    var Ready = false
    var Paused = false
    var Files = 0
    var Bytes: Int64 = 0
    var UploadsLeft = 0
    var UploadBytes: Int64 = 0
    var LastError = ""
    var DeviceID = ""
}

struct Conflict: Codable, Hashable, Identifiable {
    var Copy: String
    var Original: String
    var CopyBy: String
    var When: Date
    var id: String { Copy }
    var fileName: String { (Original as NSString).lastPathComponent }
}

struct DeviceInfo: Codable, Hashable, Identifiable {
    var ID: String
    var Name: String
    var ThisOne: Bool
    var Hub: Bool
    var id: String { ID }
}

enum Keep: Int { case both = 0, original = 1, copy = 2 }

/// Decodes the engine's JSON (Go's time.Time is RFC 3339 with fractions).
let engineDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { dec in
        let s = try dec.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
    return d
}()

/// The device's Magpie config (hub, folder, password, invite key) as the
/// engine's JSON, kept in the shared keychain group.
enum ConfigStore {
    private static let account = "magpie-config"

    static func load() -> String? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ json: String) -> Bool {
        SecItemDelete(base() as CFDictionary)
        var q = base()
        q[kSecValueData as String] = Data(json.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func clear() { SecItemDelete(base() as CFDictionary) }

    private static func base() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.mandip.magpie",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Magpie.keychainGroup,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }
}

/// A short human size: "6.2 GB".
func humanBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
