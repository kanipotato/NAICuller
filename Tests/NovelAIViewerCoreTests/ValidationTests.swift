import XCTest
@testable import NovelAIViewerCore

final class TagNameValidatorTests: XCTestCase {
    func testEmptyIsRejected() {
        XCTAssertEqual(TagNameValidator.validate(""), .empty)
    }

    func testWhitespaceOnlyIsRejected() {
        XCTAssertEqual(TagNameValidator.validate("   "), .empty)
        XCTAssertEqual(TagNameValidator.validate("\t\n"), .empty)
    }

    func testControlCharacterIsRejected() {
        XCTAssertEqual(TagNameValidator.validate("お気に\n入り"), .containsControlCharacters)
        XCTAssertEqual(TagNameValidator.validate("タブ\tあり"), .containsControlCharacters)
    }

    func testTooLongIsRejected() {
        let longName = String(repeating: "あ", count: 65)
        XCTAssertEqual(TagNameValidator.validate(longName), .tooLong)
    }

    func testExactlyMaxLengthIsAccepted() {
        let name = String(repeating: "あ", count: 64)
        XCTAssertNil(TagNameValidator.validate(name))
    }

    func testValidNameIsAccepted() {
        XCTAssertNil(TagNameValidator.validate("用途:blog"))
        XCTAssertNil(TagNameValidator.validate("お気に入り"))
    }

    func testNormalizeTrimsSurroundingWhitespace() {
        XCTAssertEqual(TagNameValidator.normalize("  用途:blog  "), "用途:blog")
    }

    func testNormalizeReturnsNilForInvalidInput() {
        XCTAssertNil(TagNameValidator.normalize("   "))
        XCTAssertNil(TagNameValidator.normalize("改行\n入り"))
    }

    func testIsSameNameIgnoresCase() {
        XCTAssertTrue(TagNameValidator.isSameName("Blog", "blog"))
        XCTAssertFalse(TagNameValidator.isSameName("Blog", "vlog"))
    }
}

final class RootPathValidatorTests: XCTestCase {
    func testNotExistingPathIsRejected() {
        let failure = RootPathValidator.validate(
            candidatePath: "/no/such/path",
            existingPaths: [],
            fileExists: { _ in (exists: false, isDirectory: false) }
        )
        XCTAssertEqual(failure, .notExisting)
    }

    func testFilePathIsRejected() {
        let failure = RootPathValidator.validate(
            candidatePath: "/tmp/somefile.txt",
            existingPaths: [],
            fileExists: { _ in (exists: true, isDirectory: false) }
        )
        XCTAssertEqual(failure, .notDirectory)
    }

    func testDuplicatePathIsRejected() {
        let failure = RootPathValidator.validate(
            candidatePath: "/Users/tester/NovelAI",
            existingPaths: ["/Users/tester/NovelAI"],
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        if case .duplicateOrContained = failure {
            // OK
        } else {
            XCTFail("Expected duplicateOrContained, got \(String(describing: failure))")
        }
    }

    func testContainedPathIsRejected() {
        // 既存ルートの子ディレクトリを追加しようとするケース
        let failure = RootPathValidator.validate(
            candidatePath: "/Users/tester/NovelAI/sub",
            existingPaths: ["/Users/tester/NovelAI"],
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        if case .duplicateOrContained = failure {
            // OK
        } else {
            XCTFail("Expected duplicateOrContained, got \(String(describing: failure))")
        }
    }

    func testAncestorOfExistingRootIsRejected() {
        // 既存ルートの親ディレクトリを追加しようとするケース（包含関係の逆方向）
        let failure = RootPathValidator.validate(
            candidatePath: "/Users/tester",
            existingPaths: ["/Users/tester/NovelAI"],
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        if case .duplicateOrContained = failure {
            // OK
        } else {
            XCTFail("Expected duplicateOrContained, got \(String(describing: failure))")
        }
    }

    func testUnrelatedPathIsAccepted() {
        let failure = RootPathValidator.validate(
            candidatePath: "/Users/tester/OtherFolder",
            existingPaths: ["/Users/tester/NovelAI"],
            fileExists: { _ in (exists: true, isDirectory: true) }
        )
        XCTAssertNil(failure)
    }
}
