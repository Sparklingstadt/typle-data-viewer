import AppKit

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var language: Language = .japanese

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
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

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.width = column == .fruit ? 200 : 100
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        updateColumnTitles()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(titleLabel)
        contentView.addSubview(languagePopUp)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            languagePopUp.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            languagePopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: languagePopUp.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: languagePopUp.leadingAnchor, constant: -12),

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

    @objc private func languageDidChange(_ sender: NSPopUpButton) {
        language = Language.allCases[sender.indexOfSelectedItem]
        updateColumnTitles()
        // 果物名は言語で並び順が変わるので、現在のソートをかけ直す
        sortRows()
        tableView.reloadData()
    }

    private func updateColumnTitles() {
        for tableColumn in tableView.tableColumns {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.title = column.title(in: language)
        }
        tableView.headerView?.needsDisplay = true
    }

    private func sortRows() {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else { return }

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

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortRows()
        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }

        let item = rows[row]
        let text: String
        switch column {
        case .number: text = String(item.number)
        case .fruit: text = item.fruit(in: language)
        case .count: text = String(item.count)
        }

        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = tableColumn.identifier
                return field
            }()
        cell.stringValue = text
        cell.alignment = column == .fruit ? .left : .right
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
