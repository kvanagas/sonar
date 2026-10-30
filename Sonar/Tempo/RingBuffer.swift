import Synchronization

/// Single-producer / single-consumer lock-free ring buffer of `Float` samples.
///
/// The producer (the real-time audio thread) only calls `write`; the consumer
/// (the analysis queue) only calls `read`. Neither side allocates or locks.
final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let head = Atomic<Int>(0) // total samples written
    private let tail = Atomic<Int>(0) // total samples read

    /// `capacity` is rounded up to the next power of two.
    init(capacity: Int) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        self.mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    /// Writes `count` samples. If the buffer is full because the consumer has
    /// fallen behind, the samples that don't fit are dropped so the producer
    /// never waits.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        let n = min(count, free)
        guard n > 0 else { return }
        for i in 0..<n {
            storage[(h + i) & mask] = samples[i]
        }
        head.store(h + n, ordering: .releasing)
    }

    /// Reads up to `maxCount` samples into `out` and returns how many were read.
    func read(into out: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(maxCount, h - t)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            out[i] = storage[(t + i) & mask]
        }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Discards everything currently buffered. Consumer side only.
    func drain() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }
}
