import Darwin
import Foundation

/// What the reader hands a request: a control message or a span of audio.
enum Inbound: Sendable {
  case event(WireEvent)
  case audio(Data)
}

/// One socket, one reader thread, and a routing table from request id to the
/// stream waiting on it.
///
/// Every frame is read on a dedicated thread and routed by its request id, so
/// any number of requests can be in flight at once. Writes go through a serial
/// queue, which keeps each request's frames in order without blocking Swift
/// concurrency's cooperative pool.
final class Transport: @unchecked Sendable {
  /// Audio is sent in frames of at most this size so a long recording is not
  /// one enormous allocation on either side.
  static let audioFrameBytes = 256 * 1024

  private final class Route: @unchecked Sendable {
    let operation: ClientOperation
    /// Kept alive while the request is open, so a stream outlives a dropped
    /// reference to the connection that made it.
    let owner: AnyObject?
    let deliver: @Sendable (Inbound) -> Void
    let finish: @Sendable ((any Error)?) -> Void
    /// Set once a cancel is sent: the consumer is gone, so frames are dropped
    /// until the request's terminal event retires the route.
    var draining = false

    init(
      operation: ClientOperation,
      owner: AnyObject?,
      deliver: @escaping @Sendable (Inbound) -> Void,
      finish: @escaping @Sendable ((any Error)?) -> Void
    ) {
      self.operation = operation
      self.owner = owner
      self.deliver = deliver
      self.finish = finish
    }
  }

  private let descriptor: Int32
  private let writeQueue = DispatchQueue(label: "ark-voice.client.write")
  private let lock = NSLock()
  private var routes: [UInt32: Route] = [:]
  private var nextRequestID: UInt32 = 1
  /// Why the connection ended, once it has.
  private var failure: (any Error)?

  private init(descriptor: Int32) {
    self.descriptor = descriptor
    var enabled: Int32 = 1
    // Writing to a socket the server has closed must return EPIPE, not kill the
    // host process with SIGPIPE.
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    let reader = Thread { [self] in readLoop() }
    reader.name = "ark-voice.client.reader"
    reader.start()
  }

