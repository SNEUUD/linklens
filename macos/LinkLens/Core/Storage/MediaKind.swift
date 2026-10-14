import Foundation

/// Kind of file in a gallery, from its extension.
///
/// A `String` raw value lets it be stored in SwiftData (`Photo.mediaKindRaw`) and read back with
/// `MediaKind(rawValue:)`; a value written by a future version decodes as `.unknown` instead of failing.
enum MediaKind: String, Sendable, Equatable, Codable {
    case photo
    case video
    case unknown

    static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "arw"]
    /// AVFoundation reads mov, mp4 and m4v. AVCHD clips (mts) are copied and listed, without a thumbnail.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mts"]

    init(relativePath: String) {
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()
        if Self.photoExtensions.contains(fileExtension) {
            self = .photo
        } else if Self.videoExtensions.contains(fileExtension) {
            self = .video
        } else {
            self = .unknown
        }
    }

    /// Stored value → kind. `nil` is a photo indexed before videos existed (F2 catalogues).
    init(stored rawValue: String?) {
        guard let rawValue else {
            self = .photo
            return
        }
        self = MediaKind(rawValue: rawValue) ?? .unknown
    }
}
