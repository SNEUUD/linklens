import Foundation

/// Names of the exported files: the original name with the new extension, and " (2)", " (3)"…
/// when the name is already taken. An existing file is never replaced.
enum ExportNaming {
    /// One name per path, in the same order. `existingNames` are the files already in the destination.
    ///
    /// Compared without case: on a Mac "DSC1.jpg" and "dsc1.JPG" are the same file.
    static func plan(_ relativePaths: [String], fileExtension: String, existingNames: Set<String>) -> [String] {
        var taken = Set(existingNames.map { $0.lowercased() })
        return relativePaths.map { relativePath in
            let name = freeName(base: baseName(of: relativePath), fileExtension: fileExtension, taken: taken)
            taken.insert(name.lowercased())
            return name
        }
    }

    /// "Jour 2/DSC04297.ARW" → "DSC04297".
    static func baseName(of relativePath: String) -> String {
        let fileName = (relativePath as NSString).lastPathComponent
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    /// `taken` must be lowercased.
    static func freeName(base: String, fileExtension: String, taken: Set<String>) -> String {
        var number = 1
        while true {
            let name = candidate(base: base, fileExtension: fileExtension, number: number)
            if !taken.contains(name.lowercased()) { return name }
            number += 1
        }
    }

    /// Number 1 is the plain name, then "DSC04297 (2).jpg", "DSC04297 (3).jpg"…
    static func candidate(base: String, fileExtension: String, number: Int) -> String {
        number == 1 ? "\(base).\(fileExtension)" : "\(base) (\(number)).\(fileExtension)"
    }
}
