import Foundation

// TODO(core): move to BlackTextCore. A copy of the helper in the Mac app's FindController.swift.

/// A counter other threads can check to see if their search is still wanted.
final class Generation: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == value
    }
}
