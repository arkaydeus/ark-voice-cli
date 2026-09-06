import Darwin
import Foundation

/// Errors from the Unix-domain socket layer.
public enum SocketError: LocalizedError {
  case pathTooLong(String)
  case addressInUse(String)
  case unsafeExistingPath(String)
  case systemCall(String, Int32)
  case notRunning(String)

  public var errorDescription: String? {
    switch self {
    case .pathTooLong(let path):
      "Socket path is too long for a Unix domain socket: \(path)"
    case .addressInUse(let path):
      "Another ark-voice server is already listening on \(path)"
    case .unsafeExistingPath(let path):
      "Refusing to replace a non-socket filesystem entry at \(path)"
    case .systemCall(let name, let code):
      "\(name) failed: \(String(cString: strerror(code))) (\(code))"
    case .notRunning(let path):
      "No ark-voice server is listening on \(path). Start one with 'ark-voice serve'."
    }
  }
}

/// Blocking read/write over one connected socket.
///
/// Reads happen on a dedicated thread per connection, and writes are queued on a
/// serial dispatch queue, so neither can stall Swift concurrency's cooperative
/// thread pool.
public final class SocketConnection: @unchecked Sendable {
  private let descriptor: Int32
  private let writeQueue: DispatchQueue
  private let closedLock = NSLock()
  private var isClosed = false

  init(descriptor: Int32, label: String) {
    self.descriptor = descriptor
    self.writeQueue = DispatchQueue(label: label)
    var enabled: Int32 = 1
    // Writing to a socket the peer has closed must return EPIPE, not kill the
    // process with SIGPIPE.
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
  }

  /// Reads the next frame, blocking until one arrives.
  public func readFrame() throws -> Frame {
    let headerBytes = try readExactly(Frame.headerSize)
    let header = try FrameHeader(headerBytes)
    let payload =
      header.payloadLength > 0 ? try readExactly(header.payloadLength) : Data()
    return Frame(kind: header.kind, requestID: header.requestID, payload: payload)
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
        continue
      }
      if received == 0 {
        throw filled == 0 ? FrameError.connectionClosed : FrameError.truncated
      }
      if errno == EINTR { continue }
      throw SocketError.systemCall("read", errno)
    }
    return Data(buffer)
  }

  /// Queues a frame for delivery. Returns immediately.
  public func send(_ frame: Frame) {
    let data = frame.encoded()
    writeQueue.async { [weak self] in
      self?.writeAll(data)
    }
  }

  /// Sends a frame and waits for it to reach the socket.
  public func sendSynchronously(_ frame: Frame) {
    let data = frame.encoded()
    writeQueue.sync { self.writeAll(data) }
  }

  private func writeAll(_ data: Data) {
    guard !isConnectionClosed else { return }
    data.withUnsafeBytes { raw in
      guard var pointer = raw.baseAddress else { return }
      var remaining = raw.count
      while remaining > 0 {
        let written = write(descriptor, pointer, remaining)
        if written > 0 {
          pointer = pointer.advanced(by: written)
          remaining -= written
          continue
        }
        if written < 0 && errno == EINTR { continue }
        // The peer went away; the reader will notice and tear the connection down.
        return
      }
    }
  }

  private var isConnectionClosed: Bool {
    closedLock.withLock { isClosed }
  }

  public func close() {
    let shouldClose = closedLock.withLock {
      guard !isClosed else { return false }
      isClosed = true
      return true
    }
    guard shouldClose else { return }
    shutdown(descriptor, SHUT_RDWR)
    // Descriptor numbers may be reused as soon as close returns. Serialize the
    // final close behind every write so an in-flight write can never target a
    // later connection that inherited the same number.
    writeQueue.async { [descriptor] in Darwin.close(descriptor) }
  }
}

