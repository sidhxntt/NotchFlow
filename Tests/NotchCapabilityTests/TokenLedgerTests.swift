import Foundation
import Testing
@testable import NotchCapabilities

@Test("the token journal appends without losing earlier events")
func tokenLedgerAppendPreservesEarlierEvents() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nf-token-ledger-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let ledger = TokenLedger(url: url)
    try ledger.append(Data("first".utf8))
    try ledger.append(Data("second".utf8))

    #expect(try ledger.records().map { String(decoding: $0, as: UTF8.self) } == ["first", "second"])
}

@Test("a torn final token journal record does not erase earlier events")
func tokenLedgerIgnoresTornFinalRecord() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nf-token-ledger-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("first\npartial".utf8).write(to: url)

    #expect(try TokenLedger(url: url).records().map { String(decoding: $0, as: UTF8.self) } == ["first"])
}
