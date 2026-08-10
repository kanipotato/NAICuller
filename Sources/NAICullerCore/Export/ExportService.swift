import Foundation

/// エクスポート可能な項目（詳細設計 4-3章：「項目名→抽出関数」のマップとして実装し、
/// 将来の項目追加を前提にする）。
public enum ExportFieldKind: String, CaseIterable, Identifiable, Sendable {
    case filePath
    case prompt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .filePath: return "ファイルパス"
        case .prompt: return "プロンプト"
        }
    }
}

/// JSONエクスポート処理。ファイル選択（NSSavePanel）はAppKit層の責務のため、
/// このサービスはData生成までを担当し、書き出し先URLへの実書き込みも提供する。
public final class ExportService {
    public struct ExportError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
    }

    /// 項目名→抽出関数のマップ。項目追加時はここにケースと抽出関数を1組足すだけでよい。
    private static let extractors: [ExportFieldKind: (ImageRecord) -> Any?] = [
        .filePath: { record in record.path },
        .prompt: { record in record.promptCache }
    ]

    public init() {}

    /// 選択画像・出力項目チェックボックスの状態からJSON配列のDataを構築する。
    /// `filePath`は絶対パス、`prompt`はprompt_cacheから抽出（無ければJSON null）。
    public func buildExportData(images: [ImageRecord], fields: [ExportFieldKind]) throws -> Data {
        guard !fields.isEmpty else {
            throw ExportError(message: "出力項目が1つも選択されていない")
        }
        var array: [[String: Any]] = []
        array.reserveCapacity(images.count)
        for image in images {
            var object: [String: Any] = [:]
            for field in fields {
                let value = Self.extractors[field]?(image) ?? nil
                object[field.rawValue] = value ?? NSNull()
            }
            array.append(object)
        }
        do {
            return try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw ExportError(message: "JSONへの変換に失敗した: \(error.localizedDescription)")
        }
    }

    /// JSON配列を指定URLへ書き出す。
    public func export(images: [ImageRecord], fields: [ExportFieldKind], to url: URL) throws {
        let data = try buildExportData(images: images, fields: fields)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError(message: "ファイルの書き出しに失敗した: \(error.localizedDescription)")
        }
    }

    /// 初期ファイル名 `novelai-export-YYYYMMDD-HHmmss.json`（詳細設計 4-3章）。
    public static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return "novelai-export-\(formatter.string(from: now)).json"
    }
}
