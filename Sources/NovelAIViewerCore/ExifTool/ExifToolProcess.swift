import Foundation

/// exiftoolを`-stay_open True -@ -`で常駐起動し、標準入出力パイプ経由でコマンドを
/// 流し込む自前ラッパー（詳細設計・技術スタック指定：バイナリは同梱せず`brew install exiftool`で
/// ユーザー環境にインストール済み前提、`Process()`で常駐させる）。
///
/// 1万枚超のファイルを1枚ずつ処理するにはプロセス起動コスト（数十ms〜）が無視できないため、
/// `-stay_open`モードで1プロセスを使い回す。
public final class ExifToolProcess {
    public struct ProcessError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let queue = DispatchQueue(label: "com.kanipotato.NovelAIViewer.ExifToolProcess")
    private var buffer = Data()
    private var isRunning = false

    /// `-execute`に対する完了マーカー。デフォルトの"{ready}\n"をそのまま使う
    /// （複数の-execute番号を並行させる必要はなく、呼び出しはqueueで直列化しているため）。
    private static let readyMarker = Data("{ready}\n".utf8)

    public init(executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-stay_open", "True", "-@", "-"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        // 標準エラーは破棄する。書き込み失敗等のエラーメッセージはexiftoolの仕様上
        // 標準出力側（-execute区切りの中）に"Error:"として出るため、そちらだけ見ればよい。
        process.standardError = Pipe()
        process.standardOutput = stdoutPipe
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        try process.run()
        self.isRunning = true
    }

    deinit {
        close()
    }

    /// 常駐プロセスへ引数を1コマンド分渡し、`-execute`終端までの標準出力を文字列で返す。
    /// 呼び出しは内部の直列queueで1コマンドずつ処理されるため、複数スレッドから
    /// 同時に呼んでも安全（並列実行はしない＝1プロセスなので当然の制約）。
    public func run(_ args: [String]) throws -> String {
        try queue.sync {
            guard isRunning else { throw ProcessError(message: "exiftoolプロセスは終了済み") }
            var command = ""
            for arg in args {
                command += arg + "\n"
            }
            command += "-execute\n"
            guard let data = command.data(using: .utf8) else {
                throw ProcessError(message: "コマンドの文字列エンコードに失敗した")
            }
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                isRunning = false
                throw ProcessError(message: "exiftoolへの書き込みに失敗した: \(error)")
            }
            return try readUntilReady()
        }
    }

    /// "{ready}\n"が現れるまで標準出力を読み進める。exiftool側の処理完了を待つポイント。
    private func readUntilReady() throws -> String {
        while true {
            if let range = buffer.range(of: Self.readyMarker) {
                let resultData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: resultData, encoding: .utf8) ?? ""
            }
            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                // パイプがEOF＝プロセスが予期せず終了した。
                isRunning = false
                throw ProcessError(message: "exiftoolプロセスが予期せず終了した")
            }
            buffer.append(chunk)
        }
    }

    /// `-stay_open False`を送って穏当にプロセスを終了させる。アプリ終了時やExifTool未検出時の
    /// 再チェック前に呼ぶ。内部の書き込み・クローズ処理はベストエフォートのため例外は投げない。
    public func close() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            if let data = "-stay_open\nFalse\n".data(using: .utf8) {
                try? stdinHandle.write(contentsOf: data)
            }
            try? stdinHandle.close()
            process.waitUntilExit()
        }
    }
}
