import Foundation
import PostgresNIO

enum DatabaseError: Error {
    case missingURL
    case invalidURL
}

enum Database {
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
}
