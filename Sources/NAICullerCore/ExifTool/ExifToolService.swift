import Foundation

/// 1枚の画像からExifTool経由で読み取ったメタデータ。
public struct ExifMetadata: Equatable, Sendable {
    /// PNG:Description（プロンプト本文、プレーンテキスト）。読めなければnil。
    public var promptDescription: String?
    public var width: Int?
    public var height: Int?
    /// PNG:Software。"NovelAI"ならNovelAI生成画像と判定できる。
    public var software: String?
    /// XMP:Subject（本アプリが書き込んだタグ名の一覧）。
    public var tagNames: [String]

    public init(promptDescription: String?, width: Int?, height: Int?, software: String?, tagNames: [String]) {
        self.promptDescription = promptDescription
        self.width = width
        self.height = height
        self.software = software
        self.tagNames = tagNames
    }
}

/// ExifTool経由のメタデータ読み書きの抽象。ScanService等がこのプロトコルに依存することで、
/// テストでは実プロセスを起動しないフェイク実装に差し替えられる
/// （例：ScanServiceTestsで「変更のないファイルはreadMetadataが呼ばれない」ことを呼び出し回数で検証する）。
public protocol ExifMetadataReading: AnyObject {
    func readMetadata(path: String) throws -> ExifMetadata
    func addTag(_ name: String, to path: String) throws
    func removeTag(_ name: String, from path: String) throws
}

/// ExifToolの高レベルAPI。読み込み（PNG:Description等）・タグの読み書き（XMP:Subject）を提供する。
///
/// タグの正データは画像ファイル側に持たせる方針のため、XMP-dc:Subject（キーワードの
/// 複数値リストに対応したフィールド）に書き込む。NovelAIが生成時に書き込む
/// PNG:Description / PNG:Commentとは別の名前空間なので衝突しない（詳細設計 6章）。
/// 実データ検証済み：`-XMP-dc:Subject+=`/`-=`で追加削除でき、値が1件なら文字列、
/// 複数件ならJSON配列として`-j`出力に現れる（`stringList`で正規化する）。
public final class ExifToolService: ExifMetadataReading {
    public struct ServiceError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
    }

    private let process: ExifToolProcess
    public let executablePath: String

    public init(executableURL: URL) throws {
        self.executablePath = executableURL.path
        self.process = try ExifToolProcess(executableURL: executableURL)
    }

    /// 起動時にExifToolバイナリを探す。見つからなければnilを返す。
    /// 呼び出し側（アプリ起動処理）はnilの場合モーダルダイアログで
    /// `brew install exiftool`を案内し、スキャン/タグ付け機能をグレーアウトする（詳細設計 5章）。
    public static func locateExecutable(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let wellKnownCandidates = [
            "/opt/homebrew/bin/exiftool",  // Apple Silicon Homebrew
            "/usr/local/bin/exiftool"       // Intel Homebrew
        ]
        for candidate in wellKnownCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/exiftool"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    public func close() {
        process.close()
    }

    /// PNG:Description（プロンプト本文）・画像サイズ・XMP:Subject（アプリのタグ）を読む。
    public func readMetadata(path: String) throws -> ExifMetadata {
        let output = try process.run(["-j", "-G", path])
        guard let json = Self.parseFirstObject(from: output) else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError(message: "exiftoolの出力を解析できなかった: \(trimmed)")
        }
        return ExifMetadata(
            promptDescription: json["PNG:Description"] as? String,
            width: (json["PNG:ImageWidth"] as? NSNumber)?.intValue,
            height: (json["PNG:ImageHeight"] as? NSNumber)?.intValue,
            software: json["PNG:Software"] as? String,
            tagNames: Self.stringList(json["XMP:Subject"])
        )
    }

    /// タグ1件をXMP:Subjectへ追加する。
    public func addTag(_ name: String, to path: String) throws {
        let output = try process.run(["-XMP-dc:Subject+=\(name)", "-overwrite_original", path])
        try Self.assertWriteSucceeded(output)
    }

    /// タグ1件をXMP:Subjectから削除する。
    public func removeTag(_ name: String, from path: String) throws {
        let output = try process.run(["-XMP-dc:Subject-=\(name)", "-overwrite_original", path])
        try Self.assertWriteSucceeded(output)
    }

    /// 成功時は "1 image files updated" のようなサマリ行のみが返る。
    /// 失敗時（権限なし・ファイル破損等）は"Error: ..."が含まれ、更新件数が0件になる。
    private static func assertWriteSucceeded(_ output: String) throws {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("Error:") || trimmed.contains("0 image files updated") {
            throw ServiceError(message: trimmed.isEmpty ? "exiftoolの書き込みが失敗した（詳細不明）" : trimmed)
        }
    }

    private static func parseFirstObject(from output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8) else { return nil }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.first
    }

    /// exiftoolの`-j`出力はリストフィールドが「値が1つなら文字列、複数なら配列」で返るため正規化する。
    private static func stringList(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let single = value as? String { return [single] }
        return []
    }
}
