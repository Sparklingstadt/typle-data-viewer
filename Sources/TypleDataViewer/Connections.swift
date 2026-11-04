import Foundation
import Security

/// 保存した接続先。パスワードは持たず、Keychain に id をキーにして入れる
struct ConnectionProfile: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// postgresql://user@host:port/db?sslmode=require の形。パスワードは取り除いてある
    var url: String
}

/// どこに接続するか。環境変数 DATABASE_URL（または .env）か、保存した接続先
enum ConnectionTarget: Equatable, Sendable {
    case environment
    case profile(UUID)

    /// UserDefaults やメニュー項目に持たせる文字列
    var key: String {
        switch self {
        case .environment: "env"
        case .profile(let id): id.uuidString
        }
    }

    init(key: String) {
        if let id = UUID(uuidString: key) {
            self = .profile(id)
        } else {
            self = .environment
        }
    }
}

/// 接続先の一覧と、最後に選んだ接続先を UserDefaults に保存する
enum ConnectionStore {
    private static let profilesKey = "connectionProfiles"
    private static let selectedKey = "selectedConnection"

    static func loadProfiles() -> [ConnectionProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return [] }
        return profiles
    }

    static func saveProfiles(_ profiles: [ConnectionProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }

    static var selectedTarget: ConnectionTarget {
        get { ConnectionTarget(key: UserDefaults.standard.string(forKey: selectedKey) ?? "env") }
        set { UserDefaults.standard.set(newValue.key, forKey: selectedKey) }
    }

    /// 接続 URL からパスワードを取り出し、パスワードを除いた URL と分けて返す。URL として読めなければ nil
    static func splitPassword(from url: String) -> (url: String, password: String?)? {
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host?.isEmpty == false, components.user?.isEmpty == false else { return nil }
        let password = components.password
        components.password = nil
        guard let stripped = components.string else { return nil }
        return (stripped, password)
    }
}

/// 接続先のパスワードを、ログインキーチェーンの汎用パスワードとして保存する
enum Keychain {
    private static let service = "TypleDataViewer"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 空のパスワードを渡すと、保存してあるものを消す
    static func setPassword(_ password: String?, for account: String) {
        deletePassword(for: account)
        guard let password, !password.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Typle Data Viewer",
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
