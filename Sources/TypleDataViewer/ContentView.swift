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
            Spacer()
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
