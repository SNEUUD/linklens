import Foundation
import Testing
@testable import LinkLens

struct FolderBookmarkTests {
    @Test func bookmarkResolvesToTheSameFolder() throws {
        let folder = try TestFolder()
        defer { folder.remove() }

        let bookmark = try FolderBookmark.create(for: folder.url)
        let resolved = try FolderBookmark.resolve(bookmark)

        #expect(FolderBookmark.canonicalPath(of: resolved) == FolderBookmark.canonicalPath(of: folder.url))
        #expect(resolved.startAccessingSecurityScopedResource())
        resolved.stopAccessingSecurityScopedResource()
    }

    @Test func invalidBookmarkThrows() {
        #expect(throws: (any Error).self) {
            try FolderBookmark.resolve(Data("pas un bookmark".utf8))
        }
    }
}
