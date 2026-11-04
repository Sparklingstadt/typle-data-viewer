import Foundation
import PostgresNIO

enum DatabaseError: Error {
    case missingURL
    case invalidURL
    /// SQL 欄で、読み取り用（SELECT など）以外の文が入力された
    case unsupportedStatement
}

struct TableName: Hashable, Sendable {
    let schema: String
    let name: String

    var displayName: String { schema == "public" ? name : "\(schema).\(name)" }

    /// SQL にそのまま書ける、引用符付きの "schema"."name"
    var sqlName: String { "\(Database.quoteIdentifier(schema)).\(Database.quoteIdentifier(name))" }
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

/// スキーマタブの内容。columns は列ごとに 名前・型・NOT NULL・既定値・キー
struct TableSchema: Sendable {
    let columns: [[String?]]
    let estimatedRowCount: Int?
    let tableSize: String
    let totalSize: String
    let indexes: [String]
}

/// SQL 欄で実行した結果。行数の上限を超えた分は読まず、isTruncated を立てる
struct QueryResult: Sendable {
    let columns: [String]
    let rows: [[String?]]
    let isTruncated: Bool
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

    /// スキーマタブに出す内容をまとめて読む
    static func fetchSchema(_ table: TableName, on connection: PostgresConnection) async throws -> TableSchema {
        let columns = try await fetchSchemaColumns(table, on: connection)
        let summary = try await fetchTableSummary(table, on: connection)
        let indexes = try await fetchIndexes(table, on: connection)
        return TableSchema(
            columns: columns,
            estimatedRowCount: summary.estimatedRowCount,
            tableSize: summary.tableSize,
            totalSize: summary.totalSize,
            indexes: indexes
        )
    }

