# SwiftUI 版 Typle Data Viewer 試作 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AppKit 版と比べるため、主要機能を純 SwiftUI で動かす試作をこのブランチに作る。

**Architecture:** `Database.swift` と `Connections.swift` はそのまま使い、UI を `@Observable` の `AppModel` と SwiftUI のビューに置き換える。表は `Table` と `TableColumnForEach` の共用部品 `DataGrid` で描く。表の純粋なロジックは `GridLogic.swift` に切り出してテストする。

**Tech Stack:** Swift 6、SwiftUI、PostgresNIO、Swift Testing、SwiftPM

**Spec:** `docs/superpowers/specs/2026-11-06-swiftui-prototype-design.md`

## Global Constraints

- 対応 OS は `.macOS("14.4")`。
- `Database.swift`、`Connections.swift`、`Export.swift` は変更しない。
- AppKit を使ってよいのは `NSApp.setActivationPolicy(.regular)` と前面化の処理だけ（`import AppKit` は `TypleDataViewerApp.swift` のみ）。
- UI の文言は日本語のみ。AppKit 版の日本語の文言をそのまま使う。
- コミットは `feat:` などの接頭辞に日本語の件名を付ける。push はしない。
- `swift build` や `swift test` がサンドボックスで失敗したら、まず `--disable-sandbox` を付ける。

## Review Focus

1. SQL の結果で列名が重複する（`SELECT a.id, b.id ...`）。落ちずに両方の列が出る。列の ID は名前ではなく位置にする（Task 1 でテスト）。
2. 列数が違う表へ切り替えた直後、古い列定義と新しい行が一瞬組み合わさる。範囲外アクセスで落ちない（Task 1 でテスト）。
3. 行が0件の表、列が0個の結果（`SELECT;`）。落ちずに空の表を出す（Task 1 でテスト、Task 5 で実機確認）。
4. 改行や非常に長い文字列を含むセル。行の高さが崩れず1行で省略表示される（Task 3 で `lineLimit(1)`、Task 5 で実機確認）。
5. 読み込み中や SQL 実行中の切断、テーブル切り替え。古い結果が表に出ない（Task 2、3 の世代番号、Task 5 で実機確認）。

---

### Task 1: 表のロジック

**Files:**
- Create: `Sources/TypleDataViewer/GridLogic.swift`
- Create: `Tests/TypleDataViewerTests/GridLogicTests.swift`
- Modify: `Package.swift`（`.testTarget(name: "TypleDataViewerTests", dependencies: ["TypleDataViewer"])` を追加）

**Interfaces:**
- Produces:
  - `struct GridColumn: Identifiable, Hashable { let id: Int; let name: String }`（`id` は列の位置）
  - `struct GridRow: Identifiable, Hashable { let id: Int; let values: [String?]; func value(at column: Int) -> String? }`（範囲外は `nil`）
  - `struct GridSort: SortComparator, Hashable { var column: Int; var order: SortOrder = .forward }`（`compare(_:_:)` は `GridRow` を比べる）
  - `enum GridLogic`:
    - `static func columns(_ names: [String]) -> [GridColumn]`
    - `static func rows(_ values: [[String?]]) -> [GridRow]`
    - `static func tsv(columns: [GridColumn], rows: [GridRow]) -> String`
    - `static func lastPageOffset(totalCount: Int, pageSize: Int) -> Int`
    - `static func rangeText(offset: Int, shown: Int, total: Int) -> String`
    - `static func queryStatusText(rowCount: Int, seconds: Double, isTruncated: Bool) -> String`
    - `static func defaultSelect(for table: TableName) -> String`

- [ ] **Step 1: `Package.swift` にテストターゲットを足し、`GridLogicTests.swift` を書く**

`@testable import TypleDataViewer` と Swift Testing を使う。テストと期待値:

