import AppKit

struct FruitRow {
    let number: Int
    let fruit: String
    let count: Int
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!

    private let rows: [FruitRow] = [
        FruitRow(number: 1, fruit: "りんご", count: 2),
        FruitRow(number: 2, fruit: "バナナ", count: 4),
        FruitRow(number: 3, fruit: "オレンジ", count: 4),
    ]

    private enum Column: String, CaseIterable {
        case number = "番号"
        case fruit = "果物"
        case count = "個数"

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typle Data Viewer"

        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.rawValue
            tableColumn.width = column == .fruit ? 200 : 100
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        window.contentView = scrollView

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }

        let item = rows[row]
        let text: String
        switch column {
        case .number: text = String(item.number)
        case .fruit: text = item.fruit
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
