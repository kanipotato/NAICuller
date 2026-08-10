import XCTest
@testable import NAICullerCore

final class ImageSortOrderTests: XCTestCase {
    private func makeImage(id: Int64, name: String, mtime: Double, fileSize: Int64) -> ImageRecord {
        ImageRecord(
            id: id,
            rootId: 1,
            path: "/tmp/root/\(name)",
            mtime: mtime,
            fileSize: fileSize,
            width: nil,
            height: nil,
            promptCache: nil,
            lastScannedAt: Date()
        )
    }

    func testDateNewestSortsDescendingByMtime() {
        let images = [
            makeImage(id: 1, name: "a.png", mtime: 100, fileSize: 1),
            makeImage(id: 2, name: "b.png", mtime: 300, fileSize: 1),
            makeImage(id: 3, name: "c.png", mtime: 200, fileSize: 1)
        ]
        let sorted = ImageSortOrder.dateNewest.sorted(images).map(\.id)
        XCTAssertEqual(sorted, [2, 3, 1])
    }

    func testDateOldestSortsAscendingByMtime() {
        let images = [
            makeImage(id: 1, name: "a.png", mtime: 100, fileSize: 1),
            makeImage(id: 2, name: "b.png", mtime: 300, fileSize: 1),
            makeImage(id: 3, name: "c.png", mtime: 200, fileSize: 1)
        ]
        let sorted = ImageSortOrder.dateOldest.sorted(images).map(\.id)
        XCTAssertEqual(sorted, [1, 3, 2])
    }

    func testSizeLargestAndSmallest() {
        let images = [
            makeImage(id: 1, name: "a.png", mtime: 0, fileSize: 500),
            makeImage(id: 2, name: "b.png", mtime: 0, fileSize: 100),
            makeImage(id: 3, name: "c.png", mtime: 0, fileSize: 900)
        ]
        XCTAssertEqual(ImageSortOrder.sizeLargest.sorted(images).map(\.id), [3, 1, 2])
        XCTAssertEqual(ImageSortOrder.sizeSmallest.sorted(images).map(\.id), [2, 1, 3])
    }

    /// Finderの「名前」ソートと同じ自然順（"file2"が"file10"より前に来る）になることを確認する。
    func testNameAscendingUsesNaturalSortOrder() {
        let images = [
            makeImage(id: 1, name: "file10.png", mtime: 0, fileSize: 1),
            makeImage(id: 2, name: "file2.png", mtime: 0, fileSize: 1),
            makeImage(id: 3, name: "file1.png", mtime: 0, fileSize: 1)
        ]
        let sortedNames = ImageSortOrder.nameAscending.sorted(images).map { $0.url.lastPathComponent }
        XCTAssertEqual(sortedNames, ["file1.png", "file2.png", "file10.png"])
    }

    func testNameDescendingReversesNaturalSortOrder() {
        let images = [
            makeImage(id: 1, name: "file10.png", mtime: 0, fileSize: 1),
            makeImage(id: 2, name: "file2.png", mtime: 0, fileSize: 1),
            makeImage(id: 3, name: "file1.png", mtime: 0, fileSize: 1)
        ]
        let sortedNames = ImageSortOrder.nameDescending.sorted(images).map { $0.url.lastPathComponent }
        XCTAssertEqual(sortedNames, ["file10.png", "file2.png", "file1.png"])
    }
}
