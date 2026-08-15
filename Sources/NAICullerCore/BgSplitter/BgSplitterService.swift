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

/// `bgsplit.py split`が出力フォルダに書き出す`<元名>_manifest.json`の中身。
/// 元シートの絶対パス・使用モデル・overflow等を記録しており、「この分割をやり直す」機能が
/// 元シート特定とパラメータ復元に使う。出力先が複数の元シートの結果を集める共通フォルダでも、
/// セルのファイル名(`<元名>_r{行}_c{列}.png`)から`<元名>_manifest.json`を一意に導ける。
public struct BgSplitterManifestCell: Codable, Sendable {
    public let row: Int
    public let col: Int
    public let file: String
}

public struct BgSplitterManifest: Codable, Sendable {
    public let source: String
    public let model: String
    public let overflow: Double
    public let pad: Int
    public let alphaThreshold: Int
    public let cells: [BgSplitterManifestCell]

    enum CodingKeys: String, CodingKey {
        case source, model, overflow, pad
        case alphaThreshold = "alpha_threshold"
        case cells
    }
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

    /// ファイル名が分割セルの命名規則(`<元名>_r{行}_c{列}.png`)に一致するか調べ、一致すれば
    /// `<元名>`部分を返す。「この分割をやり直す」メニューを出すかどうかの一次判定に使う。
    public static func splitCellStem(fromFileName fileName: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.+)_r\d+_c\d+\.png$"#) else { return nil }
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let match = regex.firstMatch(in: fileName, range: range),
              let stemRange = Range(match.range(at: 1), in: fileName) else { return nil }
        return String(fileName[stemRange])
    }

    /// 分割セル画像のパスから対応マニフェスト(`<元名>_manifest.json`)を読む。
    /// `manifestDirectory`が指定されていればまずそこを見て、無ければセルと同じフォルダを見る
    /// （`--manifest-dir`を指定せずに書かれた古いマニフェストとの後方互換のため）。
    /// ファイル名が分割セルの規則に合わない、またはどちらにもマニフェストが無い/壊れている場合はnil。
    public static func readManifest(
        forCellImagePath imagePath: String,
        manifestDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> BgSplitterManifest? {
        let url = URL(fileURLWithPath: imagePath)
        guard let stem = splitCellStem(fromFileName: url.lastPathComponent) else { return nil }
        let candidates = [manifestDirectory, url.deletingLastPathComponent()].compactMap { $0 }
        for dir in candidates {
            let manifestURL = dir.appendingPathComponent("\(stem)_manifest.json")
            if let data = fileManager.contents(atPath: manifestURL.path),
               let manifest = try? JSONDecoder().decode(BgSplitterManifest.self, from: data) {
                return manifest
            }
        }
        return nil
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
    public func splitSheet(
        imagePath: String,
        model: String? = nil,
        outputDirectory: URL? = nil,
        overflow: Double? = nil,
        manifestDirectory: URL? = nil
    ) throws -> String {
        let url = URL(fileURLWithPath: imagePath)
        let stem = url.deletingPathExtension().lastPathComponent
        let outputDir = outputDirectory ?? url.deletingLastPathComponent().appendingPathComponent("\(stem)_split")

        var args = ["split", imagePath, "-o", outputDir.path]
        if let model { args += ["-m", model] }
        if let overflow { args += ["--overflow", String(overflow)] }
        if let manifestDirectory { args += ["--manifest-dir", manifestDirectory.path] }
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
        // コードレビュー指摘の修正：readabilityHandlerの最後の発火は非同期で届くため、
        // waitUntilExit()直後にnilにするだけだと、まだ配送されていない末尾チャンクを
        // 取りこぼし、失敗時のエラーメッセージが空になることがあった。子プロセスは
        // 既に終了しているので、ここでEOFまで同期的に読み切ってもデッドロックの
        // 心配はない（デッドロックが起きるのは実行中に読まず待ち続けるケースのみ）。
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrQueue.sync { stderrData.append(remainingStderr) }
        }

        guard process.terminationStatus == 0 else {
            let errText = stderrQueue.sync { String(data: stderrData, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (errText?.isEmpty == false ? errText : nil)
                ?? "bg-splitterの実行に失敗した(終了コード\(process.terminationStatus))"
            throw ServiceError(message: message)
        }
    }
}
