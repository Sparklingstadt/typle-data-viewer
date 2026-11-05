import Foundation

/// 表の列。SQL の結果では列名が重なることがあるので、ID は列の位置にする
struct GridColumn: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// 表の1行。ID は取得時の順番
struct GridRow: Identifiable, Hashable, Sendable {
    let id: Int
    let values: [String?]

    /// 列の値。表の切り替え直後は列と行の組が一瞬ずれるので、範囲外は nil にする
    func value(at column: Int) -> String? {
        values.indices.contains(column) ? values[column] : nil
    }
}

/// 列の位置で行を比べる。NULL が最小で、同値は取得時の順に並べる
struct GridSort: SortComparator, Hashable, Sendable {
    var column: Int
    var order: SortOrder = .forward

    func compare(_ lhs: GridRow, _ rhs: GridRow) -> ComparisonResult {
        let result: ComparisonResult = switch (lhs.value(at: column), rhs.value(at: column)) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        case let (lhs?, rhs?): lhs.localizedStandardCompare(rhs)
        }
        if result == .orderedSame {
            return lhs.id < rhs.id ? .orderedAscending : lhs.id > rhs.id ? .orderedDescending : .orderedSame
        }
        guard order == .reverse else { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}

enum GridLogic {
    static func columns(_ names: [String]) -> [GridColumn] {
        names.enumerated().map { GridColumn(id: $0.offset, name: $0.element) }
    }

    static func rows(_ values: [[String?]]) -> [GridRow] {
        values.enumerated().map { GridRow(id: $0.offset, values: $0.element) }
    }

    /// 表計算アプリに貼れるよう、列はタブ、行は改行で区切る。NULL は空にする
    static func tsv(columns: [GridColumn], rows: [GridRow]) -> String {
        rows.map { row in
            columns.map { TableExporter.tsvField(row.value(at: $0.id) ?? "") }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func lastPageOffset(totalCount: Int, pageSize: Int) -> Int {
        (totalCount - 1) / pageSize * pageSize
    }

    static func rangeText(offset: Int, shown: Int, total: Int) -> String {
        guard total > 0, shown > 0 else { return "0 件" }
        return "\(formatCount(offset + 1))〜\(formatCount(offset + shown)) 件目 / 全 \(formatCount(total)) 件"
    }

    static func queryStatusText(rowCount: Int, seconds: Double, isTruncated: Bool) -> String {
        let count = formatCount(rowCount)
        let time = String(format: "%.2f", seconds)
        return isTruncated ? "先頭の \(count) 行を表示（\(time) 秒）" : "\(count) 行（\(time) 秒）"
    }

    static func defaultSelect(for table: TableName) -> String {
        "SELECT * FROM \(table.sqlName) LIMIT 100;"
    }

    static func formatCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
