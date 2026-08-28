import XCTest
@testable import NAICullerCore

/// フォルダツリー絞り込み機能（サブディレクトリ階層フィルタ）のCore層ロジックのテスト。
/// `FolderTreeBuilder`（画像一覧→ツリー構築）と`FolderVisibilityResolver`（表示判定・チェック状態）を
/// `AppModel`（SwiftUI/AppKit依存）を経由せず単体で確かめる。
final class FolderTreeTests: XCTestCase {
    private func makeImage(id: Int64, rootId: Int64 = 1, path: String) -> ImageRecord {
        ImageRecord(
            id: id,
            rootId: rootId,
            path: path,
            mtime: 0,
            fileSize: 100,
            width: nil,
            height: nil,
            promptCache: nil,
            lastScannedAt: Date()
        )
    }

    private let root = Root(id: 1, path: "/tmp/検証", addedAt: Date())

    // MARK: - FolderPathUtility

    func testRelativeDirectoryForImageDirectlyInRoot() {
        XCTAssertEqual(
            FolderPathUtility.relativeDirectory(imagePath: "/tmp/検証/a.png", rootPath: "/tmp/検証"),
            ""
        )
    }

    func testRelativeDirectoryForNestedImage() {
        XCTAssertEqual(
            FolderPathUtility.relativeDirectory(imagePath: "/tmp/検証/マスコット/オレンジChibi/a.png", rootPath: "/tmp/検証"),
            "マスコット/オレンジChibi"
        )
    }

    func testRelativeDirectoryHandlesTrailingSlashOnRootPath() {
        XCTAssertEqual(
            FolderPathUtility.relativeDirectory(imagePath: "/tmp/検証/マスコット/a.png", rootPath: "/tmp/検証/"),
            "マスコット"
        )
    }

    func testRelativeDirectoryFallsBackToRootWhenPathDoesNotMatch() {
        // 想定外データ(ルート配下でない画像)。安全側でルート直下扱いにフォールバックする。
        XCTAssertEqual(
            FolderPathUtility.relativeDirectory(imagePath: "/other/a.png", rootPath: "/tmp/検証"),
            ""
        )
    }

    /// レビュー指摘の修正：`hasPrefix`だけだと`/a/b`が`/a/bc/x.png`のような兄弟ディレクトリにも
    /// マッチしてしまっていた（境界チェック無し）。区切り文字までの一致を要求する。
    func testRelativeDirectoryRejectsPathThatOnlySharesAStringPrefix() {
        XCTAssertEqual(
            FolderPathUtility.relativeDirectory(imagePath: "/a/bc/x.png", rootPath: "/a/b"),
            ""
        )
    }

    // MARK: - FolderTreeBuilder

    func testBuildCreatesNestedNodesWithAccumulatedImageCounts() {
        let images = [
            makeImage(id: 1, path: "/tmp/検証/マスコット/オレンジChibi/1.png"),
            makeImage(id: 2, path: "/tmp/検証/マスコット/オレンジChibi/2.png"),
            makeImage(id: 3, path: "/tmp/検証/マスコット/青Chibi/3.png"),
            makeImage(id: 4, path: "/tmp/検証/4.png") // ルート直下
        ]
        let tree = FolderTreeBuilder.build(images: images, root: root)

        XCTAssertEqual(tree.relativePath, "")
        XCTAssertEqual(tree.imageCount, 4) // ルート自身は配下すべての合計
        XCTAssertEqual(tree.children.count, 1)

        let mascot = tree.children[0]
        XCTAssertEqual(mascot.name, "マスコット")
        XCTAssertEqual(mascot.imageCount, 3)
        XCTAssertEqual(mascot.children.map(\.name), ["オレンジChibi", "青Chibi"]) // localizedStandardCompareの順

        let orange = mascot.children.first { $0.name == "オレンジChibi" }
        XCTAssertEqual(orange?.imageCount, 2)
        XCTAssertEqual(orange?.relativePath, "マスコット/オレンジChibi")
    }

    func testBuildIgnoresImagesFromOtherRoots() {
        let images = [
            makeImage(id: 1, rootId: 1, path: "/tmp/検証/a.png"),
            makeImage(id: 2, rootId: 2, path: "/tmp/別ルート/b.png")
        ]
        let tree = FolderTreeBuilder.build(images: images, root: root)
        XCTAssertEqual(tree.imageCount, 1)
    }

