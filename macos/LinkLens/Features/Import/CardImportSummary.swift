import Foundation

/// What the card import window says about a card before the copy: the counts, the few photos shown
/// as a preview, « +N » for the rest, and the shooting dates.
///
/// Pure values only (no disk access), so the rules are easy to test.
struct CardImportSummary: Equatable {
    /// How many photos the preview strip shows at most, as in the mockup.
    static let previewLimit = 7

    let photoCount: Int
    let videoCount: Int
    /// Every file the import copies: « Importer 11 fichiers ».
    let fileCount: Int
    /// Photos shown in the strip, spread over the whole card (first, …, last) so they give an idea of
    /// the session rather than of its first minute.
    let previewFiles: [CardFile]
    /// Files not in the strip: « +4 ». Videos count here, they have no preview.
    let hiddenCount: Int
    let earliestDate: Date?
    let latestDate: Date?

    init(card: CardContents, previewLimit: Int = Self.previewLimit) {
        photoCount = card.photoCount
        videoCount = card.videoCount
        fileCount = card.files.count
        let photos = card.files.filter { $0.kind == .photo }
        previewFiles = Self.evenlySpread(photos, count: previewLimit)
        hiddenCount = card.files.count - previewFiles.count
        earliestDate = card.earliestDate
        latestDate = card.latestDate
    }

    /// `count` items taken at regular steps, always including the first and the last one.
    /// Fewer items than `count`: all of them.
    static func evenlySpread<Item>(_ items: [Item], count: Int) -> [Item] {
        guard items.count > count else { return items }
        guard count > 1 else { return Array(items.prefix(count)) }
        let step = Double(items.count - 1) / Double(count - 1)
        return (0..<count).map { items[Int((Double($0) * step).rounded())] }
    }

    /// « 10 photos · 1 vidéo · prises le 20 sept. 2026 ».
    func line(locale: Locale = .current, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if photoCount > 0 || videoCount == 0 {
            parts.append(String(inflecting: "^[\(photoCount) photo](inflect: true)"))
        }
        if videoCount > 0 {
            parts.append(String(inflecting: "^[\(videoCount) vidéo](inflect: true)"))
        }
        if let dates = datesTaken(locale: locale, calendar: calendar) {
            parts.append(dates)
        }
        return parts.joined(separator: " · ")
    }

    /// « prises le 20 sept. 2026 », « prises du 19 au 20 sept. 2026 », « prises du 30 sept. au
    /// 2 oct. 2026 », « prises du 30 déc. 2025 au 2 janv. 2026 ». Nil when no file has a date.
    func datesTaken(locale: Locale = .current, calendar: Calendar = .current) -> String? {
        guard let first = earliestDate, let last = latestDate else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.day().month(.abbreviated).year()
        if calendar.isDate(first, inSameDayAs: last) {
            return String(localized: "prises le \(first.formatted(style))")
        }
        let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        let start: String
        if sameMonth {
            start = first.formatted(Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone).day())
        } else if sameYear {
            start = first.formatted(Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
        } else {
            start = first.formatted(style)
        }
        return String(localized: "prises du \(start) au \(last.formatted(style))")
    }
}

/// The folder an import will create, as the window shows it while the name is typed:
/// « 2026 / 2026-09-20 Mariage Julie & Tom / ». Same rules as the import itself (`ImportLayout`).
enum ImportPathPreview {
    static func text(date: Date, sessionName: String, calendar: Calendar = .current) -> String {
        let names = ImportLayout.folderNames(date: date, sessionName: sessionName, calendar: calendar)
        return "\(names.year) / \(names.session) /"
    }

    /// What VoiceOver reads: « Dossier créé : 2026, puis 2026-09-20 Mariage Julie & Tom ».
    static func spokenText(date: Date, sessionName: String, calendar: Calendar = .current) -> String {
        let names = ImportLayout.folderNames(date: date, sessionName: sessionName, calendar: calendar)
        return String(localized: "Dossier créé : \(names.year), puis \(names.session)")
    }
}

extension ImportDestination {
    /// « Images › LinkLens »: the location as the Finder names it, without the start of the path when it
    /// is in the user's home folder. On another disk: « Photos 2TB › LinkLens ».
    var shortDisplayPath: String {
        let home = URL(filePath: realHomeDirectory(), directoryHint: .isDirectory)
        return Self.shortened(
            Self.displayComponents(of: url),
            home: Self.displayComponents(of: home)
        ).joined(separator: " › ")
    }

    /// Drops the home folder's components from the front of `components`; keeps them all otherwise.
    static func shortened(_ components: [String], home: [String]) -> [String] {
        guard !home.isEmpty, components.count > home.count, Array(components.prefix(home.count)) == home else {
            return components
        }
        return Array(components.dropFirst(home.count))
    }

    /// Localized names from the Finder (« Images » for Pictures), or the raw path when the folder is
    /// not reachable.
    private static func displayComponents(of url: URL) -> [String] {
        if let components = FileManager.default.componentsToDisplay(forPath: url.path) {
            return components
        }
        if let parent = FileManager.default.componentsToDisplay(forPath: url.deletingLastPathComponent().path) {
            return parent + [url.lastPathComponent]
        }
        return url.pathComponents.filter { $0 != "/" }
    }
}
