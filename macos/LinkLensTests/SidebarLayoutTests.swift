import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import LinkLens

/// The sidebar must not force a tall window: a text measured at a tiny width (one word per line)
/// once made the window impossible to shrink below the screen height.
@MainActor
struct SidebarLayoutTests {
    @Test func theSidebarLetsTheWindowBeShort() throws {
        let container = try ModelContainer(for: Gallery.self, Photo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let gallery = Gallery(name: "Séance du 20 sept.", folderPath: "/tmp/photos", folderBookmark: Data())
        container.mainContext.insert(gallery)
        let split = NavigationSplitView {
            LibrarySidebar(
                galleries: [gallery],
                selection: .constant(nil),
                cards: [DetectedCard(url: URL(filePath: "/Volumes/SDTEST"), name: "SDTEST")]
            )
        } detail: {
            Color.clear
        }
        let store = LibraryStore(modelContainer: container)
        let controller = NSHostingController(rootView: split
            .environment(ImportController(store: store))
            .environment(CardImportController(importer: CardImporter(store: store)))
            .modelContainer(container))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(CGSize(width: 900, height: 500))
        window.layoutIfNeeded()

        #expect(window.contentMinSize.height < 400, "minimum height: \(window.contentMinSize.height)")
    }
}
