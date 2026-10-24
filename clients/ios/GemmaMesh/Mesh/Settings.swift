import Foundation
import Security
import GemmaMeshKit

/// Settings kept on the phone: static nodes (paired or typed), mesh name, extra private terms, the frontier, the
/// device name. The frontier's API key goes in the Keychain; the rest in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    /// Nodes from a pairing code or typed in Settings (PROTOCOL §1 static nodes); health-checked like any other.
    static var nodes: [Node] {
        get { (d.data(forKey: "static_nodes")).flatMap { try? JSONDecoder().decode([Node].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue.filter { !$0.discovered }), forKey: "static_nodes") }
    }

    /// The mesh this phone belongs to; mDNS records from another mesh are ignored.
    static var mesh: String {
        get { d.string(forKey: "mesh") ?? "default" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces).isEmpty ? "default" : newValue, forKey: "mesh") }
    }

    /// Comma-separated client names, matters, codenames, added to the terms in policy/rules.yaml.
    static var terms: String {
        get { d.string(forKey: "terms") ?? "" }
        set { d.set(newValue, forKey: "terms") }
    }

    static var termList: [String] {
        terms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var frontier: Frontier {
        get { Frontier(baseUrl: d.string(forKey: "frontier_url"), model: d.string(forKey: "frontier_model"), apiKey: Keychain.get("frontier_key") ?? "") }
        set {
            d.set(newValue.baseUrl, forKey: "frontier_url")
            d.set(newValue.model, forKey: "frontier_model")
            Keychain.set("frontier_key", newValue.apiKey)
        }
    }

    /// The phone model the user chose in Settings (gemma4-e4b or gemma4-e2b); nil means by memory.
    static var localModel: String? {
        get { d.string(forKey: "local_model") }
        set { d.set(newValue, forKey: "local_model") }
    }

    /// This phone's device name: the prefix of every memory event id ("<device>:<seq>"), so it is fixed on first use.
    /// iOS no longer tells apps the user's device name, so it is the hardware model plus a short random tag, e.g.
    /// "iphone16-2-4f1a": two phones of the same model never share an id space.
    static var device: String {
        if let s = d.string(forKey: "device") { return s }
        var sys = utsname()
        uname(&sys)
        // On the simulator uname says only "arm64"; the simulated model is in the environment.
        let hardware: String = withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let machine: String = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware
        let base = machine.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let tag = String(UUID().uuidString.lowercased().prefix(4))
        let name = (base.isEmpty ? "iphone" : base) + "-" + tag
        d.set(name, forKey: "device")
        return name
    }
}

enum Keychain {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        if value.isEmpty { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
