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

/// データタブの表示条件。列は列名で指定する
struct TableQuery: Equatable, Sendable {
    /// 絞り込む列。nil ならすべての列のどれかに一致する行を出す
    var filterColumn: String?
    var filterText = ""
    var sortColumn: String?
    var ascending = true
    /// 何行目から表示するか（0 始まり）
    var offset = 0
}

/// 1ページ分の行と、絞り込み後の総件数
struct TablePage: Sendable {
    let columns: [String]
    let rows: [[String?]]
    let totalCount: Int
}

enum Database {
    /// 大きなテーブルでも固まらないよう、1ページに表示する行数
    static let pageSize = 1000

    /// 比較演算子がなく ORDER BY できない型。これらは text にして並べる
    private static let unorderableTypes: Set<String> = [
        "json", "xml", "point", "line", "lseg", "box", "path", "polygon", "circle",
    ]

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

    /// データタブに出す1ページ分を読む。絞り込み・並べ替え・ページ送りはすべてサーバー側で行う
    static func fetchTable(_ table: TableName, query: TableQuery, on connection: PostgresConnection) async throws -> TablePage {
        let columnRows = try await connection.query(
            """
            SELECT column_name, data_type FROM information_schema.columns
            WHERE table_schema = \(table.schema) AND table_name = \(table.name)
            ORDER BY ordinal_position
            """,
            logger: logger
        )
        var columns: [String] = []
        var dataTypes: [String: String] = [:]
        for try await (column, dataType) in columnRows.decode((String, String).self) {
            columns.append(column)
            dataTypes[column] = dataType
        }
        guard !columns.isEmpty else { return TablePage(columns: [], rows: [], totalCount: 0) }

        let source = "\(quoteIdentifier(table.schema)).\(quoteIdentifier(table.name))"

        // 検索語は $1 に入れ、どの列とも text にして部分一致（大文字小文字を区別しない）で比べる
        var whereClause = ""
        var binds = PostgresBindings()
        let filterText = query.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filterText.isEmpty {
            let targets = query.filterColumn.map { columns.contains($0) ? [$0] : columns } ?? columns
            let conditions = targets.map { "\(quoteIdentifier($0))::text ILIKE $1" }
            whereClause = " WHERE " + conditions.joined(separator: " OR ")
            binds.append("%" + escapeLikePattern(filterText) + "%")
        }

        // 絞り込み後の件数。ページ送りと「全 N 件」の表示に使う
        let countQuery = PostgresQuery(unsafeSQL: "SELECT count(*) FROM \(source)\(whereClause)", binds: binds)
        var totalCount = 0
        for try await count in try await connection.query(countQuery, logger: logger).decode(Int.self) {
            totalCount = count
        }

        // 並べ替えは元の型のまま行うので、数値や日付も正しい順になる。NULL は昇順で先頭、降順で末尾。
        // 同じ値の行や並べ替えなしのときもページ間で行が重複・欠落しないよう、最後に ctid で順序を固定する
        var orderTerms: [String] = []
        if let sortColumn = query.sortColumn, columns.contains(sortColumn) {
            var expression = quoteIdentifier(sortColumn)
            if let dataType = dataTypes[sortColumn], unorderableTypes.contains(dataType) {
                expression += "::text"
            }
            orderTerms.append(expression + (query.ascending ? " ASC NULLS FIRST" : " DESC NULLS LAST"))
        }
        orderTerms.append("ctid")

        // 型ごとのデコードを避けるため、全列をサーバー側で text に変換して受け取る
        let selectList = columns.map { "\(quoteIdentifier($0))::text" }.joined(separator: ", ")
        let offset = max(0, query.offset)
        let sql = "SELECT \(selectList) FROM \(source)\(whereClause)"
            + " ORDER BY \(orderTerms.joined(separator: ", ")) LIMIT \(pageSize) OFFSET \(offset)"

        var rows: [[String?]] = []
        for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: logger) {
            rows.append(try row.map { try $0.decode(String?.self) })
        }
        return TablePage(columns: columns, rows: rows, totalCount: totalCount)
    }

    /// テーブルの列ごとの名前・型・NOT NULL・既定値。型は integer[] や varchar(255) のように SQL の表記で返す
    static func fetchSchema(_ table: TableName, on connection: PostgresConnection) async throws -> [[String?]] {
        let rows = try await connection.query(
            """
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = format('%I.%I', \(table.schema), \(table.name))::regclass
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            logger: logger
        )
        var columns: [[String?]] = []
        for try await (name, type, notNull, defaultValue) in rows.decode((String, String, Bool, String?).self) {
            columns.append([name, type, notNull ? "NOT NULL" : "", defaultValue])
        }
        return columns
    }

    /// LIKE の特殊文字（% と _）を文字どおりに扱うよう、既定のエスケープ文字 \ を前に付ける
    private static func escapeLikePattern(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
