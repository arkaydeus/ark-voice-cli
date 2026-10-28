import { homedir } from "node:os";
import { join } from "node:path";

/** The server's default socket: `~/.ark-voice-cli/ark-voice.sock`. */
export function defaultSocketPath(): string {
  return join(homedir(), ".ark-voice-cli", "ark-voice.sock");
}

/**
 * Resolves the socket to use: an explicit path, else `ARK_VOICE_SOCKET`,
 * else the default.
 */
export function resolveSocketPath(explicit?: string): string {
  if (explicit) return explicit;
  const fromEnv = process.env["ARK_VOICE_SOCKET"];
  if (fromEnv) return fromEnv;
  return defaultSocketPath();
}
