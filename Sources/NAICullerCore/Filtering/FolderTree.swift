import Foundation

/// 画像の絶対パスとルートの絶対パスから、ルート配下のディレクトリ相対パスを求める共通ロジック。
/// `FolderTreeBuilder`（ツリー構築）と`ImageFilter`（絞り込み判定）の両方が同じ切り出し方をする必要が
/// あるため、ここに集約して二重実装を避ける。
public enum FolderPathUtility {
    /// - Returns: 画像ファイルがrootPath直下にあるディレクトリの相対パス（`""`はルート直下自身）。
    ///   `imagePath`が`rootPath`配下でない場合（想定外のデータ）は`""`を返す（ルート直下扱いにフォールバック）。
    public static func relativeDirectory(imagePath: String, rootPath: String) -> String {
        let normalizedRoot = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        guard imagePath.hasPrefix(normalizedRoot) else { return "" }
        var remainder = String(imagePath.dropFirst(normalizedRoot.count))
        // 境界チェック：`hasPrefix`だけだと`/a/b`が`/a/bc/x.png`にもマッチしてしまう
        // （レビュー指摘：単なる文字列prefix一致で、実際に配下にあるとは限らない）。
        // 次の文字が区切り文字であることまで確認して、真に配下にあるパスだけを通す。
        guard remainder.hasPrefix("/") else { return "" }
        remainder.removeFirst()
        var components = remainder.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return "" }
        components.removeLast() // ファイル名部分を落とす
        return components.joined(separator: "/")
    }
}

/// ルート配下のディレクトリ階層を表すツリーの1ノード（サイドバーのフォルダツリー表示用）。
/// DBには保持せず、`images`の一覧から都度メモリ上に構築する（詳細設計：DBスキーマ変更なし）。
public struct FolderNode: Identifiable, Equatable, Sendable {
    /// `relativePath`をそのままidとして使う（ルート内で一意）。
    public var id: String
    public var name: String
    /// ルートpathからの相対パス（`""`はルート自身）。
    public var relativePath: String
    public var children: [FolderNode]
    /// 自身の直下＋配下すべてに含まれる画像枚数の合計（表示用）。
    public var imageCount: Int

    public init(id: String, name: String, relativePath: String, children: [FolderNode], imageCount: Int) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.children = children
        self.imageCount = imageCount
    }
}

public enum FolderTreeBuilder {
    /// 指定ルート配下の画像だけからディレクトリツリーを構築する。
    /// 画像を1枚も含まないフォルダはノードとして作られない（自身・配下ともに画像がある経路のみ辿るため）。
    public static func build(images: [ImageRecord], root: Root) -> FolderNode {
        final class MutableNode {
            let name: String
            let relativePath: String
            var children: [String: MutableNode] = [:]
            var imageCount = 0
            init(name: String, relativePath: String) {
                self.name = name
                self.relativePath = relativePath
            }
        }

        let rootNode = MutableNode(name: (root.path as NSString).lastPathComponent, relativePath: "")

        for image in images where image.rootId == root.id {
            rootNode.imageCount += 1
            let relativeDir = FolderPathUtility.relativeDirectory(imagePath: image.path, rootPath: root.path)
            guard !relativeDir.isEmpty else { continue }
            var current = rootNode
            var pathSoFar: [String] = []
            for component in relativeDir.split(separator: "/").map(String.init) {
                pathSoFar.append(component)
                if let existing = current.children[component] {
                    existing.imageCount += 1
                    current = existing
                } else {
                    let newNode = MutableNode(name: component, relativePath: pathSoFar.joined(separator: "/"))
                    newNode.imageCount = 1
                    current.children[component] = newNode
                    current = newNode
                }
            }
        }

        func convert(_ node: MutableNode) -> FolderNode {
            let sortedChildren = node.children.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return FolderNode(
                id: node.relativePath,
                name: node.name,
                relativePath: node.relativePath,
                children: sortedChildren.map(convert),
                imageCount: node.imageCount
            )
        }
        return convert(rootNode)
    }
}

/// フォルダツリーの表示/絞り込み設定1件を一意に指すキー。
public struct FolderVisibilityKey: Hashable, Sendable {
    public var rootId: Int64
    public var relativePath: String

    public init(rootId: Int64, relativePath: String) {
        self.rootId = rootId
        self.relativePath = relativePath
    }
}

/// ツリー表示用のチェック状態（サイドバーの3状態チェックボックスに対応）。
public enum FolderCheckState: Equatable, Sendable {
    case on
    case off
    case mixed
}

