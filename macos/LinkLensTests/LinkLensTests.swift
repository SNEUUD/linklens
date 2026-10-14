import Foundation
import Testing
@testable import LinkLens

/// Smoke tests: the test bundle runs inside the app (TEST_HOST) with the expected configuration.
struct LinkLensTests {
    @Test func runsInsideTheApp() {
        #expect(Bundle.main.bundleIdentifier == "fr.chriscrepin.linklens")
    }

    @Test func frenchIsTheDevelopmentLanguage() {
        #expect(Bundle.main.developmentLocalization == "fr")
    }
}