    /// テーブルの列ごとの名前・型・NOT NULL・既定値・キー。型は integer[] や varchar(255) のように SQL の表記で返す。
    /// キーはその列を含む制約で、PK・UNIQUE・FK → 参照先テーブル(列) をカンマ区切りで並べる
    private static func fetchSchemaColumns(_ table: TableName, on connection: PostgresConnection) async throws -> [[String?]] {
        let rows = try await connection.query(
            """
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid),
              (SELECT string_agg(
                  CASE c.contype
                    WHEN 'p' THEN 'PK'
                    WHEN 'u' THEN 'UNIQUE'
                    ELSE 'FK → ' || c.confrelid::regclass::text || '(' || (
                      SELECT string_agg(quote_ident(fa.attname), ', ' ORDER BY k.ord)
                      FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = k.attnum
                    ) || ')'
                  END,
                  ', ' ORDER BY CASE c.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 ELSE 2 END, c.conname)
               FROM pg_constraint c
               WHERE c.conrelid = a.attrelid AND a.attnum = ANY (c.conkey) AND c.contype IN ('p', 'u', 'f'))
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = format('%I.%I', \(table.schema), \(table.name))::regclass
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            logger: logger
        )
        var columns: [[String?]] = []
        for try await (name, type, notNull, defaultValue, keys) in rows.decode(
            (String, String, Bool, String?, String?).self
        ) {
            columns.append([name, type, notNull ? "NOT NULL" : "", defaultValue, keys])
        }
        return columns
    }

    /// 統計上の推定行数と、テーブル単体・インデックスなどを含めた大きさ。
    /// 推定行数は一度も ANALYZE されていないと -1 になるので、そのときは nil にする
    private static func fetchTableSummary(
        _ table: TableName, on connection: PostgresConnection
    ) async throws -> (estimatedRowCount: Int?, tableSize: String, totalSize: String) {
        let rows = try await connection.query(
            """
            SELECT c.reltuples::bigint, pg_size_pretty(pg_table_size(c.oid)), pg_size_pretty(pg_total_relation_size(c.oid))
            FROM pg_class c
            WHERE c.oid = format('%I.%I', \(table.schema), \(table.name))::regclass
            """,
            logger: logger
        )
        for try await (rowCount, tableSize, totalSize) in rows.decode((Int, String, String).self) {
            return (rowCount >= 0 ? rowCount : nil, tableSize, totalSize)
        }
        return (nil, "?", "?")
    }

    /// インデックスの定義（CREATE INDEX … の形）。主キー、UNIQUE、その他の順
    private static func fetchIndexes(_ table: TableName, on connection: PostgresConnection) async throws -> [String] {
        let rows = try await connection.query(
            """
            SELECT pg_get_indexdef(i.indexrelid)
            FROM pg_index i
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = format('%I.%I', \(table.schema), \(table.name))::regclass
            ORDER BY i.indisprimary DESC, i.indisunique DESC, ic.relname
            """,
            logger: logger
        )
        var indexes: [String] = []
        for try await definition in rows.decode(String.self) {
            indexes.append(definition)
        }
        return indexes
    }

    // MARK: - SQL query

    /// SQL 欄の結果として読む行数の上限
    static let queryRowLimit = 1000

    /// SQL 欄に書かれた文を読み取り専用で実行する。
    /// - 拡張問い合わせプロトコルで送るので、サーバーは1つの文しか受け付けない（; で続けた2つ目の文は実行されない）
    /// - BEGIN READ ONLY のトランザクション内で実行し、最後は必ず ROLLBACK する。書き込みはサーバーが拒否する
    /// - 長いクエリで固まらないよう、30 秒で打ち切る
    static func runReadOnlyQuery(_ sql: String, on connection: PostgresConnection) async throws -> QueryResult {
        let statement = trimmedStatement(sql)
        guard !statement.isEmpty else { return QueryResult(columns: [], rows: [], isTruncated: false) }

        let keyword = leadingKeyword(of: statement)
        let wrapsInSubquery: Bool
        switch keyword {
        case "SELECT", "WITH", "VALUES", "TABLE": wrapsInSubquery = true
        case "EXPLAIN", "SHOW": wrapsInSubquery = false
        default: throw DatabaseError.unsupportedStatement
        }

        _ = try await connection.query("BEGIN READ ONLY", logger: logger)
        do {
            _ = try await connection.query("SET LOCAL statement_timeout = '30s'", logger: logger)
            let result: QueryResult
            if wrapsInSubquery {
                result = try await runWrapped(statement, on: connection)
            } else {
                result = try await runDirect(statement, on: connection)
            }
            _ = try await connection.query("ROLLBACK", logger: logger)
            return result
        } catch {
            _ = try? await connection.query("ROLLBACK", logger: logger)
            throw error
        }
    }

    /// SELECT 系の文は副問い合わせに包み、全列をサーバー側で text にして受け取る。
    /// 列名が重複していても扱えるよう、AS q(c0, c1, …) で位置ごとに別名を付けてから参照する
    private static func runWrapped(_ statement: String, on connection: PostgresConnection) async throws -> QueryResult {
        // 1回目は行を読まずに列名だけ得る。末尾が -- のコメントでも閉じ括弧が隠れないよう、改行を挟む
        let probe = PostgresQuery(unsafeSQL: "SELECT * FROM (\n\(statement)\n) AS q LIMIT 0")
        let probeRows = try await connection.query(probe, logger: logger)
        let columns = probeRows.columns.map(\.name)
        for try await _ in probeRows {}
        guard !columns.isEmpty else { return QueryResult(columns: [], rows: [], isTruncated: false) }

        let aliases = columns.indices.map { "c\($0)" }
        let selectList = aliases.map { "\($0)::text" }.joined(separator: ", ")
        let sql = "SELECT \(selectList) FROM (\n\(statement)\n) AS q(\(aliases.joined(separator: ", ")))"
            + " LIMIT \(queryRowLimit + 1)"

        var rows: [[String?]] = []
        for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {
            rows.append(try row.map { try $0.decode(String?.self) })
        }
        let isTruncated = rows.count > queryRowLimit
        return QueryResult(columns: columns, rows: Array(rows.prefix(queryRowLimit)), isTruncated: isTruncated)
    }

    /// EXPLAIN と SHOW は副問い合わせにできないので、そのまま実行する。どちらも結果は文字列（text か json）
    private static func runDirect(_ statement: String, on connection: PostgresConnection) async throws -> QueryResult {
        let result = try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        let columns = result.columns.map(\.name)
        var rows: [[String?]] = []
        var isTruncated = false
        for try await row in result {
            guard rows.count < queryRowLimit else {
                isTruncated = true
                continue
            }
            rows.append(row.map { cell in
                // json はバイナリ形式でも中身は JSON の文字列なので、String にできない型はバイト列をそのまま読む
                (try? cell.decode(String?.self)) ?? cell.bytes.map { String(buffer: $0) }
            })
        }
        return QueryResult(columns: columns, rows: rows, isTruncated: isTruncated)
    }

    /// 前後の空白と、末尾のセミコロンを取り除く
    private static func trimmedStatement(_ sql: String) -> String {
        var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") {
            statement = String(statement.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return statement
    }

    /// 先頭のコメント（-- と /* */）と開き括弧を飛ばした、最初の単語を大文字で返す
    private static func leadingKeyword(of statement: String) -> String {
        var rest = Substring(statement)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "(" }
            if rest.hasPrefix("--") {
                rest = rest.drop { !$0.isNewline }
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return "" }
                rest = rest[end.upperBound...]
            } else {
                break
            }
        }
        return rest.prefix { $0.isLetter }.uppercased()
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

    static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
