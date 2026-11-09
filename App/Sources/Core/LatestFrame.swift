import Foundation

/// One pending frame, one worker. A slow consumer never builds a FIFO of old images.
nonisolated final class LatestFrame<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var working = false
    private var stopped = false
    private var replacements = 0

    /// True only when the caller must start a worker.
    func offer(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        if pending != nil { replacements += 1 }
        pending = value
        guard !working else { return false }
        working = true
        return true
    }

    /// The worker calls this again only after finishing its previous frame.
    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        if value == nil { working = false }
        return value
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        pending = nil
    }

    /// After waiting for a drawable, use the freshest sample without releasing the worker.
    func newest(or fallback: Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        defer { pending = nil }
        if pending != nil { replacements += 1 }
        return pending ?? fallback
    }

    func takeReplacementCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { replacements = 0 }
        return replacements
    }
}
