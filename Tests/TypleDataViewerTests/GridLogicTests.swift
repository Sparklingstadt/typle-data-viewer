import Testing
@testable import TypleDataViewer

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
