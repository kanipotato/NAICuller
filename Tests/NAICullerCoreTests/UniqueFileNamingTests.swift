import XCTest
@testable import NAICullerCore

final class UniqueFileNamingTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/backup")

    func testReturnsOriginalNameWhenNoCollision() {
        let url = UniqueFileNaming.uniqueDestinationURL(
            for: URL(fileURLWithPath: "/tmp/root/a.png"),
            in: folder,
            existingNames: []
        )
        XCTAssertEqual(url, folder.appendingPathComponent("a.png"))
    }

    func testAppendsSuffixOnCollision() {
        let url = UniqueFileNaming.uniqueDestinationURL(
            for: URL(fileURLWithPath: "/tmp/root/a.png"),
            in: folder,
            existingNames: ["a.png"]
        )
        XCTAssertEqual(url, folder.appendingPathComponent("a 2.png"))
    }

    func testSkipsOverAlreadyTakenSuffixes() {
        let url = UniqueFileNaming.uniqueDestinationURL(
            for: URL(fileURLWithPath: "/tmp/root/a.png"),
            in: folder,
            existingNames: ["a.png", "a 2.png", "a 3.png"]
        )
        XCTAssertEqual(url, folder.appendingPathComponent("a 4.png"))
    }

    func testHandlesFileNameWithoutExtension() {
        let url = UniqueFileNaming.uniqueDestinationURL(
            for: URL(fileURLWithPath: "/tmp/root/README"),
            in: folder,
            existingNames: ["README"]
        )
        XCTAssertEqual(url, folder.appendingPathComponent("README 2"))
    }

    func testHandlesNonASCIIFileNames() {
        let url = UniqueFileNaming.uniqueDestinationURL(
            for: URL(fileURLWithPath: "/tmp/root/オレンジChibi.png"),
            in: folder,
            existingNames: ["オレンジChibi.png"]
        )
        XCTAssertEqual(url, folder.appendingPathComponent("オレンジChibi 2.png"))
    }
}
