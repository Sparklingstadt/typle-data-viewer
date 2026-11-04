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

/// 左側パネルのタブ。選んだテーブルの中身を見るか、列の型を見るか、SQL を書いて実行するか
enum SidebarTab: CaseIterable {
    case data
    case schema
    case sql

    func title(in language: Language) -> String {
        switch (self, language) {
        case (.data, .japanese): "データ"
        case (.data, .english): "Data"
        case (.schema, .japanese): "スキーマ"
        case (.schema, .english): "Schema"
        case (.sql, _): "SQL"
        }
    }

    /// スキーマを表示するときの列見出し。Database.fetchSchema の列の順に対応する
    static func schemaColumnTitles(in language: Language) -> [String] {
        switch language {
        case .japanese: ["列名", "型", "NOT NULL", "既定値", "キー"]
        case .english: ["Column", "Type", "NOT NULL", "Default", "Keys"]
        }
    }
}

/// 右クリックメニューの「参照先を開く」で開く先。参照先テーブルと、その列の値の一致条件
struct ForeignKeyJump {
    let table: TableName
    let filters: [ColumnFilter]
}

/// テーブルごとに覚えておく列の見た目。列は名前で持つので、列が増減しても残りの列には効く
struct ColumnLayout: Codable {
    var order: [String] = []
    var widths: [String: Double] = [:]
    var hidden: [String] = []
}

