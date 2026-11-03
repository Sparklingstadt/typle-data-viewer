import AppKit
import PostgresNIO

enum Language: CaseIterable {
    case japanese
    case english

    // 各言語はその言語自身の表記で選択肢に出す
    var displayName: String {
        switch self {
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}

enum ConnectionState {
    case disconnected
    case connecting
    case connected(serverVersion: String)
    case failed(Error)

    func statusText(in language: Language) -> String {
        switch (self, language) {
        case (.disconnected, .japanese): "未接続"
        case (.disconnected, .english): "Not connected"
        case (.connecting, .japanese): "接続中…"
        case (.connecting, .english): "Connecting…"
        case (.connected(let version), .japanese): "接続済み（PostgreSQL \(version)）"
        case (.connected(let version), .english): "Connected (PostgreSQL \(version))"
        case (.failed(DatabaseError.missingURL), .japanese): "DATABASE_URL が設定されていません"
        case (.failed(DatabaseError.missingURL), .english): "DATABASE_URL is not set"
        case (.failed(DatabaseError.invalidURL), .japanese): "DATABASE_URL の形式が正しくありません"
        case (.failed(DatabaseError.invalidURL), .english): "DATABASE_URL is malformed"
        case (.failed, .japanese): "接続に失敗しました"
        case (.failed, .english): "Connection failed"
        }
    }

    func buttonTitle(in language: Language) -> String {
        switch (self, language) {
        case (.connected, .japanese): "切断"
        case (.connected, .english): "Disconnect"
        case (_, .japanese): "DBに接続"
        case (_, .english): "Connect to DB"
        }
    }
}

struct FruitRow {
    let number: Int
    let fruitJapanese: String
    let fruitEnglish: String
    let count: Int

    func fruit(in language: Language) -> String {
        switch language {
        case .japanese: fruitJapanese
        case .english: fruitEnglish
        }
    }
}

/// DB から読んだ1行。ソート後も同値の行を元の順に並べるため、取得時の順番を持つ
struct DatabaseRow {
    let order: Int
    let values: [String?]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var tablePopUp: NSPopUpButton!
    private var connectButton: NSButton!
    private var statusLabel: NSTextField!
    private var language: Language = .japanese
    private var connection: PostgresConnection?
    private var connectionState: ConnectionState = .disconnected {
        didSet { updateConnectionUI() }
    }

    /// 接続中は DB のテーブル一覧、未接続時は空
    private var tables: [TableName] = []
    /// 表示中の DB テーブル。nil のときはサンプルの果物データを表示する
    private var databaseColumns: [String]?
    private var databaseRows: [DatabaseRow] = []
    /// 列の入れ替え中は、古い列のまま新しいデータで描画しないよう再描画を止める
    private var isRebuildingColumns = false

    private var rows: [FruitRow] = [
        FruitRow(number: 1, fruitJapanese: "りんご", fruitEnglish: "Apple", count: 2),
        FruitRow(number: 2, fruitJapanese: "バナナ", fruitEnglish: "Banana", count: 4),
        FruitRow(number: 3, fruitJapanese: "オレンジ", fruitEnglish: "Orange", count: 4),
    ]

    private enum Column: String, CaseIterable {
        case number
        case fruit
        case count

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        func title(in language: Language) -> String {
            switch (self, language) {
            case (.number, .japanese): "番号"
            case (.fruit, .japanese): "果物"
            case (.count, .japanese): "個数"
            case (.number, .english): "No."
            case (.fruit, .english): "Fruit"
            case (.count, .english): "Count"
            }
        }
    }

    private static let databaseColumnPrefix = "db."

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typle Data Viewer"

        let languagePopUp = NSPopUpButton()
        languagePopUp.addItems(withTitles: Language.allCases.map(\.displayName))
        languagePopUp.selectItem(at: Language.allCases.firstIndex(of: language) ?? 0)
        languagePopUp.target = self
        languagePopUp.action = #selector(languageDidChange(_:))
        languagePopUp.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "データ")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        tablePopUp = NSPopUpButton()
        tablePopUp.target = self
        tablePopUp.action = #selector(tableSelectionDidChange(_:))
        tablePopUp.isHidden = true
        tablePopUp.translatesAutoresizingMaskIntoConstraints = false

        connectButton = NSButton(title: "", target: self, action: #selector(connectButtonClicked(_:)))
        connectButton.bezelStyle = .push
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        updateConnectionUI()

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        rebuildColumns()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(titleLabel)
        contentView.addSubview(tablePopUp)
        contentView.addSubview(statusLabel)
        contentView.addSubview(connectButton)
        contentView.addSubview(languagePopUp)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            languagePopUp.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            languagePopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            connectButton.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            connectButton.trailingAnchor.constraint(equalTo: languagePopUp.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tablePopUp.trailingAnchor, constant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),

            tablePopUp.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            tablePopUp.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: languagePopUp.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 終了処理は待てないので、EventLoopFuture 版で閉じるだけ依頼する
        let _: EventLoopFuture<Void>? = connection?.close()
    }

    // MARK: - Connection

    @objc private func connectButtonClicked(_ sender: NSButton) {
        if case .connected = connectionState {
            disconnect()
        } else {
            connect()
        }
    }

    private func connect() {
        connectionState = .connecting
        Task {
            do {
                let connection = try await Database.connect()
                let version: String
                let tables: [TableName]
                do {
                    version = try await Database.serverVersion(of: connection)
                    tables = try await Database.listTables(on: connection)
                } catch {
                    try? await connection.close()
                    throw error
                }
                self.connection = connection
                self.tables = tables
                connectionState = .connected(serverVersion: version)
                updateTablePopUp()
                if let first = tables.first {
                    loadTable(first)
                }
            } catch {
                connectionState = .failed(error)
            }
        }
    }

    private func disconnect() {
        guard let connection else { return }
        self.connection = nil
        tables = []
        connectionState = .disconnected
        updateTablePopUp()
        showSampleData()
        Task { try? await connection.close() }
    }

    private func updateConnectionUI() {
        guard let connectButton, let statusLabel else { return }
        connectButton.title = connectionState.buttonTitle(in: language)
        statusLabel.stringValue = connectionState.statusText(in: language)
        if case .connecting = connectionState {
            connectButton.isEnabled = false
        } else {
            connectButton.isEnabled = true
        }
        // 詳細なエラーはツールチップで確認できるようにする
        if case .failed(let error) = connectionState {
            statusLabel.toolTip = String(reflecting: error)
        } else {
            statusLabel.toolTip = nil
        }
    }

    // MARK: - Database tables

    private func updateTablePopUp() {
        let selected = tablePopUp.indexOfSelectedItem
        tablePopUp.removeAllItems()
        tablePopUp.isHidden = connection == nil
        if tables.isEmpty {
            tablePopUp.addItem(withTitle: language == .japanese ? "テーブルがありません" : "No tables")
            tablePopUp.isEnabled = false
        } else {
            tablePopUp.addItems(withTitles: tables.map(\.displayName))
            tablePopUp.isEnabled = true
            if tables.indices.contains(selected) {
                tablePopUp.selectItem(at: selected)
            }
        }
    }

    @objc private func tableSelectionDidChange(_ sender: NSPopUpButton) {
        guard tables.indices.contains(sender.indexOfSelectedItem) else { return }
        loadTable(tables[sender.indexOfSelectedItem])
    }

    private func loadTable(_ table: TableName) {
        guard let connection else { return }
        Task {
            do {
                let data = try await Database.fetchTable(table, on: connection)
                // 読み込み中に別のテーブルが選ばれていたら、古い結果は捨てる
                guard self.connection === connection,
                      tables.indices.contains(tablePopUp.indexOfSelectedItem),
                      tables[tablePopUp.indexOfSelectedItem] == table else { return }
                databaseColumns = data.columns
                databaseRows = data.rows.enumerated().map { DatabaseRow(order: $0.offset, values: $0.element) }
                rebuildColumns()
                tableView.reloadData()
            } catch {
                let alert = NSAlert()
                alert.messageText = language == .japanese
                    ? "テーブル「\(table.displayName)」を読み込めませんでした"
                    : "Could not load table \"\(table.displayName)\""
                alert.informativeText = String(reflecting: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private func showSampleData() {
        databaseColumns = nil
        databaseRows = []
        rebuildColumns()
        tableView.reloadData()
    }

    // MARK: - Columns and sorting

    private func rebuildColumns() {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }
        // 列が入れ替わるので、前の列のソート指定は外す
        tableView.sortDescriptors = []
        for tableColumn in tableView.tableColumns {
            tableView.removeTableColumn(tableColumn)
        }

        if let databaseColumns {
            for (index, name) in databaseColumns.enumerated() {
                let key = Self.databaseColumnPrefix + String(index)
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
                tableColumn.title = name
                tableColumn.width = 140
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
                tableView.addTableColumn(tableColumn)
            }
        } else {
            for column in Column.allCases {
                let tableColumn = NSTableColumn(identifier: column.identifier)
                tableColumn.width = column == .fruit ? 200 : 100
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
                tableView.addTableColumn(tableColumn)
            }
            updateColumnTitles()
        }
    }

    @objc private func languageDidChange(_ sender: NSPopUpButton) {
        language = Language.allCases[sender.indexOfSelectedItem]
        updateConnectionUI()
        if tables.isEmpty {
            updateTablePopUp()
        }
        if databaseColumns == nil {
            updateColumnTitles()
            // 果物名は言語で並び順が変わるので、現在のソートをかけ直す
            sortRows()
            tableView.reloadData()
        }
    }

    private func updateColumnTitles() {
        for tableColumn in tableView.tableColumns {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.title = column.title(in: language)
        }
        tableView.headerView?.needsDisplay = true
    }

    private func sortRows() {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }

        if databaseColumns != nil {
            guard let index = Int(key.dropFirst(Self.databaseColumnPrefix.count)),
                  index < databaseColumns?.count ?? 0 else { return }
            databaseRows.sort { lhs, rhs in
                let order = compare(lhs.values[index], rhs.values[index])
                if order == .orderedSame { return lhs.order < rhs.order }
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return
        }

        guard let column = Column(rawValue: key) else { return }
        rows.sort { lhs, rhs in
            let order: ComparisonResult
            switch column {
            case .number: order = compare(lhs.number, rhs.number)
            case .fruit: order = lhs.fruit(in: language).localizedStandardCompare(rhs.fruit(in: language))
            case .count: order = compare(lhs.count, rhs.count)
            }
            // 値が同じ場合は番号順で並びを安定させる
            if order == .orderedSame { return lhs.number < rhs.number }
            return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    /// DB の値は text で受け取っているので、数字も数値として並ぶ比較を使う。NULL は先頭
    private func compare(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        case let (lhs?, rhs?): lhs.localizedStandardCompare(rhs)
        }
    }

    // MARK: - Cell values

    /// セルをダブルクリックしたら、その値を別ウインドウで全文表示する
    @objc private func tableViewDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        let columnIndex = sender.clickedColumn
        // 見出しや空白部分のダブルクリックは -1 になる
        guard row >= 0, sender.tableColumns.indices.contains(columnIndex) else { return }
        let tableColumn = sender.tableColumns[columnIndex]
        guard let value = cellValue(row: row, identifier: tableColumn.identifier) else { return }

        var title = tableColumn.title
        if databaseColumns != nil, tables.indices.contains(tablePopUp.indexOfSelectedItem) {
            title = "\(tables[tablePopUp.indexOfSelectedItem].displayName).\(title)"
        }
        title += language == .japanese ? "（\(row + 1)行目）" : " (row \(row + 1))"
        ValueWindowController.show(title: title, value: value)
    }

    /// 表に出している値。外側が nil なら該当するセルがない、内側が nil なら DB の NULL
    private func cellValue(row: Int, identifier: NSUserInterfaceItemIdentifier) -> String?? {
        if databaseColumns != nil {
            guard let index = Int(identifier.rawValue.dropFirst(Self.databaseColumnPrefix.count)),
                  databaseRows.indices.contains(row),
                  databaseRows[row].values.indices.contains(index) else { return nil }
            return .some(databaseRows[row].values[index])
        }

        guard let column = Column(rawValue: identifier.rawValue), rows.indices.contains(row) else { return nil }
        let item = rows[row]
        switch column {
        case .number: return String(item.number)
        case .fruit: return item.fruit(in: language)
        case .count: return String(item.count)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        databaseColumns == nil ? rows.count : databaseRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isRebuildingColumns else { return }
        sortRows()
        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }

        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = tableColumn.identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()

        if databaseColumns != nil {
            let key = tableColumn.identifier.rawValue
            guard let index = Int(key.dropFirst(Self.databaseColumnPrefix.count)),
                  databaseRows.indices.contains(row),
                  databaseRows[row].values.indices.contains(index) else { return nil }
            let value = databaseRows[row].values[index]
            cell.stringValue = value ?? "NULL"
            cell.textColor = value == nil ? .tertiaryLabelColor : .labelColor
            cell.alignment = .left
            return cell
        }

        guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = rows[row]
        switch column {
        case .number: cell.stringValue = String(item.number)
        case .fruit: cell.stringValue = item.fruit(in: language)
        case .count: cell.stringValue = String(item.count)
        }
        cell.textColor = .labelColor
        cell.alignment = column == .fruit ? .left : .right
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