/// A listening Unix-domain socket.
public final class SocketListener: @unchecked Sendable {
  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
  }

  public let path: String
  private let descriptor: Int32
  private let socketIdentity: FileIdentity
  private let closedLock = NSLock()
  private var isClosed = false

  /// Binds `path`, replacing a socket file left behind by a dead server.
  ///
  /// A leftover file is indistinguishable from a live server by inspection, so
  /// this connects to it first: if that succeeds another server owns the path.
  public init(path: String) throws {
    self.path = path

    // Validate the address before opening any descriptor, and create the
    // parent before placing the startup lock inside it.
    var address = try SocketListener.address(for: path)
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    // All ark-voice processes use the same persistent lock file so stale-path
    // inspection, unlink, bind, chmod, and listen form one startup transaction.
    // The file is intentionally retained: unlinking a flock file can split
    // contenders across two inodes.
    let startupLock = try SocketListener.acquireStartupLock(for: path)
    defer {
      flock(startupLock, LOCK_UN)
      Darwin.close(startupLock)
    }

    if let existing = try SocketListener.fileInfo(at: path) {
      guard SocketListener.isSocket(existing), existing.st_uid == geteuid() else {
        throw SocketError.unsafeExistingPath(path)
      }
      if SocketListener.isLive(path: path) {
        throw SocketError.addressInUse(path)
      }
      guard Darwin.unlink(path) == 0 else { throw SocketError.systemCall("unlink", errno) }
    }

    let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { throw SocketError.systemCall("socket", errno) }
    descriptor = socketDescriptor

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = SocketListener.creationMaskLock.withLock { () -> Int32 in
      let previousMask = umask(0o177)
      defer { umask(previousMask) }
      return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(socketDescriptor, $0, size)
        }
      }
    }
    guard bound == 0 else {
      let code = errno
      Darwin.close(socketDescriptor)
      throw SocketError.systemCall("bind", code)
    }

    guard let createdInfo = try SocketListener.fileInfo(at: path) else {
      Darwin.close(socketDescriptor)
      throw SocketError.systemCall("lstat", ENOENT)
    }
    guard SocketListener.isSocket(createdInfo), createdInfo.st_uid == geteuid() else {
      Darwin.close(socketDescriptor)
      throw SocketError.unsafeExistingPath(path)
    }
    socketIdentity = SocketListener.identity(of: createdInfo)

    // The restrictive umask protects the path from the instant bind creates
    // it; chmod is checked as a second, fail-closed assertion of the contract.
    guard chmod(path, 0o600) == 0 else {
      let code = errno
      Darwin.close(socketDescriptor)
      SocketListener.unlink(path, ifIdentityIs: socketIdentity)
      throw SocketError.systemCall("chmod", code)
    }

    guard listen(socketDescriptor, 16) == 0 else {
      let code = errno
      Darwin.close(socketDescriptor)
      SocketListener.unlink(path, ifIdentityIs: socketIdentity)
      throw SocketError.systemCall("listen", code)
    }
  }

  /// Blocks until a client connects.
  public func accept() throws -> SocketConnection {
    while true {
      let client = Darwin.accept(descriptor, nil, nil)
      if client >= 0 {
        return SocketConnection(descriptor: client, label: "ark-voice.connection.\(client)")
      }
      if errno == EINTR { continue }
      throw SocketError.systemCall("accept", errno)
    }
  }

  public func close() {
    let shouldClose = closedLock.withLock {
      guard !isClosed else { return false }
      isClosed = true
      return true
    }
    guard shouldClose else { return }
    shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
    SocketListener.unlink(path, ifIdentityIs: socketIdentity)
  }

  private static let creationMaskLock = NSLock()

  private static func acquireStartupLock(for path: String) throws -> Int32 {
    let lockPath = path + ".lock"
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw SocketError.systemCall("open", errno) }
    guard fchmod(descriptor, 0o600) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw SocketError.systemCall("fchmod", code)
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw SocketError.systemCall("flock", code)
    }
    return descriptor
  }

  private static func fileInfo(at path: String) throws -> stat? {
    var info = stat()
    if lstat(path, &info) == 0 { return info }
    if errno == ENOENT { return nil }
    throw SocketError.systemCall("lstat", errno)
  }

  private static func isSocket(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFSOCK
  }

  private static func identity(of info: stat) -> FileIdentity {
    FileIdentity(device: info.st_dev, inode: info.st_ino)
  }

  private static func unlink(_ path: String, ifIdentityIs expected: FileIdentity) {
    guard let info = try? fileInfo(at: path), identity(of: info) == expected
    else { return }
    _ = Darwin.unlink(path)
  }

  static func address(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        for (index, byte) in bytes.enumerated() {
          destination[index] = CChar(bitPattern: byte)
        }
        destination[bytes.count] = 0
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }

  static func isLive(path: String) -> Bool {
    guard var address = try? address(for: path) else { return false }
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { return false }
    defer { Darwin.close(probe) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, size) }
    }
    return result == 0
  }
}

/// Connects to a listening ark-voice server.
public func connectToSocket(path: String) throws -> SocketConnection {
  guard FileManager.default.fileExists(atPath: path) else {
    throw SocketError.notRunning(path)
  }
  var address = try SocketListener.address(for: path)
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw SocketError.systemCall("socket", errno) }
  let size = socklen_t(MemoryLayout<sockaddr_un>.size)
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
  }
  guard result == 0 else {
    let code = errno
    Darwin.close(descriptor)
    if code == ECONNREFUSED || code == ENOENT {
      throw SocketError.notRunning(path)
    }
    throw SocketError.systemCall("connect", code)
  }
  return SocketConnection(descriptor: descriptor, label: "ark-voice.client")
}
