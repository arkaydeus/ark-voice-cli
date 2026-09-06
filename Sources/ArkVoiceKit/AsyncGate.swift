import Foundation

/// A FIFO async mutex.
///
/// One model cannot run two generations at once, so every request takes a turn.
/// This is a lock rather than an actor because the work it guards touches
/// non-`Sendable` MLX types: keeping that work in ordinary nonisolated async
/// functions avoids passing models and arrays across an isolation boundary.
///
/// A task already waiting for its turn is not interrupted by cancellation; it
/// acquires and then sees the cancellation at the next checkpoint, which is
/// bounded by one generation.
final class AsyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    let mustWait: Bool = {
      lock.lock()
      defer { lock.unlock() }
      if isBusy { return true }
      isBusy = true
      return false
    }()

    guard mustWait else { return }

    await withCheckedContinuation { continuation in
      lock.lock()
      if !isBusy {
        isBusy = true
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func release() {
    lock.lock()
    if waiters.isEmpty {
      isBusy = false
      lock.unlock()
      return
    }
    let next = waiters.removeFirst()
    lock.unlock()
    next.resume()
  }
}

/// Runs `body` with exclusive access to `gate`.
///
/// A free function rather than a method on the gate so that `body` may return
/// and capture non-`Sendable` values.
func withGate<T>(_ gate: AsyncGate, _ body: () async throws -> T) async rethrows -> T {
  await gate.acquire()
  defer { gate.release() }
  return try await body()
}
