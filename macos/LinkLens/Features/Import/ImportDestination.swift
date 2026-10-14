import Foundation

/// A location where galleries are created ("Images/LinkLens", a folder on an external disk…).
struct ImportDestination: Sendable, Equatable {
    var url: URL
    /// Read-write security-scoped bookmark, saved when the location becomes the default one.
    var bookmark: Data

    /// "Macintosh HD › Utilisateurs › chris › Images › LinkLens", the way the Finder names it.
    var displayPath: String {
        let components = FileManager.default.componentsToDisplay(forPath: url.path) ?? [url.lastPathComponent]
        return components.joined(separator: " › ")
    }
}

/// Remembers the default location of new galleries between launches (in `UserDefaults`, which is
/// like `localStorage`: small values, kept in the app's sandbox).
struct ImportDestinationStore: Sendable {
    var defaults: UserDefaults { UserDefaults.standard }
    var key = "cardImport.defaultDestinationBookmark"

    /// The saved location, or nil if none was chosen yet or it cannot be reached (disk unplugged…).
    func load() -> ImportDestination? {
        guard let bookmark = defaults.data(forKey: key),
              let url = try? FolderBookmark.resolve(bookmark)
        else { return nil }
        return ImportDestination(url: url, bookmark: bookmark)
    }

    func save(_ destination: ImportDestination) {
        defaults.set(destination.bookmark, forKey: key)
    }
}
