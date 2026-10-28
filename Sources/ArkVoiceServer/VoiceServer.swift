import ArkVoiceClient
import ArkVoiceKit
import Foundation

struct AudioBufferLimits: Sendable {
  var perRequestSamples = 16_000 * 60 * 30
  var totalSamples = 16_000 * 60 * 30
  var streamCount = 8
}

/// A daemon that keeps models resident and serves synthesis and transcription
/// over a Unix-domain socket.
///
/// The point of the daemon is amortization: a process-per-call design reloads
/// roughly a gigabyte of weights for every request, which dominates the cost of
/// short utterances. Here the load happens once and every later request pays
/// only for inference.
///
/// Requests may be pipelined — several can be in flight on one connection, and
/// responses carry the request identifier they belong to — but model work still
/// runs one at a time, because the models cannot run concurrently.
public final class VoiceServer: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var socketPath: String
    /// Release models after this many idle seconds. `nil` keeps them forever.
    public var idleUnloadSeconds: Double?
    /// Exit after this many idle seconds. `nil` runs until stopped.
    public var idleExitSeconds: Double?
    /// Receives server diagnostics.
    public var log: (@Sendable (String) -> Void)?
    var audioBufferLimits = AudioBufferLimits()

    public init(
      socketPath: String,
      idleUnloadSeconds: Double? = 300,
      idleExitSeconds: Double? = nil,
      log: (@Sendable (String) -> Void)? = nil
    ) {
      self.socketPath = socketPath
      self.idleUnloadSeconds = idleUnloadSeconds
      self.idleExitSeconds = idleExitSeconds
      self.log = log
    }
  }

  private let session: VoiceSession
  private let configuration: Configuration

  private let stateLock = NSLock()
  private var listener: SocketListener?
  private var connections: [ObjectIdentifier: ConnectionHandler] = [:]
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var hasStopped = false
  private var activeRequests = 0
  private var bufferedSamples = 0
  private var requestsServed = 0
  private var lastActivity = Date()
  private var modelsUnloadedWhileIdle = false
  private let startedAt = Date()

  public init(session: VoiceSession, configuration: Configuration) {
    self.session = session
    self.configuration = configuration
  }

  /// Binds the socket and serves until ``stop()``.
  public func run() async throws {
    let listener = try SocketListener(path: configuration.socketPath)
    stateLock.withLock { self.listener = listener }
    configuration.log?("Listening on \(listener.path)")

    startAcceptLoop(on: listener)
    let monitor = startIdleMonitor()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let alreadyStopped = stateLock.withLock { () -> Bool in
        if hasStopped { return true }
        stopContinuation = continuation
        return false
      }
      if alreadyStopped { continuation.resume() }
    }

    monitor.cancel()
    listener.close()
    let openConnections = stateLock.withLock { Array(connections.values) }
    for connection in openConnections { connection.close() }
    configuration.log?("Stopped")
  }

  /// Stops serving. Safe to call from a signal handler's dispatch source.
  public func stop() {
    let continuation = stateLock.withLock { () -> CheckedContinuation<Void, Never>? in
      guard !hasStopped else { return nil }
      hasStopped = true
      let pending = stopContinuation
      stopContinuation = nil
      return pending
    }
    stateLock.withLock { listener }?.close()
    continuation?.resume()
  }

  private func startAcceptLoop(on listener: SocketListener) {
    let thread = Thread { [weak self] in
      while true {
        guard let self else { return }
        do {
          let connection = try listener.accept()
          self.adopt(connection)
        } catch {
          // A closed listener ends the loop; anything else is fatal to serving.
          if self.stateLock.withLock({ self.hasStopped }) { return }
          self.configuration.log?("Accept failed: \(error.localizedDescription)")
          self.stop()
          return
        }
      }
    }
    thread.name = "ark-voice.accept"
    thread.start()
  }

  private func adopt(_ connection: SocketConnection) {
    let handler = ConnectionHandler(
      connection: connection,
      session: session,
      server: self,
      audioBufferLimits: configuration.audioBufferLimits
    )
    stateLock.withLock { connections[ObjectIdentifier(handler)] = handler }
    configuration.log?("Client connected")
    handler.start()
  }

  fileprivate func forget(_ handler: ConnectionHandler) {
    stateLock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(handler)) }
    configuration.log?("Client disconnected")
  }

  fileprivate func noteActivity() {
    stateLock.withLock {
      guard !hasStopped else { return }
      lastActivity = Date()
    }
  }

  @discardableResult
  fileprivate func requestStarted() -> Bool {
    stateLock.withLock {
      guard !hasStopped else { return false }
      activeRequests += 1
      requestsServed += 1
      lastActivity = Date()
      modelsUnloadedWhileIdle = false
      return true
    }
  }

  fileprivate func requestFinished() {
    stateLock.withLock {
      activeRequests = max(0, activeRequests - 1)
      lastActivity = Date()
    }
  }

  fileprivate func reserveBufferedSamples(_ count: Int) -> Bool {
    stateLock.withLock {
      guard bufferedSamples + count <= configuration.audioBufferLimits.totalSamples else {
        return false
      }
      bufferedSamples += count
      return true
    }
  }

  fileprivate func releaseBufferedSamples(_ count: Int) {
    stateLock.withLock { bufferedSamples = max(0, bufferedSamples - count) }
  }

  func statusMessage() -> ServerMessage {
    var message = ServerMessage(event: .status)
    message.version = arkVoiceProtocolVersion
    message.synthesisModelLoaded = session.isSynthesisModelLoaded
    message.transcriptionModelLoaded = session.isTranscriptionModelLoaded
    message.transcriptionModel = session.loadedTranscriptionModel?.rawValue
    message.requestsServed = stateLock.withLock { requestsServed }
    message.uptimeSeconds = Date().timeIntervalSince(startedAt)
    return message
  }

  fileprivate func unloadModels(
    if condition: @escaping @Sendable () -> Bool = { true }
  ) async -> Bool {
    await session.unloadModels(if: condition)
  }

  private func startIdleMonitor() -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let configuredIntervals = [
          self.configuration.idleUnloadSeconds,
          self.configuration.idleExitSeconds,
        ].compactMap { $0 }
        let pollSeconds = min(5, max(0.05, (configuredIntervals.min() ?? 10) / 2))
        try? await Task.sleep(for: .seconds(pollSeconds))
        if Task.isCancelled { return }
        let (idleFor, isBusy, alreadyUnloaded) = self.stateLock.withLock {
          (Date().timeIntervalSince(self.lastActivity), self.activeRequests > 0,
            self.modelsUnloadedWhileIdle)
        }
        guard !isBusy else { continue }

        if let unloadAfter = self.configuration.idleUnloadSeconds,
          idleFor >= unloadAfter,
          !alreadyUnloaded,
          self.session.isSynthesisModelLoaded || self.session.isTranscriptionModelLoaded
        {
          let didUnload = await self.session.unloadModels {
            self.stateLock.withLock {
              guard !self.hasStopped, self.activeRequests == 0,
                Date().timeIntervalSince(self.lastActivity) >= unloadAfter,
                !self.modelsUnloadedWhileIdle
              else { return false }
              self.modelsUnloadedWhileIdle = true
              return true
            }
          }
          if didUnload {
            self.configuration.log?(
              "Released models after \(Int(idleFor))s idle; the next request reloads them.")
          }
        }

        if let exitAfter = self.configuration.idleExitSeconds, idleFor >= exitAfter {
          if self.stopIfStillIdle(after: exitAfter) {
            self.configuration.log?("Exiting after \(Int(idleFor))s idle.")
            return
          }
        }
      }
    }
  }

  /// Atomically claims the idle-exit transition. Once claimed, requestStarted
  /// refuses new work, closing the observation-to-stop race in the monitor.
  private func stopIfStillIdle(after interval: Double) -> Bool {
    var continuation: CheckedContinuation<Void, Never>?
    var listenerToClose: SocketListener?
    let shouldStop = stateLock.withLock { () -> Bool in
      guard !hasStopped, activeRequests == 0,
        Date().timeIntervalSince(lastActivity) >= interval
      else { return false }
      hasStopped = true
      continuation = stopContinuation
      stopContinuation = nil
      listenerToClose = listener
      return true
    }
    guard shouldStop else { return false }
    listenerToClose?.close()
    continuation?.resume()
    return true
  }
}

