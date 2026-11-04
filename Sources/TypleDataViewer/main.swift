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

/// 左側パネルのタブ。選んだテーブルの中身を見るか、列の型を見るか
enum SidebarTab: CaseIterable {
    case data
    case schema

    func title(in language: Language) -> String {
        switch (self, language) {
        case (.data, .japanese): "データ"
        case (.data, .english): "Data"
        case (.schema, .japanese): "スキーマ"
        case (.schema, .english): "Schema"
        }
    }

    /// スキーマを表示するときの列見出し。Database.fetchSchema の列の順に対応する
    static func schemaColumnTitles(in language: Language) -> [String] {
        switch language {
        case .japanese: ["列名", "型", "NOT NULL", "既定値"]
        case .english: ["Column", "Type", "NOT NULL", "Default"]
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
    private var tableView: CopyableTableView!
    /// 左側に縦に並べる DB テーブルの一覧
    private var tableListView: NSTableView!
    private var tableListPlaceholder: NSTextField!
    private var tabControl: NSSegmentedControl!
    private var sidebarTab: SidebarTab = .data
    /// 右の表にいまスキーマを出しているか。言語を切り替えたときに見出しを付け直すのに使う
    private var isShowingSchema = false
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

    // データタブの絞り込み・並べ替え・ページ送り。いずれもサーバー側で行う
    private var filterBar: NSStackView!
    private var filterColumnPopUp: NSPopUpButton!
    private var searchField: NSSearchField!
    private var pagingBar: NSStackView!
    private var rangeLabel: NSTextField!
    private var previousPageButton: NSButton!
    private var nextPageButton: NSButton!
    /// 次に読むときの条件。表示中の結果とは限らない（読み込み中は先に変わる）
    private var dataQuery = TableQuery()
    /// dataQuery がどのテーブルに対するものか。別のテーブルを選んだら条件を初期化する
    private var queryTable: TableName?
    /// いま表に出しているテーブル・ページの先頭行・絞り込み後の総件数
    private var displayedTable: TableName?
    private var displayedOffset = 0
    private var totalRowCount = 0
    /// 読み込みを始めるたびに増やす。追い越された古い結果を捨てるのに使う
    private var loadGeneration = 0

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

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
    private static let tableListColumn = NSUserInterfaceItemIdentifier("tableName")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typle Data Viewer"
        updateMainMenu()

        let languagePopUp = NSPopUpButton()
        languagePopUp.addItems(withTitles: Language.allCases.map(\.displayName))
        languagePopUp.selectItem(at: Language.allCases.firstIndex(of: language) ?? 0)
        languagePopUp.target = self
        languagePopUp.action = #selector(languageDidChange(_:))
        languagePopUp.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "データ")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        connectButton = NSButton(title: "", target: self, action: #selector(connectButtonClicked(_:)))
        connectButton.bezelStyle = .push
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        updateConnectionUI()

        tableView = CopyableTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.copyValue = { [weak self] row, identifier in
            self?.cellValue(row: row, identifier: identifier) ?? nil
        }
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

        // 表の上に絞り込み、下にページ送り。DB のデータを出しているときだけ見せる
        filterColumnPopUp = NSPopUpButton()
        filterColumnPopUp.target = self
        filterColumnPopUp.action = #selector(filterDidChange(_:))
        searchField = NSSearchField()
        searchField.target = self
        searchField.action = #selector(filterDidChange(_:))
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterBar = NSStackView(views: [filterColumnPopUp, searchField])
        filterBar.orientation = .horizontal
        filterBar.spacing = 8
        filterBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        rangeLabel = NSTextField(labelWithString: "")
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.lineBreakMode = .byTruncatingTail
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previousPageButton = NSButton(title: "", target: self, action: #selector(previousPageClicked(_:)))
        nextPageButton = NSButton(title: "", target: self, action: #selector(nextPageClicked(_:)))
        pagingBar = NSStackView()
        pagingBar.orientation = .horizontal
        pagingBar.spacing = 8
        pagingBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        pagingBar.addView(rangeLabel, in: .leading)
        pagingBar.addView(previousPageButton, in: .trailing)
        pagingBar.addView(nextPageButton, in: .trailing)

        let dataPane = NSStackView(views: [filterBar, scrollView, pagingBar])
        dataPane.orientation = .vertical
        dataPane.alignment = .width
        dataPane.spacing = 0
        dataPane.translatesAutoresizingMaskIntoConstraints = false
        updateDataControls()

        tableListView = NSTableView()
        tableListView.style = .sourceList
        tableListView.headerView = nil
        tableListView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableListView.addTableColumn(NSTableColumn(identifier: Self.tableListColumn))
        tableListView.dataSource = self
        tableListView.delegate = self

        let listScrollView = NSScrollView()
        listScrollView.documentView = tableListView
        listScrollView.hasVerticalScroller = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        tableListPlaceholder = NSTextField(wrappingLabelWithString: "")
        tableListPlaceholder.textColor = .secondaryLabelColor
        tableListPlaceholder.alignment = .center
        tableListPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        listScrollView.addSubview(tableListPlaceholder)
        NSLayoutConstraint.activate([
            tableListPlaceholder.centerYAnchor.constraint(equalTo: listScrollView.centerYAnchor),
            tableListPlaceholder.leadingAnchor.constraint(equalTo: listScrollView.leadingAnchor, constant: 12),
            tableListPlaceholder.trailingAnchor.constraint(equalTo: listScrollView.trailingAnchor, constant: -12),
        ])
        updateTableListPlaceholder()

        tabControl = NSSegmentedControl(
            labels: SidebarTab.allCases.map { $0.title(in: language) },
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabDidChange(_:))
        )
        tabControl.selectedSegment = SidebarTab.allCases.firstIndex(of: sidebarTab) ?? 0
        tabControl.segmentDistribution = .fillEqually
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        // 左側パネルは、先頭にタブ、その下にテーブルの一覧
        let sidebar = NSView()
        sidebar.addSubview(tabControl)
        sidebar.addSubview(listScrollView)
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            tabControl.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            tabControl.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            listScrollView.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            listScrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])

        // 左に一覧、右に表。ウインドウを広げたときは表の側が伸びる
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(dataPane)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(titleLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(connectButton)
        contentView.addSubview(languagePopUp)
        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            languagePopUp.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            languagePopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            connectButton.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            connectButton.trailingAnchor.constraint(equalTo: languagePopUp.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),

            splitView.topAnchor.constraint(equalTo: languagePopUp.bottomAnchor, constant: 12),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            dataPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        window.contentView = contentView
        // 区切りの初期位置は、分割ビューの大きさが決まってから設定する
        contentView.layoutSubtreeIfNeeded()
        splitView.setPosition(200, ofDividerAt: 0)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 起動したらすぐ DB に接続する。DATABASE_URL がなければ状態欄にその旨が出る
        connect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 終了処理は待てないので、EventLoopFuture 版で閉じるだけ依頼する
        let _: EventLoopFuture<Void>? = connection?.close()
    }

    // MARK: - Menu

    /// メニューバー。Cmd+W などは最前面のウインドウに送られるので、値のウインドウでもメインでも効く
    private func updateMainMenu() {
        let appName = "Typle Data Viewer"
        let japanese = language == .japanese

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: japanese ? "\(appName) を終了" : "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: japanese ? "ファイル" : "File")
        fileMenu.addItem(
            withTitle: japanese ? "閉じる" : "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu

        // 値のテキストはテキストビューが、表の行は CopyableTableView がそれぞれ受け取る
        let editMenu = NSMenu(title: japanese ? "編集" : "Edit")
        editMenu.addItem(
            withTitle: japanese ? "コピー" : "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: japanese ? "すべてを選択" : "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
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
                updateTableList()
                // 選択が変わると tableViewSelectionDidChange から読み込まれる
                if !tables.isEmpty {
                    tableListView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
        queryTable = nil
        dataQuery = TableQuery()
        searchField.stringValue = ""
        connectionState = .disconnected
        updateTableList()
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

    private func updateTableList() {
        tableListView.reloadData()
        updateTableListPlaceholder()
    }

    private func updateTableListPlaceholder() {
        tableListPlaceholder.isHidden = !tables.isEmpty
        switch (connection == nil, language) {
        case (true, .japanese): tableListPlaceholder.stringValue = "DBに接続するとテーブルが表示されます"
        case (true, .english): tableListPlaceholder.stringValue = "Connect to DB to list tables"
        case (false, .japanese): tableListPlaceholder.stringValue = "テーブルがありません"
        case (false, .english): tableListPlaceholder.stringValue = "No tables"
        }
    }

    /// 一覧で選ばれている DB テーブル
    private var selectedTable: TableName? {
        tables.indices.contains(tableListView.selectedRow) ? tables[tableListView.selectedRow] : nil
    }

    @objc private func tabDidChange(_ sender: NSSegmentedControl) {
        guard SidebarTab.allCases.indices.contains(sender.selectedSegment) else { return }
        sidebarTab = SidebarTab.allCases[sender.selectedSegment]
        if let selectedTable {
            loadTable(selectedTable)
        }
    }

    private func loadTable(_ table: TableName) {
        guard let connection else { return }
        let tab = sidebarTab
        if table != queryTable {
            // 別のテーブルに移ったら、絞り込み・並べ替え・ページを最初に戻す
            queryTable = table
            dataQuery = TableQuery()
            searchField.stringValue = ""
        }
        let query = dataQuery
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            do {
                let data: TableData
                var totalCount = 0
                switch tab {
                case .data:
                    let page = try await Database.fetchTable(table, query: query, on: connection)
                    data = TableData(columns: page.columns, rows: page.rows)
                    totalCount = page.totalCount
                case .schema:
                    data = TableData(
                        columns: SidebarTab.schemaColumnTitles(in: language),
                        rows: try await Database.fetchSchema(table, on: connection)
                    )
                }
                // 読み込み中に別のテーブルやタブ、条件が選ばれていたら、古い結果は捨てる
                guard generation == loadGeneration, self.connection === connection,
                      selectedTable == table, sidebarTab == tab else { return }
                // ページ送りや絞り込みでは列が変わらないので、列幅や並べ替えの表示はそのまま残す
                let columnsChanged = displayedTable != table || isShowingSchema != (tab == .schema)
                    || databaseColumns != data.columns
                isShowingSchema = tab == .schema
                displayedTable = table
                displayedOffset = query.offset
                totalRowCount = totalCount
                databaseColumns = data.columns
                databaseRows = data.rows.enumerated().map { DatabaseRow(order: $0.offset, values: $0.element) }
                if columnsChanged {
                    rebuildColumns()
                }
                tableView.reloadData()
                if !databaseRows.isEmpty {
                    tableView.scrollRowToVisible(0)
                }
                updateDataControls()
            } catch {
                guard generation == loadGeneration else { return }
                let alert = NSAlert()
                alert.messageText = language == .japanese
                    ? "テーブル「\(table.displayName)」を読み込めませんでした"
                    : "Could not load table \"\(table.displayName)\""
                alert.informativeText = String(reflecting: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// 選択中のテーブルを、いまの条件で読み直す
    private func reloadSelectedTable() {
        if let selectedTable {
            loadTable(selectedTable)
        }
    }

    private func showSampleData() {
        isShowingSchema = false
        displayedTable = nil
        databaseColumns = nil
        databaseRows = []
        rebuildColumns()
        tableView.reloadData()
        updateDataControls()
    }

    // MARK: - Filtering and paging

    /// DB のテーブルの中身を出しているか（スキーマやサンプルではなく）
    private var isShowingDatabaseData: Bool {
        databaseColumns != nil && !isShowingSchema
    }

    /// 絞り込み欄・ページ送り欄の表示と文言を、いまの表示内容に合わせる
    private func updateDataControls() {
        let japanese = language == .japanese
        searchField.placeholderString = japanese ? "検索" : "Search"
        previousPageButton.title = japanese ? "前へ" : "Previous"
        nextPageButton.title = japanese ? "次へ" : "Next"

        filterBar.isHidden = !isShowingDatabaseData
        pagingBar.isHidden = !isShowingDatabaseData
        guard isShowingDatabaseData, let databaseColumns else { return }

        // 先頭は「すべての列」。列名は項目の representedObject に持たせる
        filterColumnPopUp.removeAllItems()
        let allItem = NSMenuItem(title: japanese ? "すべての列" : "All columns", action: nil, keyEquivalent: "")
        filterColumnPopUp.menu?.addItem(allItem)
        filterColumnPopUp.menu?.addItem(.separator())
        for name in databaseColumns {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = name
            filterColumnPopUp.menu?.addItem(item)
        }
        let selectedItem = filterColumnPopUp.itemArray.first {
            ($0.representedObject as? String) == dataQuery.filterColumn
        }
        filterColumnPopUp.select(dataQuery.filterColumn == nil ? allItem : selectedItem ?? allItem)

        let shownEnd = displayedOffset + databaseRows.count
        if totalRowCount == 0 || databaseRows.isEmpty {
            rangeLabel.stringValue = japanese ? "0 件" : "0 rows"
        } else {
            let start = Self.formatCount(displayedOffset + 1)
            let end = Self.formatCount(shownEnd)
            let total = Self.formatCount(totalRowCount)
            rangeLabel.stringValue = japanese
                ? "\(start)〜\(end) 件目 / 全 \(total) 件"
                : "\(start)–\(end) of \(total) rows"
        }
        previousPageButton.isEnabled = displayedOffset > 0
        nextPageButton.isEnabled = shownEnd < totalRowCount
    }

    private static func formatCount(_ count: Int) -> String {
        countFormatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    /// 検索語か対象の列が変わったら、先頭のページから読み直す
    @objc private func filterDidChange(_ sender: Any) {
        guard isShowingDatabaseData else { return }
        let column = filterColumnPopUp.selectedItem?.representedObject as? String
        let text = searchField.stringValue
        guard text != dataQuery.filterText || column != dataQuery.filterColumn else { return }
        let needsReload = !(text.isEmpty && dataQuery.filterText.isEmpty)
        dataQuery.filterColumn = column
        dataQuery.filterText = text
        dataQuery.offset = 0
        // 検索語が空のまま列だけ変えても結果は同じなので、読み直さない
        if needsReload {
            reloadSelectedTable()
        }
    }

    @objc private func previousPageClicked(_ sender: Any) {
        guard isShowingDatabaseData, displayedOffset > 0 else { return }
        dataQuery.offset = max(0, displayedOffset - Database.pageSize)
        reloadSelectedTable()
    }

    @objc private func nextPageClicked(_ sender: Any) {
        guard isShowingDatabaseData, displayedOffset + databaseRows.count < totalRowCount else { return }
        dataQuery.offset = displayedOffset + Database.pageSize
        reloadSelectedTable()
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
            // データタブに戻ったときなど、サーバー側でかけている並べ替えを見出しの矢印に反映する
            if !isShowingSchema, let sortColumn = dataQuery.sortColumn,
               let index = databaseColumns.firstIndex(of: sortColumn) {
                let key = Self.databaseColumnPrefix + String(index)
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: dataQuery.ascending)]
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
        updateTableListPlaceholder()
        updateMainMenu()
        for (index, tab) in SidebarTab.allCases.enumerated() {
            tabControl.setLabel(tab.title(in: language), forSegment: index)
        }
        if isShowingSchema {
            updateSchemaColumnTitles()
        }
        updateDataControls()
        if databaseColumns == nil {
            updateColumnTitles()
            // 果物名は言語で並び順が変わるので、現在のソートをかけ直す
            sortRows()
            tableView.reloadData()
        }
    }

    private func updateSchemaColumnTitles() {
        let titles = SidebarTab.schemaColumnTitles(in: language)
        databaseColumns = titles
        for tableColumn in tableView.tableColumns {
            guard let index = Int(tableColumn.identifier.rawValue.dropFirst(Self.databaseColumnPrefix.count)),
                  titles.indices.contains(index) else { continue }
            tableColumn.title = titles[index]
        }
        tableView.headerView?.needsDisplay = true
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

    /// スキーマの表は text で受け取っているので、数字も数値として並ぶ比較を使う。NULL は先頭
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
        if databaseColumns != nil, let selectedTable {
            title = "\(selectedTable.displayName).\(title)"
        }
        // ページ送りしているときは、テーブル全体での行番号にする
        let rowNumber = row + 1 + (isShowingDatabaseData ? displayedOffset : 0)
        title += language == .japanese ? "（\(rowNumber)行目）" : " (row \(rowNumber))"
        ValueWindowController.show(title: title, value: value, language: language)
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
        if tableView === tableListView { return tables.count }
        return databaseColumns == nil ? rows.count : databaseRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === self.tableView, !isRebuildingColumns else { return }
        // DB のデータは読み込み済みの行だけでなくテーブル全体で並べたいので、ORDER BY を付けて読み直す
        if isShowingDatabaseData, let databaseColumns {
            let descriptor = tableView.sortDescriptors.first
            let index = descriptor?.key.flatMap { Int($0.dropFirst(Self.databaseColumnPrefix.count)) }
            dataQuery.sortColumn = index.flatMap { databaseColumns.indices.contains($0) ? databaseColumns[$0] : nil }
            dataQuery.ascending = descriptor?.ascending ?? true
            dataQuery.offset = 0
            reloadSelectedTable()
            return
        }
        sortRows()
        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === tableListView, let selectedTable else { return }
        loadTable(selectedTable)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }

        if tableView === tableListView {
            guard tables.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.tableListColumn, owner: self) as? NSTableCellView
                ?? {
                    let cell = NSTableCellView()
                    cell.identifier = Self.tableListColumn
                    let field = NSTextField(labelWithString: "")
                    field.lineBreakMode = .byTruncatingTail
                    field.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(field)
                    cell.textField = field
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            cell.textField?.stringValue = tables[row].displayName
            return cell
        }

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
