import Foundation
import PostgresNIO

enum DatabaseError: Error {
    case missingURL
    case invalidURL
}

struct TableName: Hashable, Sendable {
    let schema: String
    let name: String

    var displayName: String { schema == "public" ? name : "\(schema).\(name)" }
}

struct TableData: Sendable {
    let columns: [String]
    let rows: [[String?]]
}

enum Database {
    /// 大きなテーブルでも固まらないよう、表示する行数の上限
    static let rowLimit = 1000

    private static let logger = Logger(label: "typle-data-viewer.database")

    /// Neon の接続文字列（postgresql://user:password@host/db?sslmode=require）を
    /// 環境変数 DATABASE_URL、なければカレントディレクトリの .env から読む
    static func connectionURL() -> String? {
        if let url = ProcessInfo.processInfo.environment["DATABASE_URL"], !url.isEmpty {
            return url
        }

        let envPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: envPath, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DATABASE_URL=") else { continue }
            let value = trimmed.dropFirst("DATABASE_URL=".count)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func connect() async throws -> PostgresConnection {
        guard let urlString = connectionURL() else { throw DatabaseError.missingURL }
        guard let components = URLComponents(string: urlString),
              let host = components.host,
              let username = components.user else { throw DatabaseError.invalidURL }

        let database = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : nil
        // Neon は TLS 必須。ホスト名がそのまま SNI に使われ、エンドポイントの識別に必要になる
        let tls = try PostgresConnection.Configuration.TLS.require(
            NIOSSLContext(configuration: .makeClientConfiguration())
        )
        let configuration = PostgresConnection.Configuration(
            host: host,
            port: components.port ?? 5432,
            username: username,
            password: components.password,
            database: database?.isEmpty == false ? database : nil,
            tls: tls
        )
        return try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
    }

    static func serverVersion(of connection: PostgresConnection) async throws -> String {
        let rows = try await connection.query("SELECT current_setting('server_version')", logger: logger)
        for try await version in rows.decode(String.self) {
            return version
        }
        return "?"
    }

    static func listTables(on connection: PostgresConnection) async throws -> [TableName] {
        let rows = try await connection.query(
            """
            SELECT table_schema, table_name FROM information_schema.tables
            WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name
            """,
            logger: logger
        )
        var tables: [TableName] = []
        for try await (schema, name) in rows.decode((String, String).self) {
            tables.append(TableName(schema: schema, name: name))
        }
        return tables
    }

    static func fetchTable(_ table: TableName, on connection: PostgresConnection) async throws -> TableData {
        let columnRows = try await connection.query(
            """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = \(table.schema) AND table_name = \(table.name)
            ORDER BY ordinal_position
            """,
            logger: logger
        )
        var columns: [String] = []
        for try await column in columnRows.decode(String.self) {
            columns.append(column)
        }
        guard !columns.isEmpty else { return TableData(columns: [], rows: []) }

        // 型ごとのデコードを避けるため、全列をサーバー側で text に変換して受け取る
        let selectList = columns.map { "\(quoteIdentifier($0))::text" }.joined(separator: ", ")
        let source = "\(quoteIdentifier(table.schema)).\(quoteIdentifier(table.name))"
        let query = PostgresQuery(unsafeSQL: "SELECT \(selectList) FROM \(source) LIMIT \(rowLimit)")

        var rows: [[String?]] = []
        for try await row in try await connection.query(query, logger: logger) {
            rows.append(try row.map { try $0.decode(String?.self) })
        }
        return TableData(columns: columns, rows: rows)
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