```swift
@Test func duplicateColumnNamesStayDistinct() {
    #expect(GridLogic.columns(["id", "id"]).map(\.id) == [0, 1])
}
@Test func outOfRangeValueIsNil() {
    #expect(GridRow(id: 0, values: ["a"]).value(at: 3) == nil)
}
@Test func sortPutsNullFirstAscendingAndKeepsTiesInOrder() {
    let rows = GridLogic.rows([["b"], [nil], ["a"], ["a"]])
    #expect(rows.sorted(using: GridSort(column: 0)).map(\.id) == [1, 2, 3, 0])
    #expect(rows.sorted(using: GridSort(column: 0, order: .reverse)).map(\.id) == [0, 2, 3, 1])
}
@Test func sortComparesNumbersNaturally() {
    let rows = GridLogic.rows([["10"], ["9"]])
    #expect(rows.sorted(using: GridSort(column: 0)).map(\.id) == [1, 0])
}
@Test func tsvQuotesTabsAndBlanksNull() {
    let columns = GridLogic.columns(["a", "b"])
    let rows = GridLogic.rows([["x\ty", nil], ["1", "2"]])
    #expect(GridLogic.tsv(columns: columns, rows: rows) == "\"x\ty\"\t\n1\t2")
}
@Test func lastPageOffsetLandsOnPageStart() {
    #expect(GridLogic.lastPageOffset(totalCount: 2500, pageSize: 1000) == 2000)
    #expect(GridLogic.lastPageOffset(totalCount: 2000, pageSize: 1000) == 1000)
}
@Test func rangeTextMatchesAppKitWording() {
    #expect(GridLogic.rangeText(offset: 1000, shown: 1000, total: 2500) == "1,001〜2,000 件目 / 全 2,500 件")
    #expect(GridLogic.rangeText(offset: 0, shown: 0, total: 0) == "0 件")
}
@Test func queryStatusTextMentionsTruncation() {
    #expect(GridLogic.queryStatusText(rowCount: 3, seconds: 0.5, isTruncated: false) == "3 行（0.50 秒）")
    #expect(GridLogic.queryStatusText(rowCount: 3, seconds: 0.5, isTruncated: true) == "先頭の 3 行を表示（0.50 秒）")
}
@Test func defaultSelectQuotesName() {
    #expect(GridLogic.defaultSelect(for: TableName(schema: "public", name: "t")) == "SELECT * FROM \"public\".\"t\" LIMIT 100;")
}
```

- [ ] **Step 2: `swift test` で失敗を確認する**

Expected: `GridLogic` が未定義のコンパイルエラー。

- [ ] **Step 3: `GridLogic.swift` を実装する**

`GridSort.compare` は AppKit 版 `compare(_: String?, _: String?)` と同じく `nil` を最小とし、文字列は `localizedStandardCompare` で比べる。値が同じなら `order` に関わらず `id` の昇順にする。`tsv` のセルは `TableExporter.tsvField` で整形する。

- [ ] **Step 4: `swift test` で全件成功を確認する**

- [ ] **Step 5: コミットする**

`feat: 表のロジックを GridLogic に追加`

---

### Task 2: AppKit の UI を外し、接続とテーブル一覧を動かす

**Files:**
- Delete: `Sources/TypleDataViewer/main.swift`、`ValueWindow.swift`、`CopyableTableView.swift`
- Create: `Sources/TypleDataViewer/TypleDataViewerApp.swift`、`AppModel.swift`、`ContentView.swift`
- Modify: `Package.swift`（`platforms: [.macOS("14.4")]`）

**Interfaces:**
- Consumes: `Database`、`ConnectionStore`、`Keychain`、`ConnectionTarget`、`ConnectionProfile`
- Produces（`AppModel.swift`）:
  - `enum ConnectionState { case disconnected, connecting, connected(serverVersion: String), failed(Error); var statusText: String; var buttonTitle: String }`（文言は AppKit 版の日本語）
  - `enum ContentTab: String, CaseIterable, Identifiable { case data = "データ", schema = "スキーマ", sql = "SQL" }`
  - `@MainActor @Observable final class AppModel`:
    - `var connectionState: ConnectionState`、`let profiles: [ConnectionProfile]`、`var selectedTarget: ConnectionTarget`
    - `var tables: [TableName]`、`var tableKinds: [TableName: RelationKind]`、`var selectedTable: TableName?`
    - `var tab: ContentTab`
    - `var alert: AppAlert?`（`struct AppAlert: Identifiable { let id = UUID(); let title: String; let message: String }`）
    - `func toggleConnection()`、`func connect()`、`func disconnect()`
    - `func selectionDidChange()`（Task 3 以降が中身を足す。この Task では空でよい）
    - `var connection: PostgresConnection?`（`private(set)`）

