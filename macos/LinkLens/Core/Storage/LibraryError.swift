import Foundation

/// Errors shown to the user (messages in French, localized).
enum LibraryError: LocalizedError, Equatable {
    case folderNotFound(String)
    case accessDenied(String)
    case noPhotos(String)
    case galleryNotFound

    var errorDescription: String? {
        switch self {
        case .folderNotFound(let name):
            String(localized: "Dossier introuvable : \(name)")
        case .accessDenied(let name):
            String(localized: "LinkLens n'a pas l'autorisation de lire le dossier « \(name) ». Choisissez-le à nouveau.")
        case .noPhotos(let name):
            String(localized: "Aucune photo JPEG, HEIC ou RAW Sony (.ARW) dans le dossier « \(name) ».")
        case .galleryNotFound:
            String(localized: "Galerie introuvable.")
        }
    }
}
