import Foundation
import Observation
import PostgresNIO

enum ConnectionState {
    case disconnected
    case connecting
    case connected(serverVersion: String)
    case failed(Error)

    var statusText: String {
        switch self {
        case .disconnected: "未接続"
        case .connecting: "接続中…"
        case .connected(let version): "接続済み（PostgreSQL \(version)）"
        case .failed(DatabaseError.missingURL): "DATABASE_URL が設定されていません"
        case .failed(DatabaseError.invalidURL): "DATABASE_URL の形式が正しくありません"
        case .failed: "接続に失敗しました"
        }
    }

    var buttonTitle: String {
        if case .connected = self { "切断" } else { "DBに接続" }
    }

    var isConnecting: Bool {
        if case .connecting = self { true } else { false }
    }
}

enum ContentTab: String, CaseIterable, Identifiable {
    case data = "データ"
    case schema = "スキーマ"
    case sql = "SQL"

    var id: Self { self }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    var connectionState: ConnectionState = .disconnected
    let profiles = ConnectionStore.loadProfiles()
    private(set) var selectedTarget = ConnectionStore.selectedTarget
    private(set) var connection: PostgresConnection?

    private(set) var tables: [TableName] = []
    private(set) var tableKinds: [TableName: RelationKind] = [:]
    var selectedTable: TableName?
    var tab: ContentTab = .data
    var alert: AppAlert?

    func toggleConnection() {
        if connection == nil { connect() } else { disconnect() }
    }

    /// 接続中に別の接続先を選んだら、そちらへつなぎ直す
    func selectTarget(_ target: ConnectionTarget) {
        guard target != selectedTarget else { return }
        selectedTarget = target
        guard connection != nil else { return }
        disconnect()
        connect()
    }

    func connect() {
        let target = selectedTarget
        // 保存した接続先は URL とパスワード（Keychain）、DATABASE_URL は環境変数か .env から読む
        var urlString: String?
        var password: String?
        if case .profile(let id) = target {
            guard let profile = profiles.first(where: { $0.id == id }) else {
                connectionState = .failed(DatabaseError.missingURL)
                return
            }
            urlString = profile.url
            password = Keychain.password(for: id.uuidString)
        }
        connectionState = .connecting
        Task {
            do {
                let connection = try await Database.connect(urlString: urlString, password: password)
                let version: String
                let tables: [(table: TableName, kind: RelationKind)]
                do {
                    version = try await Database.serverVersion(of: connection)
                    tables = try await Database.listTables(on: connection)
                } catch {
                    try? await connection.close()
                    throw error
                }
                // 接続中に別の接続先が選ばれていたら、この接続は使わない
                guard selectedTarget == target else {
                    try? await connection.close()
                    connectionState = .disconnected
                    return
                }
                self.connection = connection
                self.tables = tables.map(\.table)
                tableKinds = Dictionary(tables.map { ($0.table, $0.kind) }, uniquingKeysWith: { first, _ in first })
                connectionState = .connected(serverVersion: version)
                selectedTable = self.tables.first
            } catch {
                connectionState = .failed(error)
            }
        }
    }

    func disconnect() {
        guard let connection else { return }
        self.connection = nil
        tables = []
        tableKinds = [:]
        selectedTable = nil
        connectionState = .disconnected
        Task { try? await connection.close() }
    }

    func selectionDidChange() {}
}
