import Foundation
import Testing
@testable import LinkLens

struct PhotoMetadataReaderTests {
    @Test func parsesExifDateWithSubseconds() throws {
        let date = try #require(PhotoMetadataReader.parseExifDate("2026:09:20 14:40:57", subseconds: "25"))
        let expected = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14, minute: 40, second: 57)))
        #expect(abs(date.timeIntervalSince(expected) - 0.25) < 0.001)
    }

    @Test(arguments: [nil, "", "2026:09:20", "pas une date"])
    func rejectsInvalidExifDates(text: String?) {
        #expect(PhotoMetadataReader.parseExifDate(text, subseconds: nil) == nil)
    }

    @Test func readsDimensionsAndDateFromJPEG() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let file = try folder.writeJPEG("a.jpg", width: 80, height: 60, exifDate: "2026:09:20 14:40:57")

        let metadata = PhotoMetadataReader.read(url: file)

        #expect(metadata.pixelWidth == 80)
        #expect(metadata.pixelHeight == 60)
        #expect(metadata.captureDate == PhotoMetadataReader.parseExifDate("2026:09:20 14:40:57", subseconds: nil))
    }

    @Test func unreadableFileGivesUnknownMetadata() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let file = try folder.writeFile("broken.ARW")

        #expect(PhotoMetadataReader.read(url: file) == .unknown)
    }
}
