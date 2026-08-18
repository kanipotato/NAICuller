import XCTest
@testable import NAICullerCore

/// バリデーション失敗の説明文のテスト。
///
/// `RootPathValidator.Failure`の文言は元は`MainWindowView`と`SettingsView`に
/// 同一の`describe(_:)`として重複しており、片方だけ直して片方が古いまま残る形だった。
/// 失敗ケース側に寄せたので、ここで全ケースが文言を持つことを固定する。
final class ValidationMessageTests: XCTestCase {

    // MARK: - RootPathValidator.Failure

    func testRootFailureMessagesAreNotEmpty() {
        let failures: [RootPathValidator.Failure] = [
            .notExisting,
            .notDirectory,
            .duplicateOrContained(existingPath: "/tmp/a")
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) の説明文が空")
        }
    }

    func testRootFailureMessagesAreDistinct() {
        let messages = Set([
            RootPathValidator.Failure.notExisting.message,
            RootPathValidator.Failure.notDirectory.message,
            RootPathValidator.Failure.duplicateOrContained(existingPath: "/tmp/a").message
        ])
        XCTAssertEqual(messages.count, 3, "ケースごとに違う説明が出るべき")
    }

    /// 重複エラーは「どのルートと衝突したか」が分からないと直しようがないので、
    /// 既存パスを必ず含める。
    func testDuplicateMessageIncludesConflictingPath() {
        let message = RootPathValidator.Failure.duplicateOrContained(existingPath: "/Users/x/Pictures").message
        XCTAssertTrue(message.contains("/Users/x/Pictures"), message)
    }

    func testNotExistingAndNotDirectoryMentionThePathProblem() {
        XCTAssertTrue(RootPathValidator.Failure.notExisting.message.contains("存在"))
        XCTAssertTrue(RootPathValidator.Failure.notDirectory.message.contains("ディレクトリ"))
    }

    // MARK: - TagNameValidator.Failure

    func testTagFailureMessagesAreNotEmptyAndDistinct() {
        let failures: [TagNameValidator.Failure] = [.empty, .containsControlCharacters, .tooLong]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) の説明文が空")
        }
        XCTAssertEqual(Set(failures.map(\.message)).count, 3)
    }

    /// 上限文字数はコード側の定数と必ず一致させる（片方だけ変えても気付けるように）。
    func testTooLongMessageUsesTheActualLimit() {
        let message = TagNameValidator.Failure.tooLong.message
        XCTAssertTrue(message.contains("\(TagNameValidator.maxLength)"), message)
    }

    /// バリデータが返す失敗が、必ず対応する説明文を引けること
    /// （実際の入力から文言までを一本で確認する）。
    func testValidatorFailuresMapToMessages() {
        XCTAssertEqual(TagNameValidator.validate("   ")?.message, TagNameValidator.Failure.empty.message)
        XCTAssertEqual(TagNameValidator.validate("a\nb")?.message, TagNameValidator.Failure.containsControlCharacters.message)
        let long = String(repeating: "あ", count: TagNameValidator.maxLength + 1)
        XCTAssertEqual(TagNameValidator.validate(long)?.message, TagNameValidator.Failure.tooLong.message)
        XCTAssertNil(TagNameValidator.validate("ふつうのタグ"))
    }
}
