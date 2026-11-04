import AppKit

/// セルの値を全文で見るためのウインドウ。表のセルは1行に切り詰めて表示しているので、長い値はここで読む。
/// JSON のオブジェクトや配列は、テキストではなく表にして見せる
@MainActor
final class ValueWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// 開いているウインドウを保持する。閉じたら外す
    private static var openControllers: [ValueWindowController] = []

    private let title: String
    private let language: Language
    /// JSON を表で見せているときの中身。テキスト表示のときは nil
    private var jsonTable: JSONTable?

    static func show(title: String, value: String?, language: Language) {
        let controller = ValueWindowController(title: title, value: value, language: language)
        openControllers.append(controller)
        controller.showWindow(nil)
    }

    private init(title: String, value: String?, language: Language) {
        self.title = title
        self.language = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false

        let container = value.flatMap(Self.jsonContainer(from:))
        jsonTable = container.map { JSONTable(container: $0, language: language) }

        super.init(window: window)

        if let jsonTable {
            let scrollView = makeTableScrollView(for: jsonTable)
            window.contentView = scrollView
            window.initialFirstResponder = scrollView.documentView
        } else {
            let scrollView = NSTextView.scrollableTextView()
            let textView = scrollView.documentView as! NSTextView
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            if let value {
                textView.string = value
                textView.textColor = .labelColor
            } else {
                textView.string = "NULL"
                textView.textColor = .tertiaryLabelColor
            }
            window.contentView = scrollView
            // 開いてすぐ Cmd+A で全選択できるよう、最初からテキストにフォーカスを置く
            window.initialFirstResponder = textView
        }

        // 開いた順に少しずつずらして、重なっても見分けられるようにする
        if let previous = Self.openControllers.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.openControllers.removeAll { $0 === self }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// JSON（jsonb の列など）のオブジェクトか配列なら、その中身を返す。それ以外は nil
    private static func jsonContainer(from value: String) -> Any? {
        guard let first = value.first, first == "{" || first == "[",
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else { return nil }
        return object
    }

    // MARK: - JSON table

    private func makeTableScrollView(for jsonTable: JSONTable) -> NSScrollView {
        let tableView = CopyableTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.copyValue = { [weak self] row, identifier in
            guard let jsonTable = self?.jsonTable,
                  let columnIndex = Int(identifier.rawValue),
                  jsonTable.rows.indices.contains(row),
                  jsonTable.rows[row].cells.indices.contains(columnIndex) else { return nil }
            switch jsonTable.rows[row].cells[columnIndex] {
            case .label(let text): return text
            case .value(let value): return JSONTable.text(for: value)
            case .missing: return nil
            }
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (index, column) in jsonTable.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            tableColumn.title = column.title
            tableColumn.width = column.isLabel ? (jsonTable.isArray ? 50 : 140) : 180
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }

    /// 値のセルをダブルクリックしたら、その値をさらに別ウインドウで開く。入れ子の JSON ならそれも表になる
    @objc private func tableViewDoubleClicked(_ sender: NSTableView) {
        guard let jsonTable,
              jsonTable.rows.indices.contains(sender.clickedRow),
              jsonTable.columns.indices.contains(sender.clickedColumn) else { return }
        let row = jsonTable.rows[sender.clickedRow]
        let column = jsonTable.columns[sender.clickedColumn]
        guard case .value(let value) = row.cells[sender.clickedColumn] else { return }
        Self.show(
            title: title + row.path + column.path,
            value: JSONTable.text(for: value),
            language: language
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        jsonTable?.rows.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let jsonTable, let tableColumn,
              let columnIndex = Int(tableColumn.identifier.rawValue),
              jsonTable.rows.indices.contains(row),
              jsonTable.rows[row].cells.indices.contains(columnIndex) else { return nil }

        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = tableColumn.identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()

        switch jsonTable.rows[row].cells[columnIndex] {
        case .label(let text):
            cell.stringValue = text
            cell.textColor = .secondaryLabelColor
        case .value(let value):
            cell.stringValue = JSONTable.text(for: value)
            cell.textColor = value is NSNull ? .tertiaryLabelColor : .labelColor
        case .missing:
            // 配列の要素にそのキーがないとき。null とは区別して空にする
            cell.stringValue = ""
        }
        return cell
    }
}

/// JSON のオブジェクトか配列を表の形にしたもの。
/// - オブジェクト: キーと値の2列
/// - オブジェクトの配列: 番号と、各要素のキーを列にしたもの
/// - それ以外の配列: 番号と値の2列
struct JSONTable {
    struct Column {
        let title: String
        /// キーや番号の列なら true。値の列は false
        let isLabel: Bool
        /// 入れ子を開いたときのウインドウ名に付ける、この列の分のパス
        let path: String
    }

    enum Cell {
        case label(String)
        case value(Any)
        case missing
    }

    struct Row {
        /// 入れ子を開いたときのウインドウ名に付ける、この行の分のパス（".key" や "[0]"）
        let path: String
        let cells: [Cell]
    }

    let columns: [Column]
    let rows: [Row]
    let isArray: Bool

    init(container: Any, language: Language) {
        let valueTitle = language == .japanese ? "値" : "Value"

        if let object = container as? [String: Any] {
            // JSONSerialization はキーの順番を保たないので、名前順に並べる
            let keys = object.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            columns = [
                Column(title: language == .japanese ? "キー" : "Key", isLabel: true, path: ""),
                Column(title: valueTitle, isLabel: false, path: ""),
            ]
            rows = keys.map { key in
                Row(path: "." + key, cells: [.label(key), .value(object[key] as Any)])
            }
            isArray = false
            return
        }

        let array = container as? [Any] ?? []
        isArray = true
        let indexColumn = Column(title: "#", isLabel: true, path: "")
        let objects = array.compactMap { $0 as? [String: Any] }

        if !array.isEmpty, objects.count == array.count {
            // 要素ごとにキーが違うこともあるので、全要素のキーを合わせて列にする
            let keys = Set(objects.flatMap(\.keys))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            columns = [indexColumn] + keys.map { Column(title: $0, isLabel: false, path: "." + $0) }
            rows = objects.enumerated().map { index, object in
                Row(
                    path: "[\(index)]",
                    cells: [.label(String(index))] + keys.map { key in
                        object[key].map(Cell.value) ?? .missing
                    }
                )
            }
        } else {
            columns = [indexColumn, Column(title: valueTitle, isLabel: false, path: "")]
            rows = array.enumerated().map { index, element in
                Row(path: "[\(index)]", cells: [.label(String(index)), .value(element)])
            }
        }
    }

    /// セルに出す文字列。入れ子のオブジェクトや配列は1行の JSON にする
    static func text(for value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default:
            guard let data = try? JSONSerialization.data(
                      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
                  let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
            return string
        }
    }
}