  static func connect(path: String) throws -> Transport {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { throw ArkVoiceClientError.socketPathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: bytes)
      destination[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ArkVoiceClientError.systemCall("socket", errno) }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(descriptor)
      if code == ENOENT || code == ECONNREFUSED { throw ArkVoiceClientError.notRunning(path: path) }
      throw ArkVoiceClientError.systemCall("connect", code)
    }
    return Transport(descriptor: descriptor)
  }

  // MARK: - Requests

  /// Sends a request and streams what comes back for it.
  ///
  /// The request goes out now, not when iteration starts, so several can be in
  /// flight together. `transform` runs on the reader thread, in frame order, and
  /// returns `nil` for frames the caller does not surface. The stream finishes
  /// after the request's terminal event, or throws the server's error.
  /// Abandoning the stream early cancels the request on the server.
  func stream<Element: Sendable>(
    _ message: WireRequest,
    audio: PCMAudio? = nil,
    retaining owner: AnyObject? = nil,
    _ transform: @escaping @Sendable (Inbound) -> Element?
  ) -> RequestStream<Element> {
    let (base, continuation) = AsyncThrowingStream<Element, any Error>.makeStream()
    let requestID = open(
      message,
      audio: audio,
      owner: owner,
      deliver: { inbound in
        if let element = transform(inbound) { continuation.yield(element) }
      },
      finish: { error in continuation.finish(throwing: error) }
    )
    let cancel: @Sendable () -> Void = { [weak self] in self?.cancel(requestID) }
    continuation.onTermination = { termination in
      if case .cancelled = termination { cancel() }
    }
    return RequestStream(base, cancel: cancel)
  }

  /// Sends a request and collects its control messages, ending with the
  /// terminal one.
  func events(_ message: WireRequest, audio: PCMAudio? = nil) async throws -> [WireEvent] {
    var events: [WireEvent] = []
    let stream = stream(message, audio: audio) { inbound -> WireEvent? in
      if case .event(let event) = inbound { return event }
      return nil
    }
    for try await event in stream { events.append(event) }
    // A cancelled task ends the iteration early rather than throwing.
    try Task.checkCancellation()
    return events
  }

  private func open(
    _ message: WireRequest,
    audio: PCMAudio?,
    owner: AnyObject?,
    deliver: @escaping @Sendable (Inbound) -> Void,
    finish: @escaping @Sendable ((any Error)?) -> Void
  ) -> UInt32 {
    let opened = lock.withLock { () -> Result<UInt32, any Error> in
      // Requests in flight saw the real cause; later ones just find it closed.
      if failure != nil { return .failure(ArkVoiceClientError.connectionClosed) }
      var requestID = nextRequestID
      // Skip id 0, reserved for connection-level errors, and any id still in use
      // after the counter wraps.
      while requestID == 0 || routes[requestID] != nil { requestID &+= 1 }
      nextRequestID = requestID &+ 1
      routes[requestID] = Route(
        operation: message.op, owner: owner, deliver: deliver, finish: finish)
      return .success(requestID)
    }
    let requestID: UInt32
    switch opened {
    case .failure(let error):
      finish(error)
      return 0
    case .success(let id):
      requestID = id
    }

    var frames: [Frame] = []
    do {
      frames.append(Frame(kind: .json, requestID: requestID, payload: try message.encoded()))
      if let audio {
        let data = audio.data
        var offset = data.startIndex
        while offset < data.endIndex {
          let end = min(offset + Self.audioFrameBytes, data.endIndex)
          frames.append(Frame(kind: .pcm, requestID: requestID, payload: data[offset..<end]))
          offset = end
        }
        frames.append(
          Frame(kind: .json, requestID: requestID, payload: try WireRequest(.end).encoded()))
      }
    } catch {
      lock.withLock { _ = routes.removeValue(forKey: requestID) }
      finish(error)
      return requestID
    }
    enqueue(frames)
    return requestID
  }

  /// Asks the server to abandon a request whose consumer has gone.
  func cancel(_ requestID: UInt32) {
    let shouldSend = lock.withLock { () -> Bool in
      guard failure == nil, let route = routes[requestID], !route.draining else { return false }
      route.draining = true
      return true
    }
    guard shouldSend, let payload = try? WireRequest(.cancel).encoded() else { return }
    enqueue([Frame(kind: .json, requestID: requestID, payload: payload)])
  }

  func close() {
    fail(ArkVoiceClientError.connectionClosed)
  }

  /// Ends the connection, failing every request still in flight with `error`.
  private func fail(_ error: any Error) {
    let pending = lock.withLock { () -> [Route]? in
      guard failure == nil else { return nil }
      failure = error
      defer { routes.removeAll() }
      return Array(routes.values)
    }
    guard let pending else { return }
    // Wakes the reader, which closes the descriptor behind any queued writes.
    shutdown(descriptor, SHUT_RDWR)
    for route in pending { route.finish(error) }
  }

  // MARK: - Writing

  private func enqueue(_ frames: [Frame]) {
    writeQueue.async { [self] in
      for frame in frames {
        guard lock.withLock({ failure == nil }) else { return }
        if let error = writeAll(frame.encoded()) {
          fail(error)
          return
        }
      }
    }
  }

  private func writeAll(_ data: Data) -> (any Error)? {
    data.withUnsafeBytes { raw -> (any Error)? in
      guard var pointer = raw.baseAddress else { return nil }
      var remaining = raw.count
      while remaining > 0 {
        let written = write(descriptor, pointer, remaining)
        if written > 0 {
          pointer = pointer.advanced(by: written)
          remaining -= written
        } else if written < 0, errno == EINTR {
          continue
        } else {
          return errno == EPIPE
            ? ArkVoiceClientError.connectionClosed : ArkVoiceClientError.systemCall("write", errno)
        }
      }
      return nil
    }
  }

  // MARK: - Reading

  private func readLoop() {
    while true {
      do {
        let header = try FrameHeader(try readExactly(Frame.headerSize))
        let payload = header.payloadLength > 0 ? try readExactly(header.payloadLength) : Data()
        dispatch(Frame(kind: header.kind, requestID: header.requestID, payload: payload))
      } catch FrameError.connectionClosed {
        fail(ArkVoiceClientError.connectionClosed)
        break
      } catch let error as FrameError {
        fail(ArkVoiceClientError.protocolViolation(error.localizedDescription))
        break
      } catch {
        fail(error)
        break
      }
    }
    // Descriptor numbers are reused as soon as close returns. Closing behind
    // every queued write means no write can land on a later connection.
    writeQueue.async { [descriptor] in Darwin.close(descriptor) }
  }

  private func dispatch(_ frame: Frame) {
    switch frame.kind {
    case .pcm:
      let route = lock.withLock { routes[frame.requestID] }
      guard let route, !lock.withLock({ route.draining }) else { return }
      route.deliver(.audio(frame.payload))

    case .json:
      let event: WireEvent
      do {
        event = try WireEvent.decode(frame.payload)
      } catch {
        fail(ArkVoiceClientError.protocolViolation("undecodable control message"))
        return
      }
      if frame.requestID == 0 {
        if event.kind == .error {
          fail(serverError(event, requestID: 0))
        }
        return
      }
      let routed = lock.withLock { () -> (Route, Bool, Bool)? in
        guard let route = routes[frame.requestID] else { return nil }
        let terminal = Self.isTerminal(event, for: route.operation)
        if terminal { routes.removeValue(forKey: frame.requestID) }
        return (route, terminal, route.draining)
      }
      // Frames for a request nobody is waiting on are dropped: a late answer to
      // a cancel, or anything addressed to an id this client never used.
      guard let (route, terminal, draining) = routed else { return }
      if draining {
        if terminal { route.finish(nil) }
        return
      }
      if event.kind == .error {
        route.finish(serverError(event, requestID: frame.requestID))
        return
      }
      route.deliver(.event(event))
      if terminal { route.finish(nil) }
    }
  }

  private static func isTerminal(_ event: WireEvent, for operation: ClientOperation) -> Bool {
    switch event.kind {
    case .error: true
    case .helloOK: operation == .hello
    case .voices: operation == .voices
    case .status: operation == .status
    case .done: true
    default: false
    }
  }

  private func serverError(_ event: WireEvent, requestID: UInt32) -> ServerError {
    ServerError(
      rawCode: event.code ?? ServerErrorCode.failed.rawValue,
      message: event.message ?? "The server reported a failure.",
      requestID: requestID
    )
  }

  private func readExactly(_ count: Int) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let received = buffer[filled...].withUnsafeMutableBytes { raw -> Int in
        read(descriptor, raw.baseAddress, count - filled)
      }
      if received > 0 {
        filled += received
      } else if received == 0 {
        throw filled == 0 ? FrameError.connectionClosed : FrameError.truncated
      } else if errno != EINTR {
        // A shutdown from close() lands here or as end of file.
        throw FrameError.connectionClosed
      }
    }
    return Data(buffer)
  }
}
