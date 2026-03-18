import Foundation

/// A thread-safe FIFO queue backed by an array.
final class ThreadSafeQueue<T> {
    private var items: [T] = []
    private let lock = NSLock()

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    func enqueue(_ item: T) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }

    func dequeue() -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    func dequeueAll() -> [T] {
        lock.lock(); defer { lock.unlock() }
        let all = items
        items.removeAll()
        return all
    }
}