/// DB から読んだ1行。ソート後も同値の行を元の順に並べるため、取得時の順番を持つ
struct DatabaseRow {
    let order: Int
    let values: [String?]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation, NSMenuDelegate {
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
    /// 接続先を選ぶメニュー。DATABASE_URL、保存した接続先、追加・編集・削除の項目を並べる
    private var connectionPopUp: NSPopUpButton!
    private var connectionProfiles: [ConnectionProfile] = ConnectionStore.loadProfiles()
    private var selectedTarget: ConnectionTarget = ConnectionStore.selectedTarget
    /// いま接続している接続先。列の見た目を接続先ごとに分けて覚えるのに使う
    private var connectedTarget: ConnectionTarget?
    private var statusLabel: NSTextField!
    private var language: Language = .japanese
    private var connection: PostgresConnection?
    private var connectionState: ConnectionState = .disconnected {
        didSet { updateConnectionUI() }
    }

    /// 接続中は DB のテーブル一覧、未接続時は空
    private var tables: [TableName] = []
    /// 一覧の各項目がテーブルかビューかなど。一覧のアイコンと、ページ送りの並べ方に使う
    private var tableKinds: [TableName: RelationKind] = [:]
    /// 表示中の表で、数値として右寄せにする列の位置
    private var numericColumnIndexes: Set<Int> = []

    private static let cellFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// NULL は斜体の薄い文字にして、空文字（何も表示しない）と見分けられるようにする
    private static let nullFont = NSFontManager.shared.convert(cellFont, toHaveTrait: .italicFontMask)
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

    // 外部キーの参照先へのジャンプ
    /// 表示中のテーブルから出ている外部キー
    private var displayedForeignKeys: [ForeignKey] = []
    /// 次にこのテーブルを読むときに使う条件。ジャンプや「戻る」で、選択の変更より先に入れておく
    private var pendingNavigation: (table: TableName, query: TableQuery)?
    /// ジャンプする前に見ていたテーブルと条件。「戻る」で1つずつ戻る
    private var navigationHistory: [(table: TableName, query: TableQuery)] = []
    /// 一致条件で絞り込んでいるときに絞り込み欄に出す、条件と解除ボタン
    private var equalityFilterLabel: NSTextField!
    private var clearEqualityFilterButton: NSButton!

    // スキーマタブで表の上に出す、推定行数・大きさ・インデックス
    private var schemaInfoBar: NSStackView!
    private var schemaSummaryLabel: NSTextField!
    private var schemaIndexesLabel: NSTextField!
    /// 表示中のスキーマ。言語を切り替えたときに文言を作り直すのに使う
    private var displayedSchema: TableSchema?

    // SQL タブ。表の上に SQL の入力欄と実行ボタンを出し、結果を同じ表に出す
    private var sqlBar: NSStackView!
    private var sqlTextView: NSTextView!
    private var runQueryButton: NSButton!
    private var queryStatusLabel: NSTextField!
    /// 表にいま SQL の実行結果を出しているか
    private var isShowingQueryResult = false
    private var isRunningQuery = false
    /// 最後に成功した実行結果と、かかった秒数。SQL タブに戻ったときにまた出す
    private var lastQueryResult: QueryResult?
    private var lastQueryDuration: TimeInterval = 0
    /// 実行するたびに増やす。追い越された古い結果を捨てるのに使う
    private var queryGeneration = 0

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

        connectionPopUp = NSPopUpButton()
        connectionPopUp.target = self
        connectionPopUp.action = #selector(connectionPopUpDidChange(_:))
        connectionPopUp.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        connectionPopUp.translatesAutoresizingMaskIntoConstraints = false
        rebuildConnectionMenu()

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
        // 右クリックしたセルに合わせて、開くときに中身を作る
        let cellMenu = NSMenu()
        cellMenu.autoenablesItems = false
        cellMenu.delegate = self
        tableView.menu = cellMenu
        // 見出しを右クリックすると、列の表示・非表示を切り替えられる
        let headerMenu = NSMenu()
        headerMenu.autoenablesItems = false
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
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
        equalityFilterLabel = NSTextField(labelWithString: "")
        equalityFilterLabel.lineBreakMode = .byTruncatingMiddle
        equalityFilterLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearEqualityFilterButton = NSButton(title: "", target: self, action: #selector(clearEqualityFilterClicked(_:)))
        clearEqualityFilterButton.bezelStyle = .inline
        filterBar = NSStackView(views: [filterColumnPopUp, searchField, equalityFilterLabel, clearEqualityFilterButton])
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

        let sqlScrollView = NSTextView.scrollableTextView()
        sqlScrollView.borderType = .bezelBorder
        sqlScrollView.translatesAutoresizingMaskIntoConstraints = false
        sqlScrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        sqlTextView = sqlScrollView.documentView as? NSTextView
        sqlTextView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        sqlTextView.isRichText = false
        sqlTextView.allowsUndo = true
        // SQL の引用符やハイフンが勝手に置き換わらないようにする
        sqlTextView.isAutomaticQuoteSubstitutionEnabled = false
        sqlTextView.isAutomaticDashSubstitutionEnabled = false
        sqlTextView.isAutomaticTextReplacementEnabled = false
        sqlTextView.isAutomaticSpellingCorrectionEnabled = false
        sqlTextView.isContinuousSpellCheckingEnabled = false

        queryStatusLabel = NSTextField(labelWithString: "")
        queryStatusLabel.textColor = .secondaryLabelColor
        queryStatusLabel.lineBreakMode = .byTruncatingTail
        queryStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 入力欄にフォーカスがあっても Cmd+Return で実行できる
        runQueryButton = NSButton(title: "", target: self, action: #selector(runQueryClicked(_:)))
        runQueryButton.keyEquivalent = "\r"
        runQueryButton.keyEquivalentModifierMask = .command
        let queryControls = NSStackView()
        queryControls.orientation = .horizontal
        queryControls.spacing = 8
        queryControls.addView(queryStatusLabel, in: .leading)
        queryControls.addView(runQueryButton, in: .trailing)

        sqlBar = NSStackView(views: [sqlScrollView, queryControls])
        sqlBar.orientation = .vertical
        sqlBar.alignment = .width
        sqlBar.spacing = 6
        sqlBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        schemaSummaryLabel = NSTextField(labelWithString: "")
        schemaSummaryLabel.lineBreakMode = .byTruncatingTail
        schemaSummaryLabel.isSelectable = true
        schemaSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // インデックスは1行に1つ。多いときは数行で切り、全部はツールチップで見られる
        schemaIndexesLabel = NSTextField(wrappingLabelWithString: "")
        schemaIndexesLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        schemaIndexesLabel.textColor = .secondaryLabelColor
        schemaIndexesLabel.maximumNumberOfLines = 6
        schemaIndexesLabel.lineBreakMode = .byTruncatingTail
        schemaIndexesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        schemaInfoBar = NSStackView(views: [schemaSummaryLabel, schemaIndexesLabel])
        schemaInfoBar.orientation = .vertical
        schemaInfoBar.alignment = .leading
        schemaInfoBar.spacing = 4
        schemaInfoBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let dataPane = NSStackView(views: [filterBar, sqlBar, schemaInfoBar, scrollView, pagingBar])
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
        contentView.addSubview(connectionPopUp)
        contentView.addSubview(languagePopUp)
        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            languagePopUp.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            languagePopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            connectButton.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            connectButton.trailingAnchor.constraint(equalTo: languagePopUp.leadingAnchor, constant: -8),

            connectionPopUp.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            connectionPopUp.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            connectionPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            statusLabel.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: connectionPopUp.leadingAnchor, constant: -8),
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
        let exportItem = fileMenu.addItem(
            withTitle: japanese ? "書き出す…" : "Export…",
            action: #selector(exportMenuItemSelected(_:)),
            keyEquivalent: "e"
        )
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        fileMenu.addItem(.separator())
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
        // 選択した行（選択がなければ全行）を、見出しの行を付けた TSV でコピーする
        let copyWithHeadersItem = editMenu.addItem(
            withTitle: japanese ? "見出し付きでコピー" : "Copy with Headers",
            action: #selector(copyWithHeadersMenuItemSelected(_:)),
            keyEquivalent: "c"
        )
        copyWithHeadersItem.keyEquivalentModifierMask = [.command, .option]
        copyWithHeadersItem.target = self
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        // 値のウインドウが前面にあっても、メインの表を読み直す
        let viewMenu = NSMenu(title: japanese ? "表示" : "View")
        let reloadItem = viewMenu.addItem(
            withTitle: japanese ? "再読み込み" : "Reload",
            action: #selector(reloadMenuItemSelected(_:)),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        let backItem = viewMenu.addItem(
            withTitle: japanese ? "戻る" : "Back",
            action: #selector(backMenuItemSelected(_:)),
            keyEquivalent: "["
        )
        backItem.target = self
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)
        mainMenu.addItem(editMenuItem)
        mainMenu.addItem(viewMenuItem)
        NSApp.mainMenu = mainMenu
    }

