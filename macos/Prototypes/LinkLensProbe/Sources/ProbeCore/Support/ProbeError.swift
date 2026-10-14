import Foundation

/// Errors shown to the user (messages in French).
public enum ProbeError: LocalizedError, Equatable {
    case folderNotFound(String)
    case outputInsideSource(output: String, source: String)
    case unreadableImage(String)
    case imageProcessingFailed(String)
    case invalidThresholds(String)
    case storeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let path):
            "Dossier introuvable : \(path)"
        case .outputInsideSource(let output, let source):
            "Le dossier de sortie (\(output)) ne doit pas être dans le dossier de photos (\(source)) : celui-ci reste en lecture seule."
        case .unreadableImage(let name):
            "Image illisible : \(name)"
        case .imageProcessingFailed(let detail):
            "Échec du traitement de l'image : \(detail)"
        case .invalidThresholds(let detail):
            "Fichier de seuils invalide : \(detail)"
        case .storeFailure(let detail):
            "Erreur SwiftData : \(detail)"
        }
    }
}
