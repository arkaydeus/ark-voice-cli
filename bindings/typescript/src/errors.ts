/**
 * Error hierarchy shared by every ark-voice binding.
 *
 * `ArkVoiceError` is the base. `ServerError` and its subclasses carry a
 * protocol `error` event; the others describe the local side of the
 * connection.
 */

/** Error codes the server sends in `error` events. Unknown codes stay plain strings. */
export type ErrorCode =
  | "bad-request"
  | "unsupported-version"
  | "models-missing"
  | "unknown-request"
  | "cancelled"
  | "failed"
  | (string & {});

/** Reasons a frame header or frame stream is rejected. */
export type FrameErrorReason =
  | "bad-magic"
  | "unknown-kind"
  | "unsupported-flags"
  | "payload-too-large"
  | "truncated";

export class ArkVoiceError extends Error {
  static {
    this.prototype.name = "ArkVoiceError";
  }

  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
  }
}

/** An `error` event from the server. `code` is the raw protocol string. */
export class ServerError extends ArkVoiceError {
  static {
    this.prototype.name = "ServerError";
  }
  readonly code: ErrorCode;
  /** The request the error ended; `0` for a connection-level error. */
  readonly requestId: number;

  constructor(code: ErrorCode, message: string, requestId: number) {
    super(message);
    this.code = code;
    this.requestId = requestId;
  }
}

/** `bad-request`: malformed frame, missing field, or no handshake yet. */
export class BadRequestError extends ServerError {
  static {
    this.prototype.name = "BadRequestError";
  }
}

/**
 * `unsupported-version`: the server speaks another protocol version. Also
 * raised client-side when `hello-ok` reports a version this client does not speak.
 */
export class UnsupportedVersionError extends ServerError {
  static {
    this.prototype.name = "UnsupportedVersionError";
  }
}

/** `models-missing`: run `ark-voice download` on the server's machine. */
export class ModelsMissingError extends ServerError {
  static {
    this.prototype.name = "ModelsMissingError";
  }
}

/** `unknown-request`: audio or `end` for a request that is not open. */
export class UnknownRequestError extends ServerError {
  static {
    this.prototype.name = "UnknownRequestError";
  }
}

/** `cancelled`: the request was cancelled. */
export class RequestCancelledError extends ServerError {
  static {
    this.prototype.name = "RequestCancelledError";
  }
}

/** `failed`: anything else; the message carries the detail. */
export class ServerFailedError extends ServerError {
  static {
    this.prototype.name = "ServerFailedError";
  }
}

/** No server is listening on the socket path. */
export class NotRunningError extends ArkVoiceError {
  static {
    this.prototype.name = "NotRunningError";
  }
  readonly socketPath: string;

  constructor(socketPath: string, options?: { cause?: unknown }) {
    super(
      `No ark-voice server is listening on ${socketPath}. Start one with \`ark-voice serve\`.`,
      options,
    );
    this.socketPath = socketPath;
  }
}

/** The connection is closed, or closed while the request was pending. */
export class ConnectionClosedError extends ArkVoiceError {
  static {
    this.prototype.name = "ConnectionClosedError";
  }

  constructor(message = "The connection to the ark-voice server is closed.", options?: { cause?: unknown }) {
    super(message, options);
  }
}

/** The server sent a malformed frame or control message. */
export class ProtocolError extends ArkVoiceError {
  static {
    this.prototype.name = "ProtocolError";
  }
  /** Set for frame errors: one of the `FrameErrorReason` strings. */
  readonly reason: FrameErrorReason | undefined;

  constructor(message: string, reason?: FrameErrorReason, options?: { cause?: unknown }) {
    super(message, options);
    this.reason = reason;
  }
}

const serverErrorClasses: Record<string, typeof ServerError> = {
  "bad-request": BadRequestError,
  "unsupported-version": UnsupportedVersionError,
  "models-missing": ModelsMissingError,
  "unknown-request": UnknownRequestError,
  cancelled: RequestCancelledError,
  failed: ServerFailedError,
};

/** Builds the `ServerError` subclass that matches `code`; unknown codes give a plain `ServerError`. */
export function serverErrorFor(code: ErrorCode, message: string, requestId: number): ServerError {
  const ErrorClass = Object.hasOwn(serverErrorClasses, code) ? serverErrorClasses[code]! : ServerError;
  return new ErrorClass(code, message, requestId);
}
