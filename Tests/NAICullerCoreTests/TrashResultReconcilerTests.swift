import XCTest
@testable import NAICullerCore

/// ゴミ箱移動の結果突き合わせのテスト。
///
/// 「移動は成功したのに失敗と誤判定してDBレコードを消し忘れる」という実バグを踏んだ箇所なので、
/// パス表記がズレていても同一ファイルとして突き合わせられることを明示的に固定する。
final class TrashResultReconcilerTests: XCTestCase {
    private func makeImage(id: Int64, path: String) -> ImageRecord {
        ImageRecord(
            id: id, rootId: 1, path: path, mtime: 0,
            fileSize: 1, width: nil, height: nil, promptCache: nil, lastScannedAt: Date()
        )
    }

    func testExactMatchesAreCountedAsSucceeded() {
        let targets = [
            makeImage(id: 1, path: "/tmp/root/a.png"),
            makeImage(id: 2, path: "/tmp/root/b.png")
        ]
        let succeeded = TrashResultReconciler.succeeded(
            targets: targets,
            recycledOriginalURLs: [URL(fileURLWithPath: "/tmp/root/a.png")]
        )
        XCTAssertEqual(succeeded.map(\.id), [1])
    }

    /// `.`要素や重複スラッシュのような表記ゆれがあっても同一ファイルとして扱う
    /// （standardizedFileURLでの正規化が効いていることの確認）。
    func testNonNormalizedPathsStillMatch() {
        let targets = [makeImage(id: 1, path: "/tmp/root/a.png")]
        let succeeded = TrashResultReconciler.succeeded(
            targets: targets,
            recycledOriginalURLs: [URL(fileURLWithPath: "/tmp/root/./a.png")]
        )
        XCTAssertEqual(succeeded.map(\.id), [1], "表記ゆれで取りこぼすとDBレコードが残ってしまう")
    }

    func testParentTraversalPathStillMatches() {
        let targets = [makeImage(id: 1, path: "/tmp/root/a.png")]
        let succeeded = TrashResultReconciler.succeeded(
            targets: targets,
            recycledOriginalURLs: [URL(fileURLWithPath: "/tmp/root/sub/../a.png")]
        )
        XCTAssertEqual(succeeded.map(\.id), [1])
    }

    func testNoResultsMeansEverythingFailed() {
        let targets = [
            makeImage(id: 1, path: "/tmp/root/a.png"),
            makeImage(id: 2, path: "/tmp/root/b.png")
        ]
        let succeeded = TrashResultReconciler.succeeded(targets: targets, recycledOriginalURLs: [URL]())
        XCTAssertTrue(succeeded.isEmpty)
        XCTAssertEqual(TrashResultReconciler.failureCount(targets: targets, recycledOriginalURLs: [URL]()), 2)
    }

    func testFailureCountCountsOnlyUnmatched() {
        let targets = [
            makeImage(id: 1, path: "/tmp/root/a.png"),
            makeImage(id: 2, path: "/tmp/root/b.png"),
            makeImage(id: 3, path: "/tmp/root/c.png")
        ]
        let recycled = [
            URL(fileURLWithPath: "/tmp/root/a.png"),
            URL(fileURLWithPath: "/tmp/root/c.png")
        ]
        XCTAssertEqual(TrashResultReconciler.failureCount(targets: targets, recycledOriginalURLs: recycled), 1)
    }

    func testSucceededPreservesTargetOrder() {
        let targets = [
            makeImage(id: 3, path: "/tmp/root/c.png"),
            makeImage(id: 1, path: "/tmp/root/a.png")
        ]
        let recycled = [
            URL(fileURLWithPath: "/tmp/root/a.png"),
            URL(fileURLWithPath: "/tmp/root/c.png")
        ]
        let succeeded = TrashResultReconciler.succeeded(targets: targets, recycledOriginalURLs: recycled)
        XCTAssertEqual(succeeded.map(\.id), [3, 1])
    }

    /// 渡していないURLが返ってきても、targetsに無いものは無視する。
    func testUnknownRecycledURLsAreIgnored() {
        let targets = [makeImage(id: 1, path: "/tmp/root/a.png")]
        let recycled = [
            URL(fileURLWithPath: "/tmp/root/a.png"),
            URL(fileURLWithPath: "/tmp/other/z.png")
        ]
        let succeeded = TrashResultReconciler.succeeded(targets: targets, recycledOriginalURLs: recycled)
        XCTAssertEqual(succeeded.map(\.id), [1])
    }
}