    func testBuildProducesNoNodeForFoldersWithoutImages() {
        // FolderTreeBuilderは画像の実パスからのみノードを作るため、空フォルダの概念自体がツリーに現れない。
        let images = [makeImage(id: 1, path: "/tmp/検証/マスコット/1.png")]
        let tree = FolderTreeBuilder.build(images: images, root: root)
        XCTAssertEqual(tree.children.map(\.relativePath), ["マスコット"])
    }

    // MARK: - FolderVisibilityResolver.isVisible

    func testIsVisibleDefaultsToTrueWithNoOverrides() {
        XCTAssertTrue(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/オレンジChibi", overrides: [:]))
    }

    func testIsVisibleUsesExactMatchOverride() {
        let overrides: [FolderVisibilityKey: Bool] = [FolderVisibilityKey(rootId: 1, relativePath: "マスコット"): false]
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット", overrides: overrides))
    }

    func testIsVisibleInheritsFromNearestAncestor() {
        let overrides: [FolderVisibilityKey: Bool] = [FolderVisibilityKey(rootId: 1, relativePath: "マスコット"): false]
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/オレンジChibi", overrides: overrides))
    }

    func testIsVisibleMoreSpecificOverrideWinsOverAncestor() {
        let overrides: [FolderVisibilityKey: Bool] = [
            FolderVisibilityKey(rootId: 1, relativePath: "マスコット"): false,
            FolderVisibilityKey(rootId: 1, relativePath: "マスコット/オレンジChibi"): true
        ]
        XCTAssertTrue(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/オレンジChibi", overrides: overrides))
        // 兄弟フォルダは祖先の設定(false)をそのまま継承する。
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/青Chibi", overrides: overrides))
    }

    func testIsVisibleDoesNotLeakAcrossRoots() {
        let overrides: [FolderVisibilityKey: Bool] = [FolderVisibilityKey(rootId: 1, relativePath: ""): false]
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "", overrides: overrides))
        XCTAssertTrue(FolderVisibilityResolver.isVisible(rootId: 2, relativePath: "", overrides: overrides))
    }

