import Foundation

/// 複数選択時の一括タグ付けで「付けるのか外すのか」「どの画像を触るのか」を決めた結果。
///
/// Photos.app等と同じトライステート方式：選択中の全画像が既にタグを持っていれば全て外す、
/// そうでなければ（1件でも未タグがあれば）全てに付ける。
///
/// 元は`AppModel.toggleTag(tagId:on:[ImageRecord])`の中に直書きされていた。
/// ExifTool書き込みという副作用の手前にある「判断」だけを取り出せば純粋関数になり、
/// 「全部付いている時だけ外す」「既にその状態の画像は触らない」といった仕様を
/// 単体で固定できるため切り出した。
public struct BatchTagToggle: Equatable, Sendable {
    /// true なら付ける、false なら外す。
    public let shouldAdd: Bool
    /// 実際に書き込みが必要な画像だけ（既に目的の状態のものは含まない）。
    public let targets: [ImageRecord]

    public init(shouldAdd: Bool, targets: [ImageRecord]) {
        self.shouldAdd = shouldAdd
        self.targets = targets
    }

    /// `targets`が空なら何もする必要がない（呼び出し側は早期returnしてよい）。
    public var isNoOp: Bool { targets.isEmpty }

    /// - Parameters:
    ///   - imageTagIds: 画像ID→タグIDの対応表。未収録の画像は「タグ無し」として扱う。
    public static func plan(
        images: [ImageRecord],
        tagId: Int64,
        imageTagIds: [Int64: Set<Int64>]
    ) -> BatchTagToggle {
        func isTagged(_ image: ImageRecord) -> Bool {
            imageTagIds[image.id]?.contains(tagId) ?? false
        }
        // 空配列に対する allSatisfy は true（＝「全部付いている」扱い）になるが、
        // targetsも空になるのでisNoOpで弾かれる。
        let allTagged = images.allSatisfy(isTagged)
        let shouldAdd = !allTagged
        let targets = images.filter { shouldAdd ? !isTagged($0) : isTagged($0) }
        return BatchTagToggle(shouldAdd: shouldAdd, targets: targets)
    }
}
