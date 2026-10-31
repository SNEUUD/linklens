import AppKit
import SwiftUI
import Testing

/// Draws a SwiftUI view in a real window and saves it as a PNG, in light or dark mode: a way to look
/// at the interface without a screen session. Used by `InterfaceRenderTests` only (never shipped).
///
/// How it works: the view goes into an `NSHostingController` inside a titled window (so the toolbar
/// and the sidebar are real), the window is shown in front for a moment so it can lay out and load
/// its thumbnails, then the window server's image of it is saved (glass and blur included).
/// `cacheDisplay`, used by earlier sessions, leaves the rows of a `List` blank since macOS 26: it is
/// only the fallback. The window flashes on screen while the renders run; do not click meanwhile.
@MainActor
enum WindowRenderer {
    enum Appearance: String, CaseIterable {
        case light, dark

        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    }

    /// Where the PNGs go: `LINKLENS_RENDERS_DIR` if set, else a folder in the temporary directory
    /// (inside the sandbox: ~/Library/Containers/fr.chriscrepin.linklens/Data/tmp/LinkLensRenders).
    static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LINKLENS_RENDERS_DIR"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return FileManager.default.temporaryDirectory.appending(path: "LinkLensRenders", directoryHint: .isDirectory)
    }

    /// Renders `view` at `size` (points; the PNG is at the screen's scale) and returns the PNG's URL.
    @discardableResult
    static func render(
        _ view: some View,
        named name: String,
        size: CGSize,
        appearance: Appearance,
        settle: Duration = .seconds(2),
        prepare: (@MainActor (NSWindow) async throws -> Void)? = nil
    ) async throws -> URL {
        // `TEST_RUNNER_LINKLENS_RENDERS_ONLY=accueil,import-carte` renders only the names starting with
        // one of these (`-only-testing` does not select the tests that take arguments).
        let url = outputDirectory.appending(path: "\(name)-\(appearance.rawValue).png")
        if let only = ProcessInfo.processInfo.environment["LINKLENS_RENDERS_ONLY"],
           !only.split(separator: ",").contains(where: { name.hasPrefix($0) }) {
            return url
        }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none // no opening zoom in the capture
        window.appearance = NSAppearance(named: appearance.name)
        window.toolbarStyle = .unified
        // An inactive window greys its text and buttons: the render shows the window as in use.
        // Light or dark comes from the window's appearance, as in the app (SwiftUI follows it).
        let controller = NSHostingController(rootView: view
            .environment(\.controlActiveState, .key))
        // Lets the view's `.toolbar` and `.navigationTitle` reach the window, as in the app.
        controller.sceneBridgingOptions = [.all]
        // Only the view's minimum size limits the window, which then keeps the size asked for (as a
        // window the user resized). By default the window would take the view's ideal size.
        controller.sizingOptions = [.minSize]
        window.contentViewController = controller
        // On screen, above the other apps: off screen or hidden, the window is not redrawn and the
        // capture shows a stale layout. Floating and transient, Stage Manager leaves it alone (it
        // would move and resize it). The app is not activated: the view is told it is in the key
        // window instead, above. With `.fullSizeContentView`, `size` includes the title bar.
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle]
        let frame = CGRect(origin: NSScreen.main?.visibleFrame.origin ?? .zero, size: size)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        window.setFrame(frame, display: true)
        defer {
            // Takes the SwiftUI views down with the window: a closed window kept alive could still write
            // to the shared settings (`@AppStorage`) and change the next render.
            window.contentViewController = nil
            window.close()
        }

        // Waiting with `Task.sleep` on the main actor keeps the main run loop turning: layout,
        // `.task` modifiers and image loading go on meanwhile.
        try await Task.sleep(for: settle)
        // E.g. keys pressed in the window, then a moment for the view to follow.
        if let prepare {
            try await prepare(window)
            try await Task.sleep(for: .seconds(1))
        }
        window.displayIfNeeded()

        let png: Data
        if let image = composited(window) {
            png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        } else {
            let frameView = try #require(window.contentView?.superview, "window frame view")
            let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            png = try #require(bitmap.representation(using: .png, properties: [:]))
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: url)
        print("Render: \(url.path)")
        return url
    }

    /// Sends a key to the window's focused view, as if typed (`→` is key code 124), with `modifiers` held.
    static func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
    }

    static func pressRightArrow(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        press(keyCode: 124, characters: String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)), modifiers: modifiers, in: window)
    }

    /// The window as the screen shows it (glass, blur, list rows included), through
    /// `CGWindowListCreateImage`. An app may capture its own windows without the screen recording
    /// permission. The function is hidden from Swift since the macOS 15 SDK (Apple wants
    /// ScreenCaptureKit, which asks for that permission), so it is looked up by name; nil if missing.
    private static func composited(_ window: NSWindow) -> CGImage? {
        if let sheet = window.attachedSheet {
            return composited(window, with: sheet)
        }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3 // kCGWindowListOptionIncludingWindow
        let options: UInt32 = (1 << 0) | (1 << 3) // boundsIgnoreFraming | bestResolution
        return createImage(.null, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }

    /// The window with the sheet shown over it (the card import window): everything on screen at or
    /// above the window, inside its frame. The renders' window floats above the other apps, so only
    /// its own sheet can be there.
    private static func composited(_ window: NSWindow, with sheet: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let screenHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        // Quartz counts y from the top of the main screen, AppKit from the bottom.
        let frame = window.frame
        let bounds = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
        let aboveAndIncluding: UInt32 = (1 << 1) | (1 << 3) // onScreenAboveWindow | includingWindow
        let options: UInt32 = (1 << 0) | (1 << 3) // boundsIgnoreFraming | bestResolution
        return createImage(bounds, aboveAndIncluding, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }
}
