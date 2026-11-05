import Testing
@testable import TypleDataViewer

/// SQL タブでテーブルを切り替えると読み込みが走らないので、選択の変更だけで古い結果を無効にする
@MainActor
@Test func selectionChangeInvalidatesInFlightLoads() {
    let model = AppModel()
    model.tab = .sql
    model.selectedTable = TableName(schema: "public", name: "t")
    let generation = model.loadGeneration
    model.selectionDidChange()
    #expect(model.loadGeneration > generation)
}

/// 読み込み中や失敗後は query.offset と表示中のページが食い違う。ページ操作は表示中のページを基準にする
@MainActor
@Test func pagingFollowsDisplayedPageNotPendingOffset() {
    let model = AppModel()
    model.query.offset = 1000
    #expect(model.displayedOffset == 0)
    #expect(!model.hasPreviousPage)
}