/// Serves one client connection.
///
/// Frames are read on a dedicated thread and handed to a consumer task, so a
/// long generation never stops the connection from receiving the `cancel` that
/// would end it.
private final class ConnectionHandler: @unchecked Sendable {
  private struct PendingAudio {
    var operation: ClientOperation
    var format: PCMSampleFormat
    var sampleRate: Int
    var name: String?
    var model: TranscriptionModel?
    var samples: [Float] = []
  }

  private let connection: SocketConnection
  private let session: VoiceSession
  // The reader can outlive `run()` while the socket is closing. Keep the
  // server alive until `close()` removes this handler from its connection set.
  private let server: VoiceServer
  private let audioBufferLimits: AudioBufferLimits

  private let stateLock = NSLock()
  private var pending: [UInt32: PendingAudio] = [:]
  private var pendingSampleCount = 0
  private var inFlight: Set<UInt32> = []
  private var tasks: [UInt32: Task<Void, Never>] = [:]
  /// Requests that finished before their task could be recorded. Without this,
  /// a connection making thousands of requests would keep a dead task for each.
  private var completedBeforeRecording: Set<UInt32> = []
  private var didHandshake = false
  private var isClosed = false

  init(
    connection: SocketConnection,
    session: VoiceSession,
    server: VoiceServer,
    audioBufferLimits: AudioBufferLimits
  ) {
    self.connection = connection
    self.session = session
    self.server = server
    self.audioBufferLimits = audioBufferLimits
  }

