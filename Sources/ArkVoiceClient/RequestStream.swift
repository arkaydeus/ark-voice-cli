import Foundation

/// A single-consumer request sequence. Leaving iteration cancels unfinished
/// work even when the sequence itself remains retained. Dropping an unused
/// sequence or calling `cancel()` also cancels its request.
public struct RequestStream<Element: Sendable>: AsyncSequence, Sendable {
  public typealias AsyncIterator = Iterator
  private let base: AsyncThrowingStream<Element, any Error>
  private let lifetime: Lifetime

  fileprivate final class Lifetime: Sendable {
    let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
  }

  init(
    _ base: AsyncThrowingStream<Element, any Error>,
    cancel: @escaping @Sendable () -> Void
  ) {
    self.base = base
    self.lifetime = Lifetime(cancel)
  }

  public func cancel() { lifetime.cancel() }

  public func makeAsyncIterator() -> Iterator {
    Iterator(base: base.makeAsyncIterator(), lifetime: Lifetime(lifetime.cancel), owner: lifetime)
  }

  public struct Iterator: AsyncIteratorProtocol {
    fileprivate var base: AsyncThrowingStream<Element, any Error>.Iterator
    private let lifetime: Lifetime
    private let owner: Lifetime

    fileprivate init(base: AsyncThrowingStream<Element, any Error>.Iterator, lifetime: Lifetime, owner: Lifetime) {
      self.base = base
      self.lifetime = lifetime
      self.owner = owner
    }

    public mutating func next() async throws -> Element? {
      try await base.next()
    }
  }
}
