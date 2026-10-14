import Foundation

extension Duration {
    /// Duration as a plain number of seconds (e.g. 0.125).
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Measures the time spent in a synchronous block, in seconds.
func measure<T>(_ seconds: inout Double, _ work: () throws -> T) rethrows -> T {
    let clock = ContinuousClock()
    let start = clock.now
    defer { seconds += start.duration(to: clock.now).seconds }
    return try work()
}