  func start() {
    let (frames, continuation) = AsyncStream<Frame>.makeStream()

    let thread = Thread { [weak self] in
      guard let self else { return }
      while true {
        do {
          continuation.yield(try self.connection.readFrame())
        } catch {
          if case FrameError.connectionClosed = error {
            // Ordinary disconnect.
          } else {
            var message = ServerMessage(event: .error)
            message.code = .badRequest
            message.message = error.localizedDescription
            self.connection.sendSynchronously(
              Frame(kind: .json, requestID: 0, payload: ProtocolCoder.encode(message)))
          }
          continuation.finish()
          return
        }
      }
    }
    thread.name = "ark-voice.reader"
    thread.start()

    Task { [weak self] in
      for await frame in frames {
        guard let self else { return }
        self.handle(frame)
      }
      self?.close()
    }
  }

  func close() {
    let state = stateLock.withLock { () -> (Bool, [Task<Void, Never>], Int, Int) in
      guard !isClosed else { return (false, [], 0, 0) }
      isClosed = true
      let running = Array(tasks.values)
      let abandonedUploads = pending.count
      let abandonedSamples = pendingSampleCount
      pending.removeAll()
      pendingSampleCount = 0
      inFlight.removeAll()
      return (true, running, abandonedUploads, abandonedSamples)
    }
    guard state.0 else { return }
    server.releaseBufferedSamples(state.3)
    for _ in 0..<state.2 { server.requestFinished() }
    for task in state.1 { task.cancel() }
    connection.close()
    server.forget(self)
  }

  // MARK: - Frame handling

  private func handle(_ frame: Frame) {
    server.noteActivity()
    switch frame.kind {
    case .pcm:
      appendAudio(frame.payload, to: frame.requestID)
    case .json:
      do {
        let message = try ProtocolCoder.decodeClient(frame.payload)
        handle(message, requestID: frame.requestID)
      } catch {
        send(.error, requestID: frame.requestID) {
          $0.code = .badRequest
          $0.message = "Could not decode control message: \(error.localizedDescription)"
        }
      }
    }
  }

