import Foundation

/// Where an imported card goes: `AAAA/AAAA-MM-JJ Nom de séance/`, every file side by side.
///
/// Pure functions only (no disk access), so the rules are easy to test.
enum ImportLayout {
    /// Longest session name kept, so the folder name stays readable in the Finder.
    static let maxSessionNameLength = 80

    /// "2026", "2026-10-14 Mariage Julie & Tom". The date is the camera's local date.
    static func folderNames(date: Date, sessionName: String, calendar: Calendar = .current) -> (year: String, session: String) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let name = sanitizedSessionName(sessionName)
        return (year, name.isEmpty ? day : "\(day) \(name)")
    }

    /// The name typed by the user, made safe for a folder name: no "/" or ":" (path separators),
    /// no leading dot (it would hide the folder), no line breaks, single spaces.
    static func sanitizedSessionName(_ name: String) -> String {
        let replaced = name.map { character -> String in
            if character == "/" || character == ":" { return "-" }
            if character.isNewline || character == "\t" { return " " }
            return String(character)
        }.joined()
        var cleaned = replaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while cleaned.hasPrefix(".") || cleaned.hasPrefix(" ") {
            cleaned.removeFirst()
        }
        return String(cleaned.prefix(maxSessionNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// "2026-10-14 Mariage", then "2026-10-14 Mariage (2)"… when a folder of that name exists already.
    static func numberedFolderName(_ name: String, number: Int) -> String {
        number == 1 ? name : "\(name) (\(number))"
    }

    /// One file name per card file, in the same order, all in the same folder. Cards number their
    /// folders (100MSDCF, 101MSDCF…) and may hold two "DSC00001.ARW": the second becomes
    /// "DSC00001 (2).ARW". Names are compared without case, like the Mac does.
    static func destinationNames(for relativePaths: [String]) -> [String] {
        var taken: Set<String> = []
        return relativePaths.map { relativePath in
            let fileExtension = (relativePath as NSString).pathExtension
            let name = ExportNaming.freeName(
                base: ExportNaming.baseName(of: relativePath),
                fileExtension: fileExtension,
                taken: taken
            )
            taken.insert(name.lowercased())
            return name
        }
    }
}
