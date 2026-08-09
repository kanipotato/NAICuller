import Foundation

/// 監視対象のルートディレクトリ（`roots`テーブル1行に対応）。
public struct Root: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var path: String
    public var addedAt: Date

    public init(id: Int64, path: String, addedAt: Date) {
        self.id = id
        self.path = path
        self.addedAt = addedAt
    }
}