  private func handle(_ message: ClientMessage, requestID: UInt32) {
    // The handshake is what makes the version field meaningful, so nothing else
    // is served until it has happened.
    if message.op != .hello, !stateLock.withLock({ didHandshake }) {
      send(.error, requestID: requestID) {
        $0.code = .badRequest
        $0.message = "Send 'hello' before any other operation."
        $0.version = arkVoiceProtocolVersion
      }
      return
    }

    if message.op != .end, message.op != .cancel,
      stateLock.withLock({ inFlight.contains(requestID) })
    {
      send(.error, requestID: requestID) {
        $0.code = .badRequest
        $0.message = "Request \(requestID) is already in flight."
      }
      return
    }

    switch message.op {
    case .hello:
      guard reserveImmediateRequest(requestID) else { return }
      defer { finishImmediateRequest(requestID) }
      let version = message.version ?? arkVoiceProtocolVersion
      guard version == arkVoiceProtocolVersion else {
        send(.error, requestID: requestID) {
          $0.code = .unsupportedVersion
          $0.message = "This server speaks protocol version \(arkVoiceProtocolVersion)."
          $0.version = arkVoiceProtocolVersion
        }
        return
      }
      stateLock.withLock { didHandshake = true }
      send(.helloOK, requestID: requestID) {
        $0.version = arkVoiceProtocolVersion
        $0.sampleRate = VoiceSession.synthesisSampleRate
      }

    case .tts:
      guard let text = message.text, !text.isEmpty else {
        send(.error, requestID: requestID) {
          $0.code = .badRequest
          $0.message = "tts requires 'text'."
        }
        return
      }
      let voice: VoiceSelection = message.voice.map { .named($0) } ?? .standard
      let format = message.format ?? .s16le
      startTask(requestID) { [weak self] in
        await self?.runSynthesis(text: text, voice: voice, format: format, requestID: requestID)
      }

    case .stt:
      var model: TranscriptionModel?
      if let name = message.model {
        guard let known = TranscriptionModel(rawValue: name) else {
          send(.error, requestID: requestID) {
            $0.code = .badRequest
            $0.message =
              "Unknown model '\(name)'. Use \(TranscriptionModel.optionsDescription)."
          }
          return
        }
        model = known
      }
      beginPendingAudio(
        .stt,
        requestID: requestID,
        format: message.format ?? .s16le,
        sampleRate: message.sampleRate ?? VoiceSession.transcriptionSampleRate,
        name: nil,
        model: model
      )

    case .createVoice:
      guard let name = message.name ?? message.voice else {
        send(.error, requestID: requestID) {
          $0.code = .badRequest
          $0.message = "create-voice requires 'name'."
        }
        return
      }
      beginPendingAudio(
        .createVoice,
        requestID: requestID,
        format: message.format ?? .s16le,
        sampleRate: message.sampleRate ?? VoiceSession.synthesisSampleRate,
        name: name,
        model: nil
      )

    case .end:
      let audio = stateLock.withLock { () -> PendingAudio? in
        guard let audio = pending.removeValue(forKey: requestID) else { return nil }
        pendingSampleCount -= audio.samples.count
        return audio
      }
      guard let audio else {
        send(.error, requestID: requestID) {
          $0.code = .unknownRequest
          $0.message = "No audio stream is open for request \(requestID)."
        }
        return
      }
      server.releaseBufferedSamples(audio.samples.count)
      startTask(requestID, alreadyReserved: true, alreadyActive: true) { [weak self] in
        switch audio.operation {
        case .createVoice:
          await self?.runVoiceCreation(audio, requestID: requestID)
        default:
          await self?.runTranscription(audio, requestID: requestID)
        }
      }

    case .voices:
      guard reserveImmediateRequest(requestID) else { return }
      defer { finishImmediateRequest(requestID) }
      do {
        let names = try session.voiceNames()
        send(.voices, requestID: requestID) { $0.names = names }
      } catch {
        send(.error, requestID: requestID) {
          $0.code = .failed
          $0.message = error.localizedDescription
        }
      }

    case .status:
      guard reserveImmediateRequest(requestID) else { return }
      defer { finishImmediateRequest(requestID) }
      var status = server.statusMessage()
      status.event = .status
      connection.send(Frame(kind: .json, requestID: requestID, payload: ProtocolCoder.encode(status)))

    case .unload:
      startTask(requestID) { [weak self] in
        guard let self else { return }
        let unloaded = await self.server.unloadModels { !Task.isCancelled }
        if unloaded, !Task.isCancelled {
          self.send(.done, requestID: requestID) { _ in }
        } else {
          self.sendFailure(CancellationError(), requestID: requestID)
        }
      }

    case .cancel:
      let cancellation = stateLock.withLock { () -> (PendingAudio?, Task<Void, Never>?) in
        if let audio = pending.removeValue(forKey: requestID) {
          pendingSampleCount -= audio.samples.count
          inFlight.remove(requestID)
          return (audio, nil)
        }
        return (nil, tasks[requestID])
      }
      if cancellation.0 != nil {
        server.releaseBufferedSamples(cancellation.0?.samples.count ?? 0)
        server.requestFinished()
        send(.error, requestID: requestID) {
          $0.code = .cancelled
          $0.message = "Request \(requestID) was cancelled."
        }
        return
      }
      guard let task = cancellation.1 else {
        send(.error, requestID: requestID) {
          $0.code = .unknownRequest
          $0.message = "Request \(requestID) is not running."
        }
        return
      }
      task.cancel()
    }
  }

