import XCTest
@testable import NAICullerCore

final class FailureSummaryTests: XCTestCase {
    func testEmptyNamesProduceEmptyString() {
        XCTAssertEqual(FailureSummary.text(names: []), "")
    }

    func testFewerThanLimitAreListedAsIs() {
        XCTAssertEqual(FailureSummary.text(names: ["a.png", "b.png"]), "a.png、b.png")
    }

    /// ちょうど上限件数のときに「他0件」を付けない（境界）。
    func testExactlyLimitHasNoRemainderSuffix() {
        let names = ["1", "2", "3", "4", "5"]
        XCTAssertEqual(FailureSummary.text(names: names), "1、2、3、4、5")
    }

    func testOverLimitFoldsRemainder() {
        let names = ["1", "2", "3", "4", "5", "6", "7"]
        XCTAssertEqual(FailureSummary.text(names: names), "1、2、3、4、5、他2件")
    }

    func testCustomLimit() {
        XCTAssertEqual(FailureSummary.text(names: ["a", "b", "c"], maxShown: 1), "a、他2件")
    }

    /// 0以下の上限が渡っても`prefix`の挙動に依存して壊れないこと。
    func testZeroLimitFoldsEverything() {
        XCTAssertEqual(FailureSummary.text(names: ["a", "b"], maxShown: 0), "他2件")
    }
}
