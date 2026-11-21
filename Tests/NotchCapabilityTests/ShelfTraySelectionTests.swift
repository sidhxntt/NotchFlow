import XCTest
@testable import NotchCapabilities

final class ShelfTraySelectionTests: XCTestCase {
    private func files(_ names: [String]) -> [NotchShelfItem] {
        names.map { NotchShelfItem(kind: .file(bookmark: Data(), fallbackURL: URL(fileURLWithPath: "/tmp/\($0)"))) }
    }

    func testPlainClickTogglesAndSetsAnchor() {
        let items = files(["a.png", "b.png"])
        let on = ShelfTraySelection.selection(afterClicking: items[0].id, extendingRange: false,
                                              in: items, current: [], anchor: nil)
        XCTAssertEqual(on.selection, [items[0].id])
        XCTAssertEqual(on.anchor, items[0].id)

        let off = ShelfTraySelection.selection(afterClicking: items[0].id, extendingRange: false,
                                               in: items, current: on.selection, anchor: on.anchor)
        XCTAssertTrue(off.selection.isEmpty)
        XCTAssertNil(off.anchor)
    }

    func testShiftClickSelectsRangeInTrayOrderEitherDirection() {
        let items = files(["a.png", "b.png", "c.png", "d.png", "e.png"])
        let down = ShelfTraySelection.selection(afterClicking: items[3].id, extendingRange: true,
                                                in: items, current: [items[1].id], anchor: items[1].id)
        XCTAssertEqual(down.selection, Set(items[1...3].map(\.id)))
        XCTAssertEqual(down.anchor, items[1].id)

        let up = ShelfTraySelection.selection(afterClicking: items[0].id, extendingRange: true,
                                              in: items, current: [items[2].id], anchor: items[2].id)
        XCTAssertEqual(up.selection, Set(items[0...2].map(\.id)))
    }

    func testShiftClickKeepsRowsSelectedOutsideTheRange() {
        let items = files(["a.png", "b.png", "c.png", "d.png"])
        let result = ShelfTraySelection.selection(afterClicking: items[3].id, extendingRange: true,
                                                  in: items, current: [items[0].id, items[2].id],
                                                  anchor: items[2].id)
        XCTAssertEqual(result.selection, [items[0].id, items[2].id, items[3].id])
    }

    func testShiftClickWithoutAnchorFallsBackToToggle() {
        let items = files(["a.png", "b.png"])
        let result = ShelfTraySelection.selection(afterClicking: items[1].id, extendingRange: true,
                                                  in: items, current: [], anchor: nil)
        XCTAssertEqual(result.selection, [items[1].id])
        XCTAssertEqual(result.anchor, items[1].id)
    }

    func testArrowMovesASingleSelectionAndStopsAtTheEnds() {
        let items = files(["a.png", "b.png", "c.png"])
        let down = ShelfTraySelection.selection(afterMoving: 1, extendingRange: false, in: items,
                                                current: [items[0].id], anchor: items[0].id,
                                                cursor: items[0].id)
        XCTAssertEqual(down?.selection, [items[1].id])
        XCTAssertEqual(down?.anchor, items[1].id)
        XCTAssertEqual(down?.cursor, items[1].id)

        let pastEnd = ShelfTraySelection.selection(afterMoving: 1, extendingRange: false, in: items,
                                                   current: [items[2].id], anchor: items[2].id,
                                                   cursor: items[2].id)
        XCTAssertEqual(pastEnd?.selection, [items[2].id])
    }

    func testShiftArrowExtendsFromTheAnchorAndShrinksBack() {
        let items = files(["a.png", "b.png", "c.png", "d.png"])
        let first = ShelfTraySelection.selection(afterMoving: 1, extendingRange: true, in: items,
                                                 current: [items[1].id], anchor: items[1].id,
                                                 cursor: items[1].id)
        XCTAssertEqual(first?.selection, Set(items[1...2].map(\.id)))
        let second = ShelfTraySelection.selection(afterMoving: 1, extendingRange: true, in: items,
                                                  current: first!.selection, anchor: first!.anchor,
                                                  cursor: first!.cursor)
        XCTAssertEqual(second?.selection, Set(items[1...3].map(\.id)))
        XCTAssertEqual(second?.anchor, items[1].id)
        let back = ShelfTraySelection.selection(afterMoving: -1, extendingRange: true, in: items,
                                                current: second!.selection, anchor: second!.anchor,
                                                cursor: second!.cursor)
        XCTAssertEqual(back?.selection, Set(items[1...2].map(\.id)))
        let above = ShelfTraySelection.selection(afterMoving: -1, extendingRange: true, in: items,
                                                 current: [items[1].id], anchor: items[1].id,
                                                 cursor: items[1].id)
        XCTAssertEqual(above?.selection, Set(items[0...1].map(\.id)))
    }

    func testArrowDoesNothingWithoutASelection() {
        let items = files(["a.png", "b.png"])
        XCTAssertNil(ShelfTraySelection.selection(afterMoving: 1, extendingRange: true, in: items,
                                                  current: [], anchor: nil, cursor: nil))
    }

    func testSameTypeFilesAcceptsOneExtensionCaseInsensitively() {
        let items = files(["a.JPG", "b.jpg", "c.jpg"])
        XCTAssertEqual(ShelfTraySelection.sameTypeFiles(items)?.count, 3)
    }

    func testSameTypeFilesRejectsMixedTypesTextAndEmpty() {
        XCTAssertNil(ShelfTraySelection.sameTypeFiles(files(["a.png", "b.jpg"])))
        XCTAssertNil(ShelfTraySelection.sameTypeFiles(files(["a.png"]) + [.text("hello")]))
        XCTAssertNil(ShelfTraySelection.sameTypeFiles([]))
        XCTAssertNil(ShelfTraySelection.sameTypeFiles(files(["Makefile"])))
    }
}