  private func beginPendingAudio(
    _ operation: ClientOperation,
    requestID: UInt32,
    format: PCMSampleFormat,
    sampleRate: Int,
    name: String?,
    model: TranscriptionModel?
  ) {
    guard sampleRate > 0 else {
      send(.error, requestID: requestID) {
        $0.code = .badRequest
        $0.message = "Audio sample rate must be positive."
      }
      return
    }
    guard server.requestStarted() else { return }
    let refusal = stateLock.withLock { () -> String? in
      guard !isClosed else { return "The connection is closed." }
      guard !inFlight.contains(requestID) else {
        return "Request \(requestID) is already in flight."
      }
      guard pending.count < audioBufferLimits.streamCount else {
        return "Too many audio streams are open; finish or cancel one before starting another."
      }
      inFlight.insert(requestID)
      pending[requestID] = PendingAudio(
        operation: operation,
        format: format,
        sampleRate: sampleRate,
        name: name,
        model: model
      )
      return nil
    }
    if let refusal {
      server.requestFinished()
      send(.error, requestID: requestID) {
        $0.code = .badRequest
        $0.message = refusal
      }
    }
  }

  private func appendAudio(_ payload: Data, to requestID: UInt32) {
    let format = stateLock.withLock { pending[requestID]?.format }
    guard let format else {
      send(.error, requestID: requestID) {
        $0.code = .unknownRequest
        $0.message = "Audio arrived for request \(requestID), which is not accepting audio."
      }
      return
    }

    do {
      let samples = try AudioDecoding.samples(from: payload, format: format)
      let appendResult = stateLock.withLock { () -> (overflowed: Bool, released: Int) in
        guard var entry = pending[requestID] else { return (false, 0) }
        guard entry.samples.count + samples.count <= audioBufferLimits.perRequestSamples,
          pendingSampleCount + samples.count <= audioBufferLimits.totalSamples,
          server.reserveBufferedSamples(samples.count)
        else {
          pendingSampleCount -= entry.samples.count
          pending.removeValue(forKey: requestID)
          inFlight.remove(requestID)
          return (true, entry.samples.count)
        }
        entry.samples.append(contentsOf: samples)
        pendingSampleCount += samples.count
        pending[requestID] = entry
        return (false, 0)
      }
      server.releaseBufferedSamples(appendResult.released)
      if appendResult.overflowed {
        server.requestFinished()
        send(.error, requestID: requestID) {
          $0.code = .badRequest
          $0.message = "Buffered audio exceeded the connection limit; send 'end' sooner."
        }
      }
    } catch {
      let removed = stateLock.withLock { () -> Bool in
        guard let audio = pending.removeValue(forKey: requestID) else { return false }
        pendingSampleCount -= audio.samples.count
        inFlight.remove(requestID)
        server.releaseBufferedSamples(audio.samples.count)
        return true
      }
      if removed { server.requestFinished() }
      send(.error, requestID: requestID) {
        $0.code = .badRequest
        $0.message = error.localizedDescription
      }
    }
  }

  private func startTask(
    _ requestID: UInt32,
    alreadyReserved: Bool = false,
    alreadyActive: Bool = false,
    _ body: @escaping @Sendable () async -> Void
  ) {
    if !alreadyReserved {
      let reserved = stateLock.withLock { () -> Bool in
        guard !isClosed, !inFlight.contains(requestID) else { return false }
        inFlight.insert(requestID)
        return true
      }
      guard reserved else {
        send(.error, requestID: requestID) {
          $0.code = .badRequest
          $0.message = "Request \(requestID) is already in flight."
        }
        return
      }
    }
    if !alreadyActive, !server.requestStarted() {
      stateLock.withLock { _ = inFlight.remove(requestID) }
      return
    }
    let requestServer = server
    let task = Task { [weak self, requestServer] in
      defer { requestServer.requestFinished() }
      await body()
      guard let self else { return }
      stateLock.withLock {
        inFlight.remove(requestID)
        if tasks.removeValue(forKey: requestID) == nil {
          // The work outran the bookkeeping below; tell it not to file this one.
          completedBeforeRecording.insert(requestID)
        }
      }
    }
    stateLock.withLock {
      if completedBeforeRecording.remove(requestID) == nil {
        tasks[requestID] = task
      }
    }
  }

