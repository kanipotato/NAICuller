import XCTest
@testable import NovelAIViewerCore

final class ExportServiceTests: XCTestCase {
    private func makeRecord(id: Int64, path: String, prompt: String?) -> ImageRecord {
        ImageRecord(id: id, rootId: 1, path: path, mtime: 0, fileSize: 0, width: nil, height: nil, promptCache: prompt, lastScannedAt: Date())
    }

    func testBuildExportDataIncludesFilePathAndPrompt() throws {
        let service = ExportService()
        let images = [makeRecord(id: 1, path: "/tmp/a.png", prompt: "1girl, chibi")]
        let data = try service.buildExportData(images: images, fields: [.filePath, .prompt])

        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["filePath"] as? String, "/tmp/a.png")
        XCTAssertEqual(json[0]["prompt"] as? String, "1girl, chibi")
    }

    /// prompt_cacheが無い画像はnullとして出力される（詳細設計 4-3章）。
    func testMissingPromptIsExportedAsNull() throws {
        let service = ExportService()
        let images = [makeRecord(id: 1, path: "/tmp/a.png", prompt: nil)]
        let data = try service.buildExportData(images: images, fields: [.filePath, .prompt])

        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertTrue(json[0]["prompt"] is NSNull)
    }

    func testOnlySelectedFieldsAreIncluded() throws {
        let service = ExportService()
        let images = [makeRecord(id: 1, path: "/tmp/a.png", prompt: "prompt text")]
        let data = try service.buildExportData(images: images, fields: [.filePath])

        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertNotNil(json[0]["filePath"])
        XCTAssertNil(json[0]["prompt"])
    }

    func testEmptyFieldsThrows() {
        let service = ExportService()
        let images = [makeRecord(id: 1, path: "/tmp/a.png", prompt: nil)]
        XCTAssertThrowsError(try service.buildExportData(images: images, fields: []))
    }

    func testEmptyImagesProducesEmptyArray() throws {
        let service = ExportService()
        let data = try service.buildExportData(images: [], fields: [.filePath])
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertTrue(json.isEmpty)
    }

    func testExportWritesFileToDisk() throws {
        let service = ExportService()
        let images = [makeRecord(id: 1, path: "/tmp/a.png", prompt: "1girl")]
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try service.export(images: images, fields: [.filePath, .prompt], to: tempURL)

        let data = try Data(contentsOf: tempURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(json[0]["filePath"] as? String, "/tmp/a.png")
    }

    func testDefaultFileNameFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 9
        components.hour = 12
        components.minute = 34
        components.second = 56
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!

        let fileName = ExportService.defaultFileName(now: date)
        XCTAssertEqual(fileName, "novelai-export-20260809-123456.json")
    }
}