    /// 接続し直さずに、選択中のテーブルをいまの条件（絞り込み・並べ替え・ページ・タブ）のまま読み直す
    @objc private func reloadMenuItemSelected(_ sender: Any?) {
        // SQL タブでは、書いてある SQL を実行し直す
        if sidebarTab == .sql {
            runQuery()
            return
        }
        guard let selectedTable else { return }
        loadTable(selectedTable, keepsScrollPosition: true)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportMenuItemSelected(_:))
            || menuItem.action == #selector(copyWithHeadersMenuItemSelected(_:)) {
            return !tableView.tableColumns.isEmpty
        }
        if menuItem.action == #selector(reloadMenuItemSelected(_:)) {
            return connection != nil && (sidebarTab == .sql || selectedTable != nil)
        }
        if menuItem.action == #selector(backMenuItemSelected(_:)) {
            return connection != nil && !navigationHistory.isEmpty
        }
        return true
    }

    // MARK: - Export

    /// 書き出しの保存パネルで選んでいる形式。パネルの形式メニューから変える
    private var exportFormat: ExportFormat = .csv
    private weak var exportPanel: NSSavePanel?

    /// 表に出している内容を、見えている列の順・並べ替えた順のまま取り出す。
    /// - Parameter rowIndexes: 取り出す行。nil なら全行
    private func displayedContent(rowIndexes: IndexSet? = nil) -> (columns: [String], rows: [[String?]]) {
        // 隠した列は書き出さない
        let tableColumns = tableView.tableColumns.filter { !$0.isHidden }
        let indexes = rowIndexes ?? IndexSet(integersIn: 0..<tableView.numberOfRows)
        let rows = indexes.map { row in
            tableColumns.map { column -> String? in
                // 外側の nil（該当するセルがない）は空、内側の nil は DB の NULL
                guard let value = cellValue(row: row, identifier: column.identifier) else { return "" }
                return value
            }
        }
        return (tableColumns.map(\.title), rows)
    }

    /// ファイル名の初期値。表示中のテーブル名、SQL の結果なら query
    private var exportFileName: String {
        let base: String
        if isShowingQueryResult {
            base = "query"
        } else if databaseColumns != nil, let selectedTable {
            base = isShowingSchema ? "\(selectedTable.displayName)_schema" : selectedTable.displayName
        } else {
            base = "data"
        }
        return base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    /// 表に出している行（データタブではいま表示中のページ）を CSV・TSV・JSON で保存する
    @objc private func exportMenuItemSelected(_ sender: Any?) {
        let content = displayedContent()
        let japanese = language == .japanese

        let panel = NSSavePanel()
        panel.title = japanese ? "書き出す" : "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // 保存パネルの下に形式のメニューを付ける
        let formatPopUp = NSPopUpButton()
        formatPopUp.addItems(withTitles: ExportFormat.allCases.map(\.title))
        formatPopUp.selectItem(at: ExportFormat.allCases.firstIndex(of: exportFormat) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(exportFormatDidChange(_:))
        let formatLabel = NSTextField(labelWithString: japanese ? "形式:" : "Format:")
        let accessory = NSStackView(views: [formatLabel, formatPopUp])
        accessory.orientation = .horizontal
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory

        panel.allowedContentTypes = [exportFormat.contentType]
        panel.nameFieldStringValue = "\(exportFileName).\(exportFormat.fileExtension)"
        exportPanel = panel

        Task {
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            let data = TableExporter.data(columns: content.columns, rows: content.rows, format: exportFormat)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = japanese ? "書き出せませんでした" : "Could not export"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// 形式を変えたら、保存できる種類とファイル名の拡張子も合わせる
    @objc private func exportFormatDidChange(_ sender: NSPopUpButton) {
        guard ExportFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        exportFormat = ExportFormat.allCases[sender.indexOfSelectedItem]
        guard let exportPanel else { return }
        exportPanel.allowedContentTypes = [exportFormat.contentType]
        let name = (exportPanel.nameFieldStringValue as NSString).deletingPathExtension
        exportPanel.nameFieldStringValue = "\(name).\(exportFormat.fileExtension)"
    }

    @objc private func copyWithHeadersMenuItemSelected(_ sender: Any?) {
        let selection = tableView.selectedRowIndexes
        let content = displayedContent(rowIndexes: selection.isEmpty ? nil : selection)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TableExporter.string(columns: content.columns, rows: content.rows, format: .tsv),
            forType: .string
        )
    }

    // MARK: - Connection profiles

    /// 接続先メニューの項目を作り直す。representedObject に "target:…" か "action:…" を持たせる
    private func rebuildConnectionMenu() {
        let japanese = language == .japanese
        connectionPopUp.removeAllItems()
        guard let menu = connectionPopUp.menu else { return }

        let hasEnvironmentURL = Database.connectionURL() != nil
        let environmentItem = NSMenuItem(
            title: hasEnvironmentURL ? "DATABASE_URL" : (japanese ? "DATABASE_URL（未設定）" : "DATABASE_URL (not set)"),
            action: nil,
            keyEquivalent: ""
        )
        environmentItem.representedObject = "target:" + ConnectionTarget.environment.key
        menu.addItem(environmentItem)
        for profile in connectionProfiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = "target:" + ConnectionTarget.profile(profile.id).key
            item.toolTip = profile.url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let actions: [(String, String)] = [
            ("add", japanese ? "接続先を追加…" : "Add Connection…"),
            ("edit", japanese ? "選択中の接続先を編集…" : "Edit Selected Connection…"),
            ("delete", japanese ? "選択中の接続先を削除…" : "Delete Selected Connection…"),
        ]
        for (action, title) in actions {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = "action:" + action
            // DATABASE_URL は編集・削除できない
            if action != "add", selectedTarget == .environment {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        selectConnectionMenuItem()
    }

    /// メニューの表示を、選択中の接続先に合わせる
    private func selectConnectionMenuItem() {
        let key = "target:" + selectedTarget.key
        if let item = connectionPopUp.itemArray.first(where: { ($0.representedObject as? String) == key }) {
            connectionPopUp.select(item)
        } else {
            selectedTarget = .environment
            ConnectionStore.selectedTarget = .environment
            connectionPopUp.selectItem(at: 0)
        }
    }

    @objc private func connectionPopUpDidChange(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        if value.hasPrefix("action:") {
            // 操作の項目は選んだままにしない
            selectConnectionMenuItem()
            switch value.dropFirst("action:".count) {
            case "add": editConnectionProfile(nil)
            case "edit":
                if case .profile(let id) = selectedTarget, let profile = connectionProfiles.first(where: { $0.id == id }) {
                    editConnectionProfile(profile)
                }
            case "delete": deleteSelectedConnectionProfile()
            default: break
            }
            return
        }
        let target = ConnectionTarget(key: String(value.dropFirst("target:".count)))
        guard target != selectedTarget else { return }
        switchConnection(to: target)
    }

    /// 接続先を切り替える。接続中なら切断して、新しい接続先につなぎ直す
    private func switchConnection(to target: ConnectionTarget) {
        selectedTarget = target
        ConnectionStore.selectedTarget = target
        rebuildConnectionMenu()
        disconnect()
        connect()
    }

    /// 接続先を追加（profile が nil）または編集するシート。パスワードは Keychain に保存する
    private func editConnectionProfile(_ profile: ConnectionProfile?) {
        let japanese = language == .japanese
        let nameField = NSTextField(string: profile?.name ?? "")
        nameField.placeholderString = japanese ? "本番 DB など" : "e.g. Production"
        let urlField = NSTextField(string: profile?.url ?? "")
        urlField.placeholderString = "postgresql://user@host/db?sslmode=require"
        let passwordField = NSSecureTextField(string: profile.flatMap { Keychain.password(for: $0.id.uuidString) } ?? "")
        passwordField.placeholderString = japanese ? "URL に含めてもかまいません" : "Can also be included in the URL"
        for field in [nameField, urlField, passwordField] {
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: japanese ? "名前:" : "Name:"), nameField],
            [NSTextField(labelWithString: japanese ? "接続 URL:" : "URL:"), urlField],
            [NSTextField(labelWithString: japanese ? "パスワード:" : "Password:"), passwordField],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = profile == nil
            ? (japanese ? "接続先を追加" : "Add Connection")
            : (japanese ? "接続先を編集" : "Edit Connection")
        alert.informativeText = japanese
            ? "パスワードはキーチェーンに保存され、設定ファイルには書かれません。"
            : "The password is stored in the Keychain, not in the settings file."
        alert.accessoryView = grid
        alert.addButton(withTitle: japanese ? "保存" : "Save")
        alert.addButton(withTitle: japanese ? "キャンセル" : "Cancel")
        alert.window.initialFirstResponder = profile == nil ? nameField : urlField

        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            guard let split = ConnectionStore.splitPassword(from: urlField.stringValue) else {
                let error = NSAlert()
                error.messageText = japanese ? "接続 URL の形式が正しくありません" : "The URL is malformed"
                error.informativeText = "postgresql://user:password@host:5432/db?sslmode=require"
                _ = await error.beginSheetModal(for: window)
                return
            }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let saved = ConnectionProfile(
                id: profile?.id ?? UUID(),
                name: name.isEmpty ? (URLComponents(string: split.url)?.host ?? split.url) : name,
                url: split.url
            )
            // URL にパスワードが書かれていればそちらを優先する
            Keychain.setPassword(split.password ?? passwordField.stringValue, for: saved.id.uuidString)
            if let index = connectionProfiles.firstIndex(where: { $0.id == saved.id }) {
                connectionProfiles[index] = saved
            } else {
                connectionProfiles.append(saved)
            }
            ConnectionStore.saveProfiles(connectionProfiles)
            // 追加・編集した接続先につなぎ直す
            switchConnection(to: .profile(saved.id))
        }
    }

    private func deleteSelectedConnectionProfile() {
        guard case .profile(let id) = selectedTarget,
              let profile = connectionProfiles.first(where: { $0.id == id }) else { return }
        let japanese = language == .japanese
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = japanese ? "接続先「\(profile.name)」を削除しますか？" : "Delete the connection \"\(profile.name)\"?"
        alert.informativeText = japanese
            ? "キーチェーンに保存したパスワードも削除されます。DB のデータは変わりません。"
            : "Its password is also removed from the Keychain. No data in the database is changed."
        alert.addButton(withTitle: japanese ? "削除" : "Delete")
        alert.addButton(withTitle: japanese ? "キャンセル" : "Cancel")
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            connectionProfiles.removeAll { $0.id == id }
            ConnectionStore.saveProfiles(connectionProfiles)
            Keychain.deletePassword(for: id.uuidString)
            switchConnection(to: .environment)
        }
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
        let target = selectedTarget
        // 保存した接続先は URL とパスワード（Keychain）、DATABASE_URL は環境変数か .env から読む
        var urlString: String?
        var password: String?
        if case .profile(let id) = target {
            guard let profile = connectionProfiles.first(where: { $0.id == id }) else {
                connectionState = .failed(DatabaseError.missingURL)
                return
            }
            urlString = profile.url
            password = Keychain.password(for: id.uuidString)
        }
        connectionState = .connecting
        connectionPopUp.isEnabled = false
        Task {
            defer { connectionPopUp.isEnabled = true }
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
                connectedTarget = target
                connectionState = .connected(serverVersion: version)
                updateTableList()
                updateDataControls()
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
        tableKinds = [:]
        queryTable = nil
        dataQuery = TableQuery()
        searchField.stringValue = ""
        lastQueryResult = nil
        pendingNavigation = nil
        navigationHistory = []
        displayedForeignKeys = []
        connectedTarget = nil
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
        if sidebarTab == .sql {
            if let selectedTable {
                prefillQueryIfEmpty(for: selectedTable)
            }
            showQueryResult()
            window.makeFirstResponder(sqlTextView)
            return
        }
        if let selectedTable {
            loadTable(selectedTable)
        } else if isShowingQueryResult {
            showSampleData()
        }
        updateDataControls()
    }

    /// - Parameter keepsScrollPosition: 再読み込みのとき、同じテーブル・ページならスクロール位置を保つ
    private func loadTable(_ table: TableName, keepsScrollPosition: Bool = false) {
        guard let connection else { return }
        let tab = sidebarTab
        // SQL タブではテーブルを読まない。入力欄が空なら、そのテーブルを見る SELECT を入れておく
        if tab == .sql {
            prefillQueryIfEmpty(for: table)
            return
        }
        if let pendingNavigation, pendingNavigation.table == table {
            // ジャンプや「戻る」で開いたときは、用意しておいた条件で読む
            self.pendingNavigation = nil
            queryTable = table
            dataQuery = pendingNavigation.query
            searchField.stringValue = pendingNavigation.query.filterText
        } else if table != queryTable {
            // 別のテーブルに移ったら、絞り込み・並べ替え・ページを最初に戻す
            pendingNavigation = nil
            queryTable = table
            dataQuery = TableQuery()
            searchField.stringValue = ""
        }
        let query = dataQuery
        let kind = tableKinds[table] ?? .table
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            do {
                let data: TableData
                var totalCount = 0
                var schema: TableSchema?
                var foreignKeys: [ForeignKey] = []
                var numericColumns: Set<Int> = []
                switch tab {
                case .data:
                    let page = try await Database.fetchTable(table, kind: kind, query: query, on: connection)
                    data = TableData(columns: page.columns, rows: page.rows)
                    totalCount = page.totalCount
                    foreignKeys = page.foreignKeys
                    numericColumns = page.numericColumns
                case .schema:
                    let fetched = try await Database.fetchSchema(table, on: connection)
                    schema = fetched
                    data = TableData(columns: SidebarTab.schemaColumnTitles(in: language), rows: fetched.columns)
                case .sql:
                    return
                }
                // 読み込み中に別のテーブルやタブ、条件が選ばれていたら、古い結果は捨てる
                guard generation == loadGeneration, self.connection === connection,
                      selectedTable == table, sidebarTab == tab else { return }
                // 再読み込みで行が減り、いまのページが範囲外になったら最後のページを読み直す
                if tab == .data, data.rows.isEmpty, query.offset > 0, totalCount > 0 {
                    dataQuery.offset = (totalCount - 1) / Database.pageSize * Database.pageSize
                    loadTable(table)
                    return
                }
                let keepsScroll = keepsScrollPosition && displayedTable == table
                    && isShowingSchema == (tab == .schema) && displayedOffset == query.offset
                let scrollOrigin = tableView.enclosingScrollView?.documentVisibleRect.origin
                // ページ送りや絞り込みでは列が変わらないので、列幅や並べ替えの表示はそのまま残す
                let columnsChanged = displayedTable != table || isShowingSchema != (tab == .schema)
                    || isShowingQueryResult || databaseColumns != data.columns
                isShowingSchema = tab == .schema
                isShowingQueryResult = false
                displayedSchema = schema
                displayedTable = table
                displayedOffset = query.offset
                totalRowCount = totalCount
                displayedForeignKeys = foreignKeys
                numericColumnIndexes = numericColumns
                databaseColumns = data.columns
                databaseRows = data.rows.enumerated().map { DatabaseRow(order: $0.offset, values: $0.element) }
                if columnsChanged {
                    rebuildColumns()
                } else if isShowingSchema {
                    // スキーマは手元で並べているので、見出しの並べ替えを読み直した行にもかけ直す
                    sortRows()
                }
                tableView.reloadData()
                if keepsScroll, let scrollOrigin {
                    tableView.scroll(scrollOrigin)
                } else if !databaseRows.isEmpty {
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
        displayedSchema = nil
        isShowingQueryResult = false
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
        databaseColumns != nil && !isShowingSchema && !isShowingQueryResult
    }

    /// 絞り込み欄・ページ送り欄の表示と文言を、いまの表示内容に合わせる
    private func updateDataControls() {
        let japanese = language == .japanese
        searchField.placeholderString = japanese ? "検索" : "Search"
        previousPageButton.title = japanese ? "前へ" : "Previous"
        nextPageButton.title = japanese ? "次へ" : "Next"
        runQueryButton.title = japanese ? "実行" : "Run"
        runQueryButton.toolTip = "⌘↩"
        runQueryButton.isEnabled = connection != nil && !isRunningQuery
        sqlBar.isHidden = sidebarTab != .sql
        updateQueryStatusLabel()
        updateSchemaInfo()

        filterBar.isHidden = !isShowingDatabaseData
        pagingBar.isHidden = !isShowingDatabaseData
        let equalityFilters = dataQuery.equalityFilters
        equalityFilterLabel.isHidden = equalityFilters.isEmpty
        clearEqualityFilterButton.isHidden = equalityFilters.isEmpty
        let conditions = equalityFilters.map { "\($0.column) = \($0.value)" }.joined(separator: ", ")
        equalityFilterLabel.stringValue = (japanese ? "参照で絞り込み: " : "Referenced: ") + conditions
        equalityFilterLabel.toolTip = conditions
        clearEqualityFilterButton.title = japanese ? "解除" : "Clear"
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

    /// スキーマタブの上の欄。推定行数と大きさ、その下にインデックスの定義を並べる
    private func updateSchemaInfo() {
        guard isShowingSchema, let displayedSchema else {
            schemaInfoBar.isHidden = true
            return
        }
        schemaInfoBar.isHidden = false
        let japanese = language == .japanese
        let rowCount = displayedSchema.estimatedRowCount.map(Self.formatCount)
        let rowsText = japanese
            ? "推定 \(rowCount ?? "不明") 行"
            : "About \(rowCount ?? "unknown") rows"
        let sizeText = japanese
            ? "データ \(displayedSchema.tableSize) · インデックス等を含め \(displayedSchema.totalSize)"
            : "Data \(displayedSchema.tableSize) · \(displayedSchema.totalSize) including indexes"
        schemaSummaryLabel.stringValue = "\(rowsText) · \(sizeText)"

        let indexes = displayedSchema.indexes
        let indexesText = indexes.isEmpty
            ? (japanese ? "インデックスなし" : "No indexes")
            : indexes.joined(separator: "\n")
        schemaIndexesLabel.stringValue = indexesText
        schemaIndexesLabel.toolTip = indexes.isEmpty ? nil : indexesText
    }

    // MARK: - Foreign keys

    /// 右クリックしたセルに合わせたメニュー。「値を開く」と、その列を含む外部キーごとの「参照先を開く」
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.headerView?.menu {
            updateHeaderMenu(menu)
            return
        }
        guard menu === tableView.menu else { return }
        menu.removeAllItems()
        let row = tableView.clickedRow
        let columnIndex = tableView.clickedColumn
        guard row >= 0, tableView.tableColumns.indices.contains(columnIndex) else { return }
        let japanese = language == .japanese

        let openItem = NSMenuItem(
            title: japanese ? "値を開く" : "Open Value",
            action: #selector(openClickedValueMenuItemSelected(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let identifier = tableView.tableColumns[columnIndex].identifier
        guard isShowingDatabaseData, let databaseColumns,
              let index = Int(identifier.rawValue.dropFirst(Self.databaseColumnPrefix.count)),
              databaseColumns.indices.contains(index), databaseRows.indices.contains(row) else { return }
        let values = databaseRows[row].values
        let columnName = databaseColumns[index]

        let foreignKeys = displayedForeignKeys.filter { $0.columns.contains(columnName) }
        if !foreignKeys.isEmpty {
            menu.addItem(.separator())
        }
        for foreignKey in foreignKeys {
            // 複合キーなら、キーのすべての列の値で絞り込む
            let keyValues = foreignKey.columns.map { name -> String? in
                databaseColumns.firstIndex(of: name).flatMap { values.indices.contains($0) ? values[$0] : nil }
            }
            let conditions = zip(foreignKey.referencedColumns, keyValues)
                .map { "\($0) = \($1 ?? "NULL")" }
                .joined(separator: ", ")
            let target = foreignKey.referencedTable
            let item = NSMenuItem(
                title: japanese
                    ? "参照先を開く: \(target.displayName)（\(conditions)）"
                    : "Open Referenced Row: \(target.displayName) (\(conditions))",
                action: #selector(followForeignKeyMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            // NULL の外部キーは何も参照していない。一覧にないテーブルも開けない
            let nonNullValues = keyValues.compactMap { $0 }
            item.isEnabled = nonNullValues.count == keyValues.count && tables.contains(target)
            item.representedObject = ForeignKeyJump(
                table: target,
                filters: zip(foreignKey.referencedColumns, nonNullValues).map { ColumnFilter(column: $0, value: $1) }
            )
            menu.addItem(item)
        }
    }

    @objc private func openClickedValueMenuItemSelected(_ sender: NSMenuItem) {
        tableViewDoubleClicked(tableView)
    }

    @objc private func followForeignKeyMenuItemSelected(_ sender: NSMenuItem) {
        guard let jump = sender.representedObject as? ForeignKeyJump else { return }
        // いま見ている場所を「戻る」の行き先として覚えておく
        if isShowingDatabaseData, let displayedTable {
            var current = dataQuery
            current.offset = displayedOffset
            navigationHistory.append((displayedTable, current))
        }
        var query = TableQuery()
        query.equalityFilters = jump.filters
        navigate(to: jump.table, query: query)
    }

    @objc private func backMenuItemSelected(_ sender: Any?) {
        guard let previous = navigationHistory.popLast() else { return }
        navigate(to: previous.table, query: previous.query)
    }

    @objc private func clearEqualityFilterClicked(_ sender: Any?) {
        guard isShowingDatabaseData, !dataQuery.equalityFilters.isEmpty else { return }
        dataQuery.equalityFilters = []
        dataQuery.offset = 0
        reloadSelectedTable()
    }

    /// テーブルを選び直し、指定した条件でデータタブに出す
    private func navigate(to table: TableName, query: TableQuery) {
        guard let index = tables.firstIndex(of: table) else { return }
        if sidebarTab != .data {
            sidebarTab = .data
            tabControl.selectedSegment = SidebarTab.allCases.firstIndex(of: .data) ?? 0
        }
        pendingNavigation = (table, query)
        // 並べ替えの矢印を条件に合わせ直すため、同じテーブルでも列を作り直させる
        displayedTable = nil
        if tableListView.selectedRow == index {
            // 選択が変わらないと読み込みが始まらないので、自分で読む
            loadTable(table)
        } else {
            // 選択が変わると tableViewSelectionDidChange から読み込まれる
            tableListView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        tableListView.scrollRowToVisible(index)
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

    // MARK: - SQL query

    @objc private func runQueryClicked(_ sender: Any?) {
        runQuery()
    }

    /// 入力欄の SQL を読み取り専用で実行し、結果を表に出す
    private func runQuery() {
        guard let connection, sidebarTab == .sql, !isRunningQuery else { return }
        let sql = sqlTextView.string
        queryGeneration += 1
        let generation = queryGeneration
        isRunningQuery = true
        updateDataControls()
        let start = Date()
        Task {
            do {
                let result = try await Database.runReadOnlyQuery(sql, on: connection)
                guard generation == queryGeneration else { return }
                isRunningQuery = false
                // 実行中に切断していたら結果は捨てる
                guard self.connection === connection else {
                    updateDataControls()
                    return
                }
                lastQueryResult = result
                lastQueryDuration = Date().timeIntervalSince(start)
                // 別のタブに移っていたら、SQL タブに戻ったときに出す
                if sidebarTab == .sql {
                    showQueryResult()
                } else {
                    updateDataControls()
                }
            } catch {
                guard generation == queryGeneration else { return }
                isRunningQuery = false
                updateDataControls()
                let alert = NSAlert()
                alert.messageText = language == .japanese ? "SQL を実行できませんでした" : "Could not run the SQL"
                alert.informativeText = queryErrorText(error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// 最後の実行結果を表に出す。まだ実行していなければ空の表にする
    private func showQueryResult() {
        isShowingSchema = false
        isShowingQueryResult = true
        displayedTable = nil
        databaseColumns = lastQueryResult?.columns ?? []
        numericColumnIndexes = lastQueryResult?.numericColumns ?? []
        databaseRows = (lastQueryResult?.rows ?? []).enumerated().map {
            DatabaseRow(order: $0.offset, values: $0.element)
        }
        rebuildColumns()
        tableView.reloadData()
        updateDataControls()
    }

    /// SQL の入力欄が空なら、選んだテーブルを見る SELECT を入れる。書きかけの SQL は消さない
    private func prefillQueryIfEmpty(for table: TableName) {
        guard sqlTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sqlTextView.string = "SELECT * FROM \(table.sqlName) LIMIT 100;"
    }

    private func updateQueryStatusLabel() {
        let japanese = language == .japanese
        if connection == nil {
            queryStatusLabel.stringValue = japanese ? "DBに接続すると実行できます" : "Connect to DB to run SQL"
        } else if isRunningQuery {
            queryStatusLabel.stringValue = japanese ? "実行中…" : "Running…"
        } else if let lastQueryResult {
            let count = Self.formatCount(lastQueryResult.rows.count)
            let seconds = String(format: "%.2f", lastQueryDuration)
            switch (lastQueryResult.isTruncated, japanese) {
            case (false, true): queryStatusLabel.stringValue = "\(count) 行（\(seconds) 秒）"
            case (false, false): queryStatusLabel.stringValue = "\(count) rows (\(seconds) s)"
            case (true, true): queryStatusLabel.stringValue = "先頭の \(count) 行を表示（\(seconds) 秒）"
            case (true, false): queryStatusLabel.stringValue = "Showing the first \(count) rows (\(seconds) s)"
            }
        } else {
            queryStatusLabel.stringValue = japanese
                ? "SELECT・WITH・VALUES・TABLE・EXPLAIN・SHOW を読み取り専用で実行します（⌘↩）"
                : "Runs SELECT, WITH, VALUES, TABLE, EXPLAIN, and SHOW read-only (⌘↩)"
        }
    }

    /// エラーの説明。サーバーのエラーなら、メッセージ・詳細・ヒントだけを見せる
    private func queryErrorText(_ error: Error) -> String {
        if case DatabaseError.unsupportedStatement = error {
            return language == .japanese
                ? "読み取り専用のため、SELECT・WITH・VALUES・TABLE・EXPLAIN・SHOW で始まる文だけを実行できます。"
                : "Only statements starting with SELECT, WITH, VALUES, TABLE, EXPLAIN, or SHOW can be run (read-only)."
        }
        if let serverInfo = (error as? PSQLError)?.serverInfo, let message = serverInfo[.message] {
            return [message, serverInfo[.detail], serverInfo[.hint]].compactMap { $0 }.joined(separator: "\n")
        }
        return String(reflecting: error)
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
            // データタブでは、このテーブルで前に変えた列の並び・幅・表示を戻す
            if isShowingDatabaseData, let displayedTable, let layout = loadColumnLayout(for: displayedTable) {
                apply(layout, columnNames: databaseColumns)
            }
            // データタブに戻ったときなど、サーバー側でかけている並べ替えを見出しの矢印に反映する
            if !isShowingSchema, !isShowingQueryResult, let sortColumn = dataQuery.sortColumn,
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

    // MARK: - Column layout

    /// 列の識別子（db.0 など）に対応する DB の列名
    private func databaseColumnName(for identifier: NSUserInterfaceItemIdentifier) -> String? {
        guard let databaseColumns,
              let index = Int(identifier.rawValue.dropFirst(Self.databaseColumnPrefix.count)),
              databaseColumns.indices.contains(index) else { return nil }
        return databaseColumns[index]
    }

    /// 同じ名前のテーブルでも接続先が違えば別のものなので、接続先ごとに分けて覚える
    private func columnLayoutKey(for table: TableName) -> String {
        "columnLayout.\((connectedTarget ?? selectedTarget).key).\(table.schema).\(table.name)"
    }

    private func loadColumnLayout(for table: TableName) -> ColumnLayout? {
        guard let data = UserDefaults.standard.data(forKey: columnLayoutKey(for: table)) else { return nil }
        return try? JSONDecoder().decode(ColumnLayout.self, from: data)
    }

    /// いまの列の並び・幅・表示を、表示中のテーブルの分として保存する。データタブのときだけ
    private func saveColumnLayout() {
        guard !isRebuildingColumns, isShowingDatabaseData, let displayedTable else { return }
        var layout = ColumnLayout()
        for tableColumn in tableView.tableColumns {
            guard let name = databaseColumnName(for: tableColumn.identifier) else { continue }
            layout.order.append(name)
            layout.widths[name] = Double(tableColumn.width)
            if tableColumn.isHidden {
                layout.hidden.append(name)
            }
        }
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: columnLayoutKey(for: displayedTable))
    }

    /// 保存してあった並び・幅・表示を、作ったばかりの列に当てる。rebuildColumns の中から呼ぶ
    private func apply(_ layout: ColumnLayout, columnNames: [String]) {
        // 保存した順に並べ、保存後に増えた列は元の順で後ろに続ける
        let savedOrder = layout.order.filter { columnNames.contains($0) }
        let desiredOrder = savedOrder + columnNames.filter { !savedOrder.contains($0) }
        for (target, name) in desiredOrder.enumerated() {
            guard let current = tableView.tableColumns.firstIndex(where: {
                databaseColumnName(for: $0.identifier) == name
            }), current != target else { continue }
            tableView.moveColumn(current, toColumn: target)
        }
        for tableColumn in tableView.tableColumns {
            guard let name = databaseColumnName(for: tableColumn.identifier) else { continue }
            if let width = layout.widths[name] {
                tableColumn.width = CGFloat(width)
            }
            tableColumn.isHidden = layout.hidden.contains(name)
        }
        // すべて隠れていると何も見えなくなるので、そのときは全部出す
        if tableView.tableColumns.allSatisfy(\.isHidden) {
            tableView.tableColumns.forEach { $0.isHidden = false }
        }
    }

    /// 見出しの右クリックメニュー。列ごとのチェックと、すべて表示・元に戻す
    private func updateHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let japanese = language == .japanese
        let visibleCount = tableView.tableColumns.filter { !$0.isHidden }.count
        for tableColumn in tableView.tableColumns {
            let item = NSMenuItem(
                title: tableColumn.title,
                action: #selector(toggleColumnVisibilityMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = tableColumn.isHidden ? .off : .on
            item.representedObject = tableColumn.identifier
            // 最後の1列は隠せない
            item.isEnabled = tableColumn.isHidden || visibleCount > 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let showAllItem = NSMenuItem(
            title: japanese ? "すべての列を表示" : "Show All Columns",
            action: #selector(showAllColumnsMenuItemSelected(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = self
        showAllItem.isEnabled = visibleCount < tableView.tableColumns.count
        menu.addItem(showAllItem)
        let resetItem = NSMenuItem(
            title: japanese ? "列の並び・幅・表示を元に戻す" : "Reset Column Layout",
            action: #selector(resetColumnLayoutMenuItemSelected(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        resetItem.isEnabled = isShowingDatabaseData
        menu.addItem(resetItem)
    }

    @objc private func toggleColumnVisibilityMenuItemSelected(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? NSUserInterfaceItemIdentifier,
              let tableColumn = tableView.tableColumn(withIdentifier: identifier) else { return }
        tableColumn.isHidden.toggle()
        saveColumnLayout()
    }

    @objc private func showAllColumnsMenuItemSelected(_ sender: Any?) {
        tableView.tableColumns.forEach { $0.isHidden = false }
        saveColumnLayout()
    }

    /// 保存した見た目を消して、列を作り直す
    @objc private func resetColumnLayoutMenuItemSelected(_ sender: Any?) {
        guard isShowingDatabaseData, let displayedTable else { return }
        UserDefaults.standard.removeObject(forKey: columnLayoutKey(for: displayedTable))
        rebuildColumns()
        tableView.reloadData()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard notification.object as? NSTableView === tableView else { return }
        saveColumnLayout()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard notification.object as? NSTableView === tableView else { return }
        saveColumnLayout()
    }

    @objc private func languageDidChange(_ sender: NSPopUpButton) {
        language = Language.allCases[sender.indexOfSelectedItem]
        updateConnectionUI()
        updateTableListPlaceholder()
        updateMainMenu()
        rebuildConnectionMenu()
        // 一覧のアイコンの説明（ツールチップ）を付け直す
        tableListView.reloadData()
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
        if databaseColumns != nil, !isShowingQueryResult, let selectedTable {
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

    // MARK: - Relation kinds

    private static func symbolName(for kind: RelationKind) -> String {
        switch kind {
        case .table, .partitionedTable: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .foreignTable: "network"
        }
    }

    private static func kindTitle(_ kind: RelationKind, in language: Language) -> String {
        switch (kind, language) {
        case (.table, .japanese): "テーブル"
        case (.table, .english): "Table"
        case (.partitionedTable, .japanese): "パーティションテーブル"
        case (.partitionedTable, .english): "Partitioned table"
        case (.view, .japanese): "ビュー"
        case (.view, .english): "View"
        case (.materializedView, .japanese): "マテリアライズドビュー"
        case (.materializedView, .english): "Materialized view"
        case (.foreignTable, .japanese): "外部テーブル"
        case (.foreignTable, .english): "Foreign table"
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
                    // 先頭に、テーブルかビューかなどを表すアイコンを置く
                    let icon = NSImageView()
                    icon.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(icon)
                    cell.imageView = icon
                    let field = NSTextField(labelWithString: "")
                    field.lineBreakMode = .byTruncatingTail
                    field.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(field)
                    cell.textField = field
                    NSLayoutConstraint.activate([
                        icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        icon.widthAnchor.constraint(equalToConstant: 16),
                        icon.heightAnchor.constraint(equalToConstant: 16),
                        field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            let table = tables[row]
            let kind = tableKinds[table] ?? .table
            cell.textField?.stringValue = table.displayName
            cell.imageView?.image = NSImage(
                systemSymbolName: Self.symbolName(for: kind),
                accessibilityDescription: Self.kindTitle(kind, in: language)
            )
            cell.toolTip = Self.kindTitle(kind, in: language)
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
            cell.font = value == nil ? Self.nullFont : Self.cellFont
            cell.alignment = numericColumnIndexes.contains(index) ? .right : .left
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
        cell.font = Self.cellFont
        cell.alignment = column == .fruit ? .left : .right
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