  private func reserveImmediateRequest(_ requestID: UInt32) -> Bool {
    let reserved = stateLock.withLock { () -> Bool in
      guard !isClosed, !inFlight.contains(requestID) else { return false }
      inFlight.insert(requestID)
      return true
    }
    if !reserved {
      send(.error, requestID: requestID) {
        $0.code = .badRequest
        $0.message = "Request \(requestID) is already in flight."
      }
    }
    return reserved
  }

  private func finishImmediateRequest(_ requestID: UInt32) {
    stateLock.withLock { _ = inFlight.remove(requestID) }
  }

  // MARK: - Work

  private func runSynthesis(
    text: String,
    voice: VoiceSelection,
    format: PCMSampleFormat,
    requestID: UInt32
  ) async {
    do {
      var chunkCount = 0
      var sampleCount = 0
      var sentFormat = false

      for try await chunk in session.synthesize(text, voice: voice) {
        try Task.checkCancellation()
        if !sentFormat {
          send(.audioFormat, requestID: requestID) {
            $0.sampleRate = chunk.sampleRate
            $0.format = format
          }
          sentFormat = true
        }
        connection.send(
          Frame(
            kind: .pcm,
            requestID: requestID,
            payload: AudioDecoding.data(from: chunk.samples, format: format)
          )
        )
        chunkCount += 1
        sampleCount += chunk.samples.count
      }

      let rate = Double(VoiceSession.synthesisSampleRate)
      send(.done, requestID: requestID) {
        $0.chunks = chunkCount
        $0.samples = sampleCount
        $0.seconds = Double(sampleCount) / rate
      }
    } catch {
      sendFailure(error, requestID: requestID)
    }
  }

  private func runTranscription(_ audio: PendingAudio, requestID: UInt32) async {
    do {
      let samples = try AudioDecoding.resample(
        audio.samples,
        from: audio.sampleRate,
        to: VoiceSession.transcriptionSampleRate
      )
      for try await event in session.transcribe(samples: samples, model: audio.model) {
        try Task.checkCancellation()
        switch event {
        case .partial(let text):
          send(.partial, requestID: requestID) { $0.text = text }
        case .final(let text):
          send(.final, requestID: requestID) { $0.text = text }
        }
      }
      send(.done, requestID: requestID) { _ in }
    } catch {
      sendFailure(error, requestID: requestID)
    }
  }

  private func runVoiceCreation(_ audio: PendingAudio, requestID: UInt32) async {
    do {
      try Task.checkCancellation()
      guard let name = audio.name else {
        throw VoiceStoreError.invalidName("")
      }
      let samples = try AudioDecoding.resample(
        audio.samples,
        from: audio.sampleRate,
        to: VoiceSession.synthesisSampleRate
      )
      let url = try await session.createVoice(name: name, referenceSamples: samples)
      try Task.checkCancellation()
      send(.voiceCreated, requestID: requestID) { $0.path = url.path }
      send(.done, requestID: requestID) { _ in }
    } catch {
      sendFailure(error, requestID: requestID)
    }
  }

  private func sendFailure(_ error: Error, requestID: UInt32) {
    if error is CancellationError {
      send(.error, requestID: requestID) {
        $0.code = .cancelled
        $0.message = "Request \(requestID) was cancelled."
      }
      return
    }
    let code: ServerErrorCode
    if case ModelStoreError.missingModels = error {
      code = .modelsMissing
    } else {
      code = .failed
    }
    send(.error, requestID: requestID) {
      $0.code = code
      $0.message = error.localizedDescription
    }
  }

  private func send(
    _ event: ServerEvent,
    requestID: UInt32,
    _ configure: (inout ServerMessage) -> Void
  ) {
    var message = ServerMessage(event: event)
    configure(&message)
    connection.send(
      Frame(kind: .json, requestID: requestID, payload: ProtocolCoder.encode(message))
    )
  }
}
