import SwiftUI

/// 列数が実行時に決まる表。データ、スキーマ、SQL の結果で共用する
struct DataGrid: View {
    let columns: [GridColumn]
    let rows: [GridRow]
    let numericColumns: Set<Int>
    @Binding var sortOrder: [GridSort]
    @State private var selection = Set<GridRow.ID>()

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView("表示する列がありません", systemImage: "tablecells")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumnForEach(columns) { column in
                        TableColumn(column.name, sortUsing: GridSort(column: column.id)) { row in
                            cell(row.value(at: column.id), isNumeric: numericColumns.contains(column.id))
                        }
                    }
                }
                // 列の構成が変わったら、列幅などを引き継がず作り直す
                .id(columns)
                .onChange(of: rows) {
                    selection = []
                    // ページ送りや絞り込みのあとは先頭から見せる
                    if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) }
                }
                .onCopyCommand {
                    let selected = rows.filter { selection.contains($0.id) }
                    guard !selected.isEmpty else { return [] }
                    return [NSItemProvider(object: GridLogic.tsv(columns: columns, rows: selected) as NSString)]
                }
            }
        }
    }

    private func cell(_ value: String?, isNumeric: Bool) -> some View {
        Text(value ?? "NULL")
            .italic(value == nil)
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: isNumeric ? .trailing : .leading)
    }
}
