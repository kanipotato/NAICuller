import XCTest
@testable import NAICullerCore

final class PromptCandidateAnalyzerTests: XCTestCase {
    func testTermsSplitsTrimsAndLowercases() {
        let terms = PromptCandidateAnalyzer.terms(in: "1girl, Chibi ,  orange hair,,")
        XCTAssertEqual(terms, ["1girl", "chibi", "orange hair"])
    }

    func testAnalyzeCountsEachTermOncePerPrompt() {
        let prompts = [
            "1girl, chibi, orange hair",
            "1girl, chibi, blue hair",
            "1girl, chibi, chibi, orange hair", // 同一プロンプト内の重複は1回として数える
        ]
        let candidates = PromptCandidateAnalyzer.analyze(prompts: prompts, minimumCount: 1)
        let byTerm = Dictionary(uniqueKeysWithValues: candidates.map { ($0.term, $0.count) })
        XCTAssertEqual(byTerm["1girl"], 3)
        XCTAssertEqual(byTerm["chibi"], 3)
        XCTAssertEqual(byTerm["orange hair"], 2)
        XCTAssertEqual(byTerm["blue hair"], 1)
    }

    func testAnalyzeFiltersByMinimumCount() {
        let prompts = ["a, b", "a, c"]
        let candidates = PromptCandidateAnalyzer.analyze(prompts: prompts, minimumCount: 2)
        XCTAssertEqual(candidates.map(\.term), ["a"])
    }

    func testAnalyzeSortsByCountDescendingThenAlphabetically() {
        let prompts = ["a, b, z", "a, b, y", "a, z"]
        let candidates = PromptCandidateAnalyzer.analyze(prompts: prompts, minimumCount: 1)
        // a:3件, b:2件, z:2件（bとzは同数なのでアルファベット順）, y:1件
        XCTAssertEqual(candidates.map(\.term), ["a", "b", "z", "y"])
    }

    func testAnalyzeRespectsLimit() {
        let prompts = (0..<10).map { "tag\($0)" }
        let candidates = PromptCandidateAnalyzer.analyze(prompts: prompts, minimumCount: 1, limit: 3)
        XCTAssertEqual(candidates.count, 3)
    }

    func testAnalyzeIgnoresEmptyPrompt() {
        let candidates = PromptCandidateAnalyzer.analyze(prompts: ["", "  "], minimumCount: 1)
        XCTAssertTrue(candidates.isEmpty)
    }
}
