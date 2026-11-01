/// A value a test changes after handing it to a closure, for instance a disk unplugged then plugged back.
/// Capturing a plain `var` in a `@MainActor` closure and changing it afterwards is a Swift 6 warning; a
/// small box shared by reference is not (like a `useRef` in React).
@MainActor
final class TestValue<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
