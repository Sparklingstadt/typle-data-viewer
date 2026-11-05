import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .onChange(of: model.selectedTable) { model.selectionDidChange() }
        .onChange(of: model.tab) { model.loadSelected() }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder private var sidebar: some View {
        if model.connection == nil {
            ContentUnavailableView("未接続", systemImage: "cylinder.split.1x2", description: Text("DBに接続するとテーブルが並びます"))
        } else {
            List(model.tables, id: \.self, selection: $model.selectedTable) { table in
                Label(table.displayName, systemImage: icon(for: model.tableKinds[table]))
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            Picker("タブ", selection: $model.tab) {
                ForEach(ContentTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(8)
            switch model.tab {
            case .data: dataTab
            case .schema: schemaTab
            case .sql: SQLView(model: model)
            }
        }
    }

    private var schemaTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let schema = model.schema {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schemaSummary(schema))
                    Text(schema.indexes.isEmpty ? "インデックスなし" : schema.indexes.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            DataGrid(
                columns: model.schema == nil ? [] : model.schemaColumns,
                rows: model.schemaRows,
                numericColumns: [],
                sortOrder: $model.schemaSort
            )
        }
    }

    private func schemaSummary(_ schema: TableSchema) -> String {
        let rowCount = schema.estimatedRowCount.map(GridLogic.formatCount) ?? "不明"
        return "推定 \(rowCount) 行 · データ \(schema.tableSize) · インデックス等を含め \(schema.totalSize)"
    }

    private var dataTab: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("検索", text: $model.query.filterText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.applyFilter() }
                Picker("絞り込む列", selection: $model.query.filterColumn) {
                    Text("すべての列").tag(String?.none)
                    ForEach(model.gridColumns) { Text($0.name).tag(String?.some($0.name)) }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: model.query.filterColumn) { model.applyFilter() }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            DataGrid(
                columns: model.gridColumns,
                rows: model.gridRows,
                numericColumns: model.numericColumns,
                sortOrder: Binding(get: { model.dataSort }, set: { model.sortData(by: $0) })
            )
            HStack {
                Text(GridLogic.rangeText(offset: model.query.offset, shown: model.gridRows.count, total: model.totalCount))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("前へ") { model.previousPage() }.disabled(!model.hasPreviousPage)
                Button("次へ") { model.nextPage() }.disabled(!model.hasNextPage)
            }
            .padding(8)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Text(model.connectionState.statusText)
                .foregroundStyle(.secondary)
            Picker("接続先", selection: Binding(
                get: { model.selectedTarget.key },
                set: { model.selectTarget(ConnectionTarget(key: $0)) }
            )) {
                Text("DATABASE_URL").tag(ConnectionTarget.environment.key)
                ForEach(model.profiles, id: \.id) { profile in
                    Text(profile.name).tag(ConnectionTarget.profile(profile.id).key)
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .disabled(model.connectionState.isConnecting)
            Button(model.connectionState.buttonTitle) { model.toggleConnection() }
                .disabled(model.connectionState.isConnecting)
        }
    }

    private func icon(for kind: RelationKind?) -> String {
        switch kind {
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .foreignTable: "link"
        case .table, .partitionedTable, nil: "tablecells"
        }
    }
}
