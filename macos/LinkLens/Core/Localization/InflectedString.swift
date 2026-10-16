import Foundation

extension String {
    /// A localized string whose `^[26 photo](inflect: true)` becomes « 26 photos ».
    ///
    /// `String(localized:)` leaves that markup as it is; only `AttributedString(localized:)` (and
    /// SwiftUI's `Text`) apply it. Use this one where a plain `String` is needed (VoiceOver labels,
    /// texts built in code), like a `pluralize()` helper in TypeScript.
    init(inflecting value: String.LocalizationValue) {
        self.init(AttributedString(localized: value).characters)
    }
}
