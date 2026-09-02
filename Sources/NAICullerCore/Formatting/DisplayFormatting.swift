import Foundation

/// 右パネルに出す値の整形。
///
/// 元は`DetailPanelView`のprivateメンバとして、SwiftUIのView本体に混ざって置かれていた
/// （@MainActor + View依存でテスト不能）。入力→出力が閉じている整形処理なのでCore層へ出す。
///
/// `DetailPanelView`自体のView階層は変更していない。あのファイルにはHSplitViewの
/// ペイン幅計算にまつわる不具合を実機で踏んで直した経緯がコメントに詳しく残っており
/// （ルートViewの同一性を変えない／選択の有無でサブツリー構造を入れ替えない）、
/// セクションを子Viewへ切り出すとView階層が1段増えて同種の再発を招きうるため。
public enum DisplayFormatting {
    /// 生成パラメータの数値。整数なら小数点以下を出さず、そうでなければ2桁で丸める。
    ///
    /// cfg や LoRA の強度は `7.0` のように整数値になることが多く、そのまま出すと
    /// `7.00` と冗長になる。一方 `7.5` は精度を落とさず出したいので出し分ける。
    public static func parameterValue(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }

    /// ファイルサイズ（Finderと同じ10進表記）。
    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 画像の寸法。幅か高さが未取得ならnil（呼び出し側は行ごと出さない）。
    public static func imageDimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    /// 日時。ロケール・タイムゾーンは表示環境に従うが、テストのために注入できるようにする。
    public static func dateTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
