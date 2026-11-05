import SwiftUI

/// SQL の入力欄と実行結果
struct SQLView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.sqlText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .padding(.horizontal, 8)
            HStack {
                Text(model.queryStatusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("実行") { model.runQuery() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.connection == nil || model.isRunningQuery)
            }
            .padding(8)
            DataGrid(
                columns: model.queryColumns,
                rows: model.queryRows,
                numericColumns: model.queryResult?.numericColumns ?? [],
                sortOrder: $model.querySort
            )
        }
    }
}