/// フォルダの表示/非表示を判定するロジック。DBにもAppModelにも依存しない純粋関数。
///
/// 読み取り方式：「最も近い祖先の明示設定が勝つ」（CSS詳細度と同じ考え方）。これにより、
/// 再スキャンで後から見つかった新規サブフォルダも、祖先の設定を自動的に継承する
/// （新規フォルダには`overrides`にエントリが無いので、祖先の設定にそのまま従う）。
///
/// 書き込み方式（`togglingVisibility`）：対象ノード配下（自身含む）の既存の個別設定を全て消してから、
/// 対象ノード自身にだけ新しい設定を書く（配下への実カスケード書き込みではなく「配下の上書きを消して
/// 祖先継承に戻す」ことで、結果的に配下全部が新しい状態に揃って見える）。
///
/// 【設計変更の経緯】当初は対象ノード1件分だけを書き込み、配下の個別設定は一切触らない方式だった
/// （「子の個別設定を親の再トグルで壊さない」ことを狙った意図的な設計）。しかしレビューで、この方式だと
/// 「子を個別にOFFにした後、親を再トグルして"全部見せる/全部隠す"に戻したい」という最も基本的な操作が
/// 不可能になる（親のON/OFFが子の個別設定に阻まれて`.mixed`のまま動かなくなる）ことが判明したため、
/// 現在の「配下の上書きを消してから自身に書く」方式に改めた。この方式でも、後から見つかった新規サブ
/// フォルダが祖先の設定を継承する性質（読み取り方式の恩恵）はそのまま両立する。
public enum FolderVisibilityResolver {
    /// `relativePath`から根に向かって最も近い明示的な設定を探して返す。無ければ`true`（デフォルト表示）。
    public static func isVisible(rootId: Int64, relativePath: String, overrides: [FolderVisibilityKey: Bool]) -> Bool {
        var components = relativePath.isEmpty ? [] : relativePath.split(separator: "/").map(String.init)
        while true {
            let key = FolderVisibilityKey(rootId: rootId, relativePath: components.joined(separator: "/"))
            if let explicit = overrides[key] { return explicit }
            guard !components.isEmpty else { break }
            components.removeLast()
        }
        return true
    }

    /// ノード自身＋配下すべての実効表示状態から、ツリー表示用のチェック状態（ON/OFF/中間）を求める。
    /// 保存はせず、描画のたびに計算する（詳細設計6章）。
    public static func checkState(for node: FolderNode, rootId: Int64, overrides: [FolderVisibilityKey: Bool]) -> FolderCheckState {
        var states = Set<Bool>()
        func collect(_ n: FolderNode) {
            states.insert(isVisible(rootId: rootId, relativePath: n.relativePath, overrides: overrides))
            for child in n.children { collect(child) }
        }
        collect(node)
        if states == [true] { return .on }
        if states == [false] { return .off }
        return .mixed
    }

    /// フォルダツリーのチェック操作を適用した、新しい`overrides`を返す（純粋関数）。
    /// 対象ノード配下（自身含む）の既存の個別設定を全て消してから、対象ノード自身にだけ
    /// 新しい設定を書く。詳細は本enumのドキュメント参照。
    public static func togglingVisibility(
        _ isOn: Bool,
        of node: FolderNode,
        rootId: Int64,
        in overrides: [FolderVisibilityKey: Bool]
    ) -> [FolderVisibilityKey: Bool] {
        var result = overrides
        func clearSubtree(_ n: FolderNode) {
            result.removeValue(forKey: FolderVisibilityKey(rootId: rootId, relativePath: n.relativePath))
            for child in n.children { clearSubtree(child) }
        }
        clearSubtree(node)
        result[FolderVisibilityKey(rootId: rootId, relativePath: node.relativePath)] = isOn
        return result
    }

    /// 画像1件が、指定の`rootPaths`/`overrides`のもとで表示対象かどうかを判定する。
    /// `ImageFilter.apply`と`AppModel.analyzePromptCandidates`の両方が同じ3段階の判定
    /// （rootPath解決→相対ディレクトリ抽出→表示判定）を必要とするため、二重実装を避けるためここに集約する。
    public static func isImageVisible(_ image: ImageRecord, rootPaths: [Int64: String], overrides: [FolderVisibilityKey: Bool]) -> Bool {
        guard let rootPath = rootPaths[image.rootId] else { return false }
        let relativeDir = FolderPathUtility.relativeDirectory(imagePath: image.path, rootPath: rootPath)
        return isVisible(rootId: image.rootId, relativePath: relativeDir, overrides: overrides)
    }
}
