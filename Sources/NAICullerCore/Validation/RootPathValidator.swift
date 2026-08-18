import Foundation

/// ルートディレクトリ追加時のバリデーション（詳細設計 2章）。
/// 「存在するディレクトリか」「既存ルートと重複／包含関係でないか」を判定する。
public enum RootPathValidator {
    public enum Failure: Equatable, Sendable {
        case notExisting
        case notDirectory
        /// 既存ルートと完全一致、または一方が他方の祖先ディレクトリになっている。
        case duplicateOrContained(existingPath: String)

        /// ユーザーに見せる説明文。
        ///
        /// 元はこの`switch`が`MainWindowView`と`SettingsView`にそれぞれ
        /// `describe(_:)`として**同一の実装で重複**しており、片方の文言だけ直して
        /// もう片方が古いまま残る形になっていた。失敗ケースを持つ側に文言を寄せて
        /// 一元化する（ケースを増やしたときの追従漏れも防げる）。
        public var message: String {
            switch self {
            case .notExisting:
                return "指定したパスが存在しません。"
            case .notDirectory:
                return "指定したパスはディレクトリではありません。"
            case .duplicateOrContained(let existingPath):
                return "既存のルート「\(existingPath)」と重複しているか、包含関係にあります。"
            }
        }
    }

    /// - Parameters:
    ///   - candidatePath: 追加しようとしているパス（標準化前でよい）。
    ///   - existingPaths: 登録済みルートのパス一覧。
    ///   - fileExists: テスト容易性のため注入可能にしたファイル存在確認クロージャ。
    public static func validate(
        candidatePath: String,
        existingPaths: [String],
        fileExists: (String) -> (exists: Bool, isDirectory: Bool) = { path in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return (exists, isDir.boolValue)
        }
    ) -> Failure? {
        let result = fileExists(candidatePath)
        guard result.exists else { return .notExisting }
        guard result.isDirectory else { return .notDirectory }

        let candidate = standardizedComponents(candidatePath)
        for existing in existingPaths {
            let existingComponents = standardizedComponents(existing)
            if candidate == existingComponents
                || isAncestor(existingComponents, of: candidate)
                || isAncestor(candidate, of: existingComponents) {
                return .duplicateOrContained(existingPath: existing)
            }
        }
        return nil
    }

    private static func standardizedComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }

    /// `ancestor`が`descendant`の祖先ディレクトリ（完全一致は含まない）かどうか。
    private static func isAncestor(_ ancestor: [String], of descendant: [String]) -> Bool {
        guard ancestor.count < descendant.count else { return false }
        return Array(descendant.prefix(ancestor.count)) == ancestor
    }
}
