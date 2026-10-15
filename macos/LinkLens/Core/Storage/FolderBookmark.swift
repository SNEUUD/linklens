import Foundation

/// Security-scoped bookmarks: the sandbox only lets the app read a folder the user picked,
/// and only during this launch. A bookmark is a saved "permission slip" that reopens it later.
///
/// Every access must be wrapped like this:
/// ```
/// guard url.startAccessingSecurityScopedResource() else { throw … }
/// defer { url.stopAccessingSecurityScopedResource() }
/// ```
enum FolderBookmark {
    /// Read-only on purpose: F2 indexes in place and must never write to the folder.
    static func create(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Read-write: for the location where card imports (F1) create their folders. Never used for a gallery.
    static func createReadWrite(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Returns the folder URL. A stale bookmark (folder moved or renamed) still resolves;
    /// `GalleryAvailabilityMonitor` (F9) saves a fresh one.
    static func resolve(_ bookmark: Data) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// Same, for the availability check (F9): never tries to mount a disk that is not there, and tells
    /// whether the bookmark is stale. `(url: URL, isStale: Bool)` is a tuple with named parts, like
    /// returning `{ url, isStale }` from a TypeScript function.
    static func resolveWithoutMounting(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// True for a folder in the user's trash (~/.Trash) or the trash of an external disk (.Trashes).
    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Canonical form of a folder path, used to compare folders.
    static func canonicalPath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
