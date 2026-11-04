import AppKit

/// Cmd+C で選択中の行をコピーできる表。表計算アプリに貼れるよう、列はタブ、行は改行で区切る
@MainActor
final class CopyableTableView: NSTableView {
    /// 行と列からコピーする文字列を返す。nil（DB の NULL など）は空にする
    var copyValue: ((Int, NSUserInterfaceItemIdentifier) -> String?)?

    @objc func copy(_ sender: Any?) {
        guard let copyValue, !selectedRowIndexes.isEmpty else { return }
        // 列は見出しをドラッグで並べ替えられるので、いま見えている順で並べる
        let lines = selectedRowIndexes.map { row in
            tableColumns.map { TableExporter.tsvField(copyValue(row, $0.identifier) ?? "") }.joined(separator: "\t")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return copyValue != nil && !selectedRowIndexes.isEmpty
        }
        return super.validateUserInterfaceItem(item)
    }
}
