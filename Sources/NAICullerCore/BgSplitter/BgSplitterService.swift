import Foundation

/// `~/Dev/tools/bg-splitter`（背景透過+シート画像グリッド分割の自作Python CLI）を
/// サブプロセスとして呼び出すラッパー。ExifToolServiceと違い、これは自分専用の
/// 未公開ツールで`brew`等の一般配布はしていないため、固定パス1箇所だけを確認する
/// （他のNAICullerユーザーの環境では`bgSplitterAvailable`がfalseのまま機能がグレーアウトするだけで、
/// アプリ本体の動作には影響しない設計）。
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

    /// `~/Dev/tools/bg-splitter/venv/bin/python3`と`bgsplit.py`が両方揃っているか確認する。
    /// 見つからなければnil（呼び出し側はbgSplitterAvailable=falseにしてメニューをグレーアウトする）。
    public static func locate(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (python: URL, script: URL)? {
        let root = homeDirectory.appendingPathComponent("Dev/tools/bg-splitter")
        let python = root.appendingPathComponent("venv/bin/python3")
        let script = root.appendingPathComponent("bgsplit.py")
        guard fileManager.isExecutableFile(atPath: python.path),
              fileManager.fileExists(atPath: script.path) else {
            return nil
        }
        return (python, script)
    }

    /// 背景透過を実行する。出力先は`bgsplit.py`側の既定命名規則
    /// （`<元ファイル名>_nobg.png`を元画像と同じフォルダに書き出す）に従うため、
    /// -oは指定せずそのパスを組み立てて返すだけにしている。
    @discardableResult
    public func removeBackground(imagePath: String) throws -> String {
        try run(["remove", imagePath])
        let url = URL(fileURLWithPath: imagePath)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(stem)_nobg.png").path
    }

    /// シート画像のグリッド分割+背景透過を実行する。出力先は`bgsplit.py`側の既定命名規則
    /// （`<元ファイル名>_split/`フォルダを元画像と同じ場所に作る）に従う。
    @discardableResult
    public func splitSheet(imagePath: String) throws -> String {
        try run(["split", imagePath])
        let url = URL(fileURLWithPath: imagePath)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(stem)_split").path
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
