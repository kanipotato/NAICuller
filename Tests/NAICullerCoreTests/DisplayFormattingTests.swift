import XCTest
@testable import NAICullerCore

/// 右パネルの表示整形のテスト（`DetailPanelView`から切り出したもの）。
final class DisplayFormattingTests: XCTestCase {

    // MARK: - 生成パラメータの数値

    /// cfg や LoRA の強度は 7.0 のような整数値になることが多く、7.00 と出すと冗長。
    func testParameterValueDropsDecimalsForWholeNumbers() {
        XCTAssertEqual(DisplayFormatting.parameterValue(7), "7")
        XCTAssertEqual(DisplayFormatting.parameterValue(7.0), "7")
        XCTAssertEqual(DisplayFormatting.parameterValue(0), "0")
    }

    func testParameterValueKeepsTwoDecimalsOtherwise() {
        XCTAssertEqual(DisplayFormatting.parameterValue(7.5), "7.50")
        XCTAssertEqual(DisplayFormatting.parameterValue(0.85), "0.85")
    }

    func testParameterValueRoundsToTwoDecimals() {
        XCTAssertEqual(DisplayFormatting.parameterValue(1.005), "1.00")
        XCTAssertEqual(DisplayFormatting.parameterValue(1.239), "1.24")
    }

    func testParameterValueHandlesNegatives() {
        XCTAssertEqual(DisplayFormatting.parameterValue(-2), "-2")
        XCTAssertEqual(DisplayFormatting.parameterValue(-2.5), "-2.50")
    }

    // MARK: - 寸法

    func testImageDimensionsFormatsBothValues() {
        XCTAssertEqual(DisplayFormatting.imageDimensions(width: 832, height: 1216), "832 × 1216")
    }

    /// 片方でも欠けていれば行自体を出さない（呼び出し側がnilで分岐する）。
    func testImageDimensionsIsNilWhenEitherIsMissing() {
        XCTAssertNil(DisplayFormatting.imageDimensions(width: nil, height: 1216))
        XCTAssertNil(DisplayFormatting.imageDimensions(width: 832, height: nil))
        XCTAssertNil(DisplayFormatting.imageDimensions(width: nil, height: nil))
    }

    // MARK: - ファイルサイズ

    func testFileSizeProducesNonEmptyString() {
        XCTAssertFalse(DisplayFormatting.fileSize(0).isEmpty)
        XCTAssertFalse(DisplayFormatting.fileSize(1_048_576).isEmpty)
    }

    func testFileSizeGrowsWithBytes() {
        // 表記はロケール依存なので厳密な文字列は比較せず、大小関係だけ確かめる。
        XCTAssertNotEqual(DisplayFormatting.fileSize(1_000), DisplayFormatting.fileSize(1_000_000))
    }

    // MARK: - 日時

    /// ロケール・タイムゾーンを固定すれば決定的に整形されること
    /// （既定は環境依存なので、テストでは必ず固定して比較する）。
    func testDateTimeIsDeterministicWithFixedLocaleAndTimeZone() {
        let date = Date(timeIntervalSince1970: 0)
        let text = DisplayFormatting.dateTime(
            date,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(text.contains("1970"), text)
        XCTAssertTrue(text.contains("Jan"), text)
    }
}