- [ ] **Step 1: 3ファイルを削除し、`Package.swift` の対応 OS を上げる**

- [ ] **Step 2: `AppModel.swift` を実装する**

`connect()` は AppKit 版 `connect()`（`git show main:Sources/TypleDataViewer/main.swift` の 948 行目）の流れに揃える。保存済み接続先は URL と Keychain のパスワードを使う。接続中に `selectedTarget` が変わったら接続を閉じて `.disconnected` にする。接続後は `selectedTarget` の保存（`ConnectionStore.selectedTarget`）はしない（状態復元は範囲外）。接続後は先頭のテーブルを選ぶ。`disconnect()` は接続を閉じ、一覧と選択を空にする。

- [ ] **Step 3: `TypleDataViewerApp.swift` を実装する**

`@main struct TypleDataViewerApp: App`。`WindowGroup` は `ContentView` に `AppModel` を渡す。`init()` で `NSApplication.shared.setActivationPolicy(.regular)`、表示後に前面化する。最後のウィンドウを閉じたら終了する（`NSApplicationDelegateAdaptor` は使わず `Window` シーンを使う）。

- [ ] **Step 4: `ContentView.swift` を実装する**

`NavigationSplitView`。サイドバーは `List(selection:)` で、種類ごとのアイコン（テーブル `tablecells`、ビュー `eye`、マテリアライズドビュー `square.stack.3d.up`、外部テーブル `link`）を付ける。未接続時は `ContentUnavailableView`。ツールバーに接続先の `Picker`（`DATABASE_URL` と保存済み接続先）、接続ボタン、状態の文言を置く。接続中は `Picker` を無効にする。詳細側はタブの `Picker(.segmented)` とプレースホルダーでよい。`.alert(item:)` 相当で `alert` を出す。

- [ ] **Step 5: `swift build` と `swift test` の成功を確認する**

- [ ] **Step 6: コミットする**

`feat: UI を SwiftUI に置き換え、接続とテーブル一覧を実装`

---

### Task 3: データタブ

**Files:**
- Create: `Sources/TypleDataViewer/DataGrid.swift`
- Modify: `AppModel.swift`、`ContentView.swift`、`TypleDataViewerApp.swift`

**Interfaces:**
- Consumes: Task 1 の型すべて、`AppModel`
- Produces:
  - `struct DataGrid: View`: `init(columns: [GridColumn], rows: [GridRow], numericColumns: Set<Int>, sortOrder: Binding<[GridSort]>)`
  - `AppModel` に追加:
    - `var query: TableQuery`、`var gridColumns: [GridColumn]`、`var gridRows: [GridRow]`、`var numericColumns: Set<Int>`、`var totalCount: Int`
    - `var dataSort: [GridSort]`（`didSet` で `TableQuery` に反映し再読み込み）
    - `func loadSelected()`、`func reload()`、`func applyFilter()`、`func nextPage()`、`func previousPage()`
    - `var loadGeneration: Int`（`private`）

- [ ] **Step 1: `DataGrid.swift` を実装する**

`Table(rows, selection: $selection, sortOrder: sortOrder)` に `TableColumnForEach(columns)` を使い、各列は `TableColumn(column.name, sortUsing: GridSort(column: column.id)) { row in ... }`。セルは `lineLimit(1)`、`nil` は斜体の `NULL` で薄い色、数値の列は右寄せ。列の構成が変わったら表を作り直すよう `.id(columns)` を付ける。`selection` は `Set<Int>` の `@State`。`.onCopyCommand` で選択行を `GridLogic.tsv` にして返す。列が0個なら `Table` を作らず空の表示にする。

動的列の見出しソートが動かない場合は、仕様の「既知の制約」どおり列と向きの `Picker` に切り替え、比較メモ用に事実を控える。

- [ ] **Step 2: `AppModel` に読み込みを実装する**

`loadSelected()` は世代番号を増やし、`Database.fetchTable` の結果を世代と接続と選択が変わっていないときだけ反映する。テーブルが変わったら `query` と `dataSort` を初期化する。行が空で `offset > 0`、`totalCount > 0` なら `GridLogic.lastPageOffset` で読み直す。失敗は `AppAlert(title: "テーブル「\(name)」を読み込めませんでした", message: String(reflecting: error))`。

