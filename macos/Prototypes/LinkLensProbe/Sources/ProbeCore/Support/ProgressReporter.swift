import Foundation

/// Terminal progress bar shared by all parallel tasks.
///
/// An `actor` handles its calls one at a time (like a single queue in front of a counter),
/// so many tasks can call `advance()` at once without corrupting `done`.
public actor ProgressReporter {
    private let total: Int
    private let label: String
    private var done = 0
    private var failed = 0
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var lastRender: ContinuousClock.Instant?

    public init(total: Int, label: String) {
        self.total = total
        self.label = label
        self.start = clock.now
    }

    public func advance(by count: Int = 1, failed didFail: Bool = false) {
        done += count
        if didFail { failed += 1 }
        render(force: done == total)
    }

    private func render(force: Bool) {
        let now = clock.now
        // Redraw at most 10 times per second.
        if !force, let lastRender, lastRender.duration(to: now) < .milliseconds(100) { return }
        lastRender = now

        let width = 30
        let filled = total > 0 ? width * done / total : width
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let elapsed = start.duration(to: now).seconds
        let rate = elapsed > 0 ? Double(done) / elapsed : 0
        var line = "\r\(label) [\(bar)] \(done)/\(total) · \(rate.formatted(.number.precision(.fractionLength(1)))) photos/s"
        if failed > 0 { line += " · \(failed) erreur(s)" }
        if force { line += "\n" }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
