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

    /// データタブの表示条件。絞り込みの入力欄と列の選択はここへ直接書く
    var query = TableQuery()
    private(set) var dataSort: [GridSort] = []
    private(set) var gridColumns: [GridColumn] = []
    private(set) var gridRows: [GridRow] = []
    private(set) var numericColumns: Set<Int> = []
    private(set) var totalCount = 0
    /// いま表に出ているページの先頭。query.offset は読み込み中の次のページを指すことがある
    private(set) var displayedOffset = 0
    /// いま query が対象にしているテーブル。別のテーブルに移ったら条件を初期状態に戻す
    private var queryTable: TableName?
    /// 読み込みのたびに増やす。完了時に番号が古ければ結果を捨てる
    private(set) var loadGeneration = 0

    private(set) var schema: TableSchema?
    private(set) var schemaRows: [GridRow] = []
    let schemaColumns = GridLogic.columns(["列名", "型", "NOT NULL", "既定値", "キー"])
    /// スキーマは手元で並べ替える
    var schemaSort: [GridSort] = [] {
        didSet { schemaRows = schemaRows.sorted(using: schemaSort) }
    }

    var sqlText = ""
    private(set) var isRunningQuery = false
    private(set) var queryResult: QueryResult?
    private(set) var queryDuration: TimeInterval = 0
    private(set) var queryColumns: [GridColumn] = []
    private(set) var queryRows: [GridRow] = []
    /// SQL の結果は手元で並べ替える
    var querySort: [GridSort] = [] {
        didSet { queryRows = queryRows.sorted(using: querySort) }
    }
    private var queryGeneration = 0

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
        loadGeneration += 1
        clearDisplayedTable()
        connectionState = .disconnected
        Task { try? await connection.close() }
    }

    func selectionDidChange() {
        guard selectedTable != queryTable else { return }
        // SQL タブでは読み込みが走らないので、ここで前のテーブルの読み込み結果を無効にする
        loadGeneration += 1
        queryTable = selectedTable
        query = TableQuery()
        dataSort = []
        loadSelected()
    }

    /// 選択中のテーブルを、いまの条件で読む
    func loadSelected() {
        guard let connection, let table = selectedTable else { return }
        switch tab {
        case .data: loadData(table, on: connection)
        case .schema: loadSchema(table, on: connection)
        case .sql:
            // SQL タブではテーブルを読まない。入力欄が空なら、そのテーブルを見る SELECT を入れておく
            if sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sqlText = GridLogic.defaultSelect(for: table)
            }
        }
    }

    private func loadData(_ table: TableName, on connection: PostgresConnection) {
        let query = query
        let kind = tableKinds[table] ?? .table
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            do {
                let page = try await Database.fetchTable(table, kind: kind, query: query, on: connection)
                // 読み込み中に別のテーブルや条件が選ばれていたら、古い結果は捨てる
                guard generation == loadGeneration else { return }
                // 再読み込みで行が減り、いまのページが範囲外になったら最後のページを読み直す
                if page.rows.isEmpty, query.offset > 0, page.totalCount > 0 {
                    self.query.offset = GridLogic.lastPageOffset(totalCount: page.totalCount, pageSize: Database.pageSize)
                    loadSelected()
                    return
                }
                gridColumns = GridLogic.columns(page.columns)
                gridRows = GridLogic.rows(page.rows)
                displayedOffset = query.offset
                numericColumns = page.numericColumns
                totalCount = page.totalCount
            } catch {
                guard generation == loadGeneration else { return }
                alert = AppAlert(title: "テーブル「\(table.displayName)」を読み込めませんでした", message: String(reflecting: error))
            }
        }
    }

    private func loadSchema(_ table: TableName, on connection: PostgresConnection) {
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            do {
                let fetched = try await Database.fetchSchema(table, on: connection)
                guard generation == loadGeneration else { return }
                schema = fetched
                schemaRows = GridLogic.rows(fetched.columns).sorted(using: schemaSort)
            } catch {
                guard generation == loadGeneration else { return }
                alert = AppAlert(title: "テーブル「\(table.displayName)」を読み込めませんでした", message: String(reflecting: error))
            }
        }
    }

    func reload() {
        loadSelected()
    }

    func runQuery() {
        guard let connection, !isRunningQuery else { return }
        let sql = sqlText
        queryGeneration += 1
        let generation = queryGeneration
        isRunningQuery = true
        let start = Date()
        Task {
            do {
                let result = try await Database.runReadOnlyQuery(sql, on: connection)
                guard generation == queryGeneration else { return }
                isRunningQuery = false
                // 実行中に切断していたら結果は捨てる
                guard self.connection === connection else { return }
                queryDuration = Date().timeIntervalSince(start)
                queryResult = result
                queryColumns = GridLogic.columns(result.columns)
                querySort = []
                queryRows = GridLogic.rows(result.rows)
            } catch {
                guard generation == queryGeneration else { return }
                isRunningQuery = false
                alert = AppAlert(title: "SQL を実行できませんでした", message: Self.queryErrorText(error))
            }
        }
    }

    var queryStatusText: String {
        if connection == nil { return "DBに接続すると実行できます" }
        if isRunningQuery { return "実行中…" }
        guard let queryResult else { return "SELECT・WITH・VALUES・TABLE・EXPLAIN・SHOW を読み取り専用で実行します（⌘↩）" }
        return GridLogic.queryStatusText(
            rowCount: queryResult.rows.count, seconds: queryDuration, isTruncated: queryResult.isTruncated
        )
    }

    /// エラーの説明。サーバーのエラーなら、メッセージ・詳細・ヒントだけを見せる
    private static func queryErrorText(_ error: Error) -> String {
        if case DatabaseError.unsupportedStatement = error {
            return "読み取り専用のため、SELECT・WITH・VALUES・TABLE・EXPLAIN・SHOW で始まる文だけを実行できます。"
        }
        if let serverInfo = (error as? PSQLError)?.serverInfo, let message = serverInfo[.message] {
            return [message, serverInfo[.detail], serverInfo[.hint]].compactMap { $0 }.joined(separator: "\n")
        }
        return String(reflecting: error)
    }

    func applyFilter() {
        query.offset = 0
        loadSelected()
    }

    /// 見出しのクリックで呼ばれる。データタブの並べ替えは DB に任せる
    func sortData(by order: [GridSort]) {
        dataSort = order
        guard let sort = order.first, gridColumns.indices.contains(sort.column) else { return }
        query.sortColumn = gridColumns[sort.column].name
        query.ascending = sort.order == .forward
        query.offset = 0
        loadSelected()
    }

    var hasNextPage: Bool { displayedOffset + gridRows.count < totalCount }
    var hasPreviousPage: Bool { displayedOffset > 0 }

    func nextPage() {
        guard hasNextPage else { return }
        query.offset = displayedOffset + Database.pageSize
        loadSelected()
    }

    func previousPage() {
        guard hasPreviousPage else { return }
        query.offset = max(0, displayedOffset - Database.pageSize)
        loadSelected()
    }

    private func clearDisplayedTable() {
        queryTable = nil
        query = TableQuery()
        dataSort = []
        gridColumns = []
        gridRows = []
        displayedOffset = 0
        numericColumns = []
        totalCount = 0
        schema = nil
        schemaRows = []
        schemaSort = []
        queryResult = nil
        queryColumns = []
        queryRows = []
        querySort = []
    }
}