- [ ] **Step 3: `ContentView.swift` にデータタブを実装する**

上に検索欄（`onSubmit` で `applyFilter()`、入力ごとには読み込まない）、列の `Picker`（先頭は「すべての列」）。中央に `DataGrid`。下に「前へ」「次へ」と `GridLogic.rangeText`。

- [ ] **Step 4: `Cmd+R` を実装する**

`TypleDataViewerApp` の `.commands` に「再読み込み」を追加し、`model.reload()` を呼ぶ。未接続時は無効。

- [ ] **Step 5: `swift build` の成功を確認する**

- [ ] **Step 6: コミットする**

`feat: データタブを実装`

---

### Task 4: スキーマタブと SQL タブ

**Files:**
- Create: `Sources/TypleDataViewer/SQLView.swift`
- Modify: `AppModel.swift`、`ContentView.swift`

**Interfaces:**
- Consumes: `DataGrid`、`GridLogic`、`AppModel`
- Produces: `AppModel` に追加
  - `var schema: TableSchema?`、`var schemaSort: [GridSort]`、`var schemaRows: [GridRow]`（`schemaSort` を適用した行）
  - `var sqlText: String`、`var isRunningQuery: Bool`、`var queryResult: QueryResult?`、`var queryDuration: TimeInterval`、`var querySort: [GridSort]`、`var queryRows: [GridRow]`
  - `var queryStatusText: String`、`func runQuery()`

- [ ] **Step 1: スキーマの読み込みと表示を実装する**

`loadSelected()` はタブがスキーマなら `Database.fetchSchema` を読む。見出しは `["列名", "型", "NOT NULL", "既定値", "キー"]`。表の上に `推定 N 行 · データ X · インデックス等を含め Y`、その下にインデックス定義（なければ「インデックスなし」）を出す。

- [ ] **Step 2: `runQuery()` を実装する**

`Database.runReadOnlyQuery` を呼び、実行時間を測る。世代番号を持ち、切断していたら結果を捨てる。エラーの文言は AppKit 版 `queryErrorText` に揃える（`DatabaseError.unsupportedStatement` と `PSQLError.serverInfo`）。タイトルは「SQL を実行できませんでした」。`queryStatusText` は未接続、実行中、結果あり（`GridLogic.queryStatusText`）、未実行の4通りで AppKit 版の文言を使う。

- [ ] **Step 3: `SQLView.swift` を実装する**

`VSplitView` の代わりに `VStack`。上に `TextEditor`（等幅）、「実行」ボタン（`.keyboardShortcut(.return, modifiers: .command)`）、状態の文言。下に `DataGrid`。タブが SQL で入力欄が空なら `GridLogic.defaultSelect` を入れる。タブを移っても結果を保つ。

- [ ] **Step 4: `swift build` と `swift test` の成功を確認する**

- [ ] **Step 5: コミットする**

`feat: スキーマタブと SQL タブを実装`

---

### Task 5: 実機確認と比較メモ

**Files:**
- Create: `docs/superpowers/specs/2026-11-06-swiftui-comparison.md`

- [ ] **Step 1: ローカル PostgreSQL を用意する**

Docker で `postgres:17` をポート 55432 で起動する。テーブル、外部キー、ビュー、マテリアライズドビュー、2,500 行のテーブル、NULL・長文・改行・タブを含む行、0 行のテーブルを作る。投入 SQL はスクラッチパッドに置き、コミットしない。

- [ ] **Step 2: アプリを起動し、仕様の「入れる機能」を順に確認する**

`DATABASE_URL` を渡して `swift run` する。Review Focus の5項目も確認する。不具合は直してコミットする（`fix:`）。

- [ ] **Step 3: 比較メモを書く**

UI 層の行数（`main` の3ファイルと、新規ファイル）、作りにくかった点と実現できなかった点、2,500 行テーブルの1,000 行ページの操作感を、実測した事実で書く。確認できなかった範囲は明記する。

- [ ] **Step 4: コンテナを止めて削除する**

- [ ] **Step 5: コミットする**

`docs: SwiftUI 版と AppKit 版の比較メモを追加`
