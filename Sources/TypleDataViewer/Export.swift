import Foundation
import UniformTypeIdentifiers

/// 表を書き出すときの形式
enum ExportFormat: CaseIterable {
    case csv
    case tsv
    case json

    var title: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        }
    }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .json: .json
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .json: "json"
        }
    }
}

/// 列名と行（値は text、nil は NULL）を CSV・TSV・JSON の文字列にする
enum TableExporter {
    static func data(columns: [String], rows: [[String?]], format: ExportFormat) -> Data {
        let text = string(columns: columns, rows: rows, format: format)
        // Excel が UTF-8 と判断して日本語を化けさせないよう、CSV には BOM を付ける
        let prefix = format == .csv ? Data([0xEF, 0xBB, 0xBF]) : Data()
        return prefix + Data(text.utf8)
    }

    static func string(columns: [String], rows: [[String?]], format: ExportFormat) -> String {
        switch format {
        case .csv:
            // RFC 4180 に合わせて CRLF で区切る。NULL は空欄
            let lines = [columns] + rows.map { $0.map { $0 ?? "" } }
            return lines.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        case .tsv:
            let lines = [columns] + rows.map { $0.map { $0 ?? "" } }
            return lines.map { $0.map(tsvField).joined(separator: "\t") }.joined(separator: "\n") + "\n"
        case .json:
            return json(columns: columns, rows: rows)
        }
    }

    /// タブや改行、引用符を含む値は、区切りと間違えられないよう引用符で囲む（表計算アプリに貼れる形）
    static func tsvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return value }
        return quoted(value)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return value }
        return quoted(value)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 1行を1つのオブジェクトにした配列。キーは列の順に並べる（JSONSerialization は順番を保たないので自前で組む）。
    /// 値はすべて文字列か null。同じ名前の列が複数あるときは、2つ目以降に _2, _3 … を付けて区別する
    private static func json(columns: [String], rows: [[String?]]) -> String {
        var seen: [String: Int] = [:]
        let keys = columns.map { name -> String in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name)_\(count)"
        }
        let encodedKeys = keys.map(jsonString)
        let objects = rows.map { row in
            let members = zip(encodedKeys, row).map { key, value in
                "    \(key): \(value.map(jsonString) ?? "null")"
            }
            return members.isEmpty ? "  {}" : "  {\n" + members.joined(separator: ",\n") + "\n  }"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