    /// 再スキャンで後から見つかった新規サブフォルダも、祖先の設定を自動的に継承することの確認
    /// (カスケード書き込み方式だと発生する「非表示フォルダ配下の新規フォルダがデフォルト表示される」
    /// 問題を、祖先探索方式では設計時点で回避している、という詳細設計の主張を固定する)。
    func testNewlyDiscoveredFolderUnderHiddenAncestorInheritsHiddenState() {
        let overrides: [FolderVisibilityKey: Bool] = [FolderVisibilityKey(rootId: 1, relativePath: "旧デザイン検証"): false]
        // "旧デザイン検証/v2"は overrides 構築時点では存在しなかった、再スキャンで新規に見つかったフォルダという想定。
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "旧デザイン検証/v2", overrides: overrides))
    }

    // MARK: - FolderVisibilityResolver.checkState

    func testCheckStateIsOnWhenNothingOverridden() {
        let tree = FolderTreeBuilder.build(
            images: [
                makeImage(id: 1, path: "/tmp/検証/マスコット/オレンジChibi/1.png"),
                makeImage(id: 2, path: "/tmp/検証/マスコット/青Chibi/2.png")
            ],
            root: root
        )
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: tree, rootId: 1, overrides: [:]), .on)
    }

    func testCheckStateIsOffWhenRootExplicitlyDisabled() {
        let tree = FolderTreeBuilder.build(
            images: [makeImage(id: 1, path: "/tmp/検証/マスコット/1.png")],
            root: root
        )
        let overrides: [FolderVisibilityKey: Bool] = [FolderVisibilityKey(rootId: 1, relativePath: ""): false]
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: tree, rootId: 1, overrides: overrides), .off)
    }

    func testCheckStateIsMixedWhenOnlyOneChildDisabled() {
        let images = [
            makeImage(id: 1, path: "/tmp/検証/マスコット/オレンジChibi/1.png"),
            makeImage(id: 2, path: "/tmp/検証/マスコット/青Chibi/2.png")
        ]
        let tree = FolderTreeBuilder.build(images: images, root: root)
        let mascot = tree.children[0]
        let overrides: [FolderVisibilityKey: Bool] = [
            FolderVisibilityKey(rootId: 1, relativePath: "マスコット/青Chibi"): false
        ]
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: mascot, rootId: 1, overrides: overrides), .mixed)
        // ルート全体としても、配下に非表示のノードが混ざっているので中間状態になる。
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: tree, rootId: 1, overrides: overrides), .mixed)
    }

    // MARK: - FolderVisibilityResolver.togglingVisibility（レビュー指摘で修正した書き込みロジック）

    /// 子を個別にOFFにした後、親を再トグルして「全部見せる」に戻す操作が実際に機能することの確認
    /// （レビューで発見された不具合：旧実装は対象ノード1件だけを書き込んでいたため、子の個別設定に
    /// 阻まれて親が`.mixed`のまま動かなくなっていた）。
    func testTogglingParentAfterHidingChildActuallyShowsEverythingAgain() {
        let images = [
            makeImage(id: 1, path: "/tmp/検証/マスコット/オレンジChibi/1.png"),
            makeImage(id: 2, path: "/tmp/検証/マスコット/青Chibi/2.png")
        ]
        let tree = FolderTreeBuilder.build(images: images, root: root)
        let mascot = tree.children[0]
        let blue = mascot.children.first { $0.name == "青Chibi" }!

        // 1. 青Chibiだけを個別にOFF。
        var overrides: [FolderVisibilityKey: Bool] = [:]
        overrides = FolderVisibilityResolver.togglingVisibility(false, of: blue, rootId: 1, in: overrides)
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: mascot, rootId: 1, overrides: overrides), .mixed)

        // 2. マスコット全体を「全部隠す」にトグル（=タップ時点でmixedだったのでfalseを書く想定）。
        overrides = FolderVisibilityResolver.togglingVisibility(false, of: mascot, rootId: 1, in: overrides)
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: mascot, rootId: 1, overrides: overrides), .off)
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/青Chibi", overrides: overrides))
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/オレンジChibi", overrides: overrides))

        // 3. もう一度マスコット全体を「全部見せる」にトグル。配下の青Chibiの個別OFFは消えているはず。
        overrides = FolderVisibilityResolver.togglingVisibility(true, of: mascot, rootId: 1, in: overrides)
        XCTAssertEqual(FolderVisibilityResolver.checkState(for: mascot, rootId: 1, overrides: overrides), .on)
        XCTAssertTrue(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/青Chibi", overrides: overrides))
    }

    /// 子だけをトグルした場合、兄弟や親には一切影響しないことの確認。
    func testTogglingChildDoesNotAffectSiblingsOrParent() {
        let images = [
            makeImage(id: 1, path: "/tmp/検証/マスコット/オレンジChibi/1.png"),
            makeImage(id: 2, path: "/tmp/検証/マスコット/青Chibi/2.png")
        ]
        let tree = FolderTreeBuilder.build(images: images, root: root)
        let mascot = tree.children[0]
        let blue = mascot.children.first { $0.name == "青Chibi" }!

        let overrides = FolderVisibilityResolver.togglingVisibility(false, of: blue, rootId: 1, in: [:])
        XCTAssertFalse(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/青Chibi", overrides: overrides))
        XCTAssertTrue(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "マスコット/オレンジChibi", overrides: overrides))
        XCTAssertTrue(FolderVisibilityResolver.isVisible(rootId: 1, relativePath: "", overrides: overrides))
    }

    // MARK: - FolderVisibilityResolver.isImageVisible（ImageFilterと`analyzePromptCandidates`の共通ロジック）

    func testIsImageVisibleExcludesImageWhenRootIsUnknown() {
        let image = makeImage(id: 1, rootId: 99, path: "/tmp/検証/a.png")
        XCTAssertFalse(FolderVisibilityResolver.isImageVisible(image, rootPaths: [:], overrides: [:]))
    }

    func testIsImageVisibleRespectsFolderOverride() {
        let image = makeImage(id: 1, rootId: 1, path: "/tmp/検証/マスコット/1.png")
        let overrides: [FolderVisibilityKey: Bool] = [FolderVisibilityKey(rootId: 1, relativePath: "マスコット"): false]
        XCTAssertFalse(FolderVisibilityResolver.isImageVisible(image, rootPaths: [1: "/tmp/検証"], overrides: overrides))
    }
}
