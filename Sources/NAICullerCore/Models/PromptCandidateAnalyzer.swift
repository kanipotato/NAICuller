import Foundation

/// プロンプト候補絞り込みで表示する1件（語句と、その語句を含む画像の枚数）。
public struct PromptCandidate: Identifiable, Equatable, Sendable {
    public var id: String { term }
    public let term: String
    public let count: Int

    public init(term: String, count: Int) {
        self.term = term
        self.count = count
    }
}

/// NovelAIのプロンプトは基本的に`1girl, chibi, orange hair, ...`のような
/// カンマ区切りタグ列であることを前提に、頻出語句を候補として集計する
/// （実際に使ってみてのフィードバックで追加：ルート内にどんなプロンプトが
/// あるか事前に把握していないと、プロンプト検索欄に何を打てばいいか分からない）。
public enum PromptCandidateAnalyzer {
    /// プロンプト本文をカンマ区切りタグに分解する（絞り込み側のマッチ判定と候補集計の
    /// 双方で同じ分解ロジックを使うための共通関数）。
    public static func terms(in prompt: String) -> Set<String> {
        Set(
            prompt.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// プロンプト群から候補語句を集計する。`count`は「その語句を含むプロンプトの数」
    /// （同一プロンプト内で同じ語句が複数回登場しても1件として数える）。
    ///
    /// - Parameters:
    ///   - minimumCount: これ未満の出現数の語句は候補から除く（仮置き既定値2）。
    ///     シード値のように1枚にしか出現しない語句をノイズとして間引くため。
    ///   - limit: 候補の最大件数（仮置き既定値200）。出現数の多い順、同数ならアルファベット順。
    public static func analyze(prompts: [String], minimumCount: Int = 2, limit: Int = 200) -> [PromptCandidate] {
        var counts: [String: Int] = [:]
        for prompt in prompts {
            for term in terms(in: prompt) {
                counts[term, default: 0] += 1
            }
        }
        let candidates: [PromptCandidate] = counts
            .filter { $0.value >= minimumCount }
            .map { PromptCandidate(term: $0.key, count: $0.value) }
        let sorted = candidates.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.term < rhs.term : lhs.count > rhs.count
        }
        return Array(sorted.prefix(limit))
    }
}
