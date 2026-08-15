import Foundation

/// bg-splitterが選べるAIモデルの一覧（`bgsplit.py`の`MODEL_CHOICES`と1対1対応）。
/// Settings画面のモデル選択・右クリックメニューのサブメニュー・ヘルプ画面の説明、
/// 全部この配列を単一のソースとして参照する（説明文の二重管理を避けるため）。
public struct BgSplitterModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let usageHint: String
}

public extension BgSplitterModel {
    static let all: [BgSplitterModel] = [
        BgSplitterModel(id: "u2net", displayName: "u2net（汎用）", usageHint: "迷ったらまずこれ。写真・イラスト問わず使える汎用モデル。"),
        BgSplitterModel(id: "u2net_human_seg", displayName: "u2net_human_seg（人物）", usageHint: "人物写真に特化したモデル。実写人物の切り抜き精度が高い。"),
        BgSplitterModel(id: "isnet-general-use", displayName: "isnet-general-use（高精度汎用）", usageHint: "u2netより高精度な汎用モデル。処理はやや重め。"),
        BgSplitterModel(id: "isnet-anime", displayName: "isnet-anime（アニメ・イラスト）", usageHint: "アニメ・イラスト向け。NovelAI生成物はまずこれでOK（既定モデル）。"),
        BgSplitterModel(id: "silueta", displayName: "silueta（軽量・高速）", usageHint: "精度より速度優先の軽量モデル。"),
    ]

    static let defaultModelId = "isnet-anime"
}

/// `~/Dev/tools/bg-splitter`（背景透過+シート画像グリッド分割の自作Python CLI）を
/// サブプロセスとして呼び出すラッパー。ExifToolServiceと違い、これは自分専用の
/// 未公開ツールで`brew`等の一般配布はしていないため、他のNAICullerユーザーの環境では
/// 見つからず`bgSplitterAvailable`がfalseのまま機能自体が非表示になるだけで、
/// アプリ本体の動作には影響しない設計（Settings画面から任意のパスを指定することもできる）。
public final class BgSplitterService {
    public struct ServiceError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
    }

    public let pythonExecutablePath: String
    public let scriptPath: String

    public init(pythonExecutableURL: URL, scriptURL: URL) {
        self.pythonExecutablePath = pythonExecutableURL.path
        self.scriptPath = scriptURL.path
    }

    /// `<root>/venv/bin/python3`と`<root>/bgsplit.py`が両方揃っているか確認する。
    /// `customRoot`未指定時は`~/Dev/tools/bg-splitter`を見る（Settings画面で個別パスを
    /// 設定していない場合の既定値）。見つからなければnil（呼び出し側はbgSplitterAvailable=falseに
    /// して機能を非表示にする）。
    public static func locate(
        customRoot: URL? = nil,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (python: URL, script: URL)? {
        let root = customRoot ?? homeDirectory.appendingPathComponent("Dev/tools/bg-splitter")
        let python = root.appendingPathComponent("venv/bin/python3")
        let script = root.appendingPathComponent("bgsplit.py")
        guard fileManager.isExecutableFile(atPath: python.path),
              fileManager.fileExists(atPath: script.path) else {
            return nil
        }
        return (python, script)
    }

    /// 背景透過を実行する。`outputDirectory`未指定時は`bgsplit.py`側の既定命名規則
    /// （`<元ファイル名>_nobg.png`を元画像と同じフォルダに書き出す）を再現する形で
    /// こちら側で出力パスを組み立て、`-o`に明示的に渡す（bgsplit.py単体では省略時に
    /// 同じ場所へ既定名で書くが、Swift側からは常に完成パスを渡して結果を確実に把握する）。
    @discardableResult
    public func removeBackground(imagePath: String, model: String? = nil, outputDirectory: URL? = nil) throws -> String {
        let url = URL(fileURLWithPath: imagePath)
        let stem = url.deletingPathExtension().lastPathComponent
        let baseDir = outputDirectory ?? url.deletingLastPathComponent()
        let outputPath = baseDir.appendingPathComponent("\(stem)_nobg.png")

        var args = ["remove", imagePath, "-o", outputPath.path]
        if let model { args += ["-m", model] }
        try run(args)
        return outputPath.path
    }

    /// シート画像のグリッド分割+背景透過を実行する。`outputDirectory`未指定時は
    /// `bgsplit.py`側の既定命名規則（`<元ファイル名>_split/`フォルダを元画像と同じ場所に作る）
    /// に従うパスを組み立てて`-o`に渡す。
    @discardableResult
    public func splitSheet(imagePath: String, model: String? = nil, outputDirectory: URL? = nil) throws -> String {
        let url = URL(fileURLWithPath: imagePath)
        let stem = url.deletingPathExtension().lastPathComponent
        let outputDir = outputDirectory ?? url.deletingLastPathComponent().appendingPathComponent("\(stem)_split")

        var args = ["split", imagePath, "-o", outputDir.path]
        if let model { args += ["-m", model] }
        try run(args)
        return outputDir.path
    }

    /// 標準出力は捨て（進捗の%表示等をGUI側で使う予定が無いため）、標準エラーだけ
    /// readabilityHandlerで非同期に読み進める。`waitUntilExit()`の後にまとめて読もうとすると、
    /// 出力がOSのパイプバッファ(64KB程度)を超えた時点で子プロセスがwrite()でブロックし、
    /// 親はwaitUntilExit()でブロックしたままという典型的なデッドロックになるため避ける
    /// （ExifToolProcess.swiftの`-execute`待ちと違い、こちらは1回限りの実行なので都度Processを生成する）。
    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutablePath)
        process.arguments = [scriptPath] + arguments
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrQueue = DispatchQueue(label: "com.kanipotato.NAICuller.BgSplitterService.stderr")
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stderrQueue.sync { stderrData.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ServiceError(message: "bg-splitterを起動できなかった: \(error)")
        }
        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let errText = stderrQueue.sync { String(data: stderrData, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (errText?.isEmpty == false ? errText : nil)
                ?? "bg-splitterの実行に失敗した(終了コード\(process.terminationStatus))"
            throw ServiceError(message: message)
        }
    }
}
