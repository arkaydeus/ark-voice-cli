/**
 * Integration tests against a real `ark-voice serve`.
 *
 * Binary: $ARK_VOICE_BINARY, else <repo>/.build/release/ark-voice (with
 * mlx.metallib beside it); without either the whole suite is skipped.
 * Model-backed tests are skipped if the server reports `models-missing`.
 */
import { afterAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, unlinkSync, symlinkSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ArkVoiceClient, ModelsMissingError, PCMAudio, type SynthesisDoneEvent } from "../src/index.js";

const SENTENCE = "The quick brown fox jumps over the lazy dog.";
const MODEL_TIMEOUT = 300_000;

function findBinary(): { path?: string; reason: string } {
  const fromEnv = process.env["ARK_VOICE_BINARY"];
  if (fromEnv) {
    return existsSync(fromEnv) ? { path: fromEnv, reason: "" } : { reason: `ARK_VOICE_BINARY=${fromEnv} does not exist` };
  }
  const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
  const built = join(repoRoot, ".build", "release", "ark-voice");
  if (existsSync(built)) return { path: built, reason: "" };
  return { reason: `set ARK_VOICE_BINARY or build ${built} (swift build -c release)` };
}

interface RunningServer {
  process: ChildProcess;
  dir: string;
  socketPath: string;
  log: string[];
}

async function startServer(binary: string): Promise<RunningServer> {
  // Under /tmp, not $TMPDIR: macOS caps socket paths at 104 bytes.
  const dir = mkdtempSync("/tmp/arkv-ts-it-");
  const socketPath = join(dir, "ark-voice.sock");
  const log: string[] = [];
  let child: ChildProcess | undefined;
  try {
    const models = join(homedir(), ".ark-voice-cli", "mlx-audio");
    if (existsSync(models)) symlinkSync(models, join(dir, "mlx-audio"), "dir");
    const spawned = spawn(binary, ["serve", "--model-root", dir, "--socket", socketPath, "--idle-unload", "off"], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    child = spawned;
    spawned.stdout?.on("data", (chunk: Buffer) => log.push(chunk.toString()));
    spawned.stderr?.on("data", (chunk: Buffer) => log.push(chunk.toString()));
    await new Promise<void>((resolve, reject) => {
      spawned.once("spawn", resolve);
      spawned.once("error", reject);
    });
    const deadline = Date.now() + 15_000;
    while (!existsSync(socketPath)) {
      if (spawned.exitCode !== null || spawned.signalCode !== null) {
        throw new Error(`ark-voice serve exited early (${spawned.exitCode ?? spawned.signalCode}):\n${log.join("")}`);
      }
      if (Date.now() > deadline) {
        throw new Error(`ark-voice serve did not create ${socketPath} within 15 s:\n${log.join("")}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return { process: spawned, dir, socketPath, log };
  } catch (error) {
    if (child?.pid) await stopServer({ process: child, dir, socketPath, log });
    else rmSync(dir, { recursive: true, force: true });
    throw error;
  }
}

async function stopServer(server: RunningServer): Promise<void> {
  const { process: child } = server;
  if (child.exitCode === null && child.signalCode === null) {
    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
    await exited;
    clearTimeout(timer);
  }
  rmSync(server.dir, { recursive: true, force: true });
}

const binary = findBinary();
let server: RunningServer | undefined;
let synthesisSkip = "";
let transcriptionSkip = "";

if (binary.path) {
  server = await startServer(binary.path);
  try {
    // Probe once so model-backed tests can be skipped (not failed) when models are missing.
    const probe = await ArkVoiceClient.connect({ socketPath: server.socketPath });
    try {
      try {
        await probe.synthesizeAudio("Hi.");
      } catch (error) {
        if (!(error instanceof ModelsMissingError)) throw error;
        synthesisSkip = `synthesis models missing: ${error.message}`;
      }
      try {
        await probe.transcribeText(PCMAudio.fromSamples(new Float32Array(8000), 16000));
      } catch (error) {
        if (!(error instanceof ModelsMissingError)) throw error;
        transcriptionSkip = `transcription model missing: ${error.message}`;
      }
    } finally {
      await probe.close();
    }
  } catch (error) {
    await stopServer(server);
    server = undefined;
    throw error;
  }
} else {
  console.warn(`[integration] SKIPPED: no ark-voice binary (${binary.reason})`);
}
if (synthesisSkip) console.warn(`[integration] SKIPPING model-backed synthesis tests: ${synthesisSkip}`);
if (transcriptionSkip) console.warn(`[integration] SKIPPING transcription test: ${transcriptionSkip}`);

afterAll(async () => {
  if (server) await stopServer(server);
});

async function withClient<T>(body: (client: ArkVoiceClient) => Promise<T>): Promise<T> {
  const client = await ArkVoiceClient.connect({ socketPath: server!.socketPath });
  try {
    return await body(client);
  } finally {
    await client.close();
  }
}

let speech: Promise<PCMAudio> | undefined;
/** The test sentence, synthesized once and shared. */
function sentenceAudio(): Promise<PCMAudio> {
  speech ??= withClient(async (client) => (await client.synthesizeAudio(SENTENCE)).audio);
  return speech;
}

describe.skipIf(!binary.path)("ark-voice serve", () => {
  test.skipIf(!!synthesisSkip)("profile root is removed after an injected failure", async () => {
    const voices = join(homedir(), ".ark-voice-cli", "voices");
    const snapshot = (): Array<[string, string]> => existsSync(voices)
      ? readdirSync(voices).sort().map((name) => [name, readFileSync(join(voices, name)).toString("base64")])
      : [];
    const before = snapshot();
    const isolated = await startServer(binary.path!);
    let connected: ArkVoiceClient | undefined;
    const failure = new Error("injected after voice creation");
    try {
      connected = await ArkVoiceClient.connect({ socketPath: isolated.socketPath });
      const saved = await connected.createVoice("failure-test", await sentenceAudio());
      expect(dirname(saved)).toBe(join(isolated.dir, "voices"));
      expect(existsSync(saved)).toBe(true);
      throw failure;
    } catch (error) {
      expect(error).toBe(failure);
    } finally {
      await connected?.close();
      await stopServer(isolated);
      expect(existsSync(isolated.dir)).toBe(false);
      expect(snapshot()).toEqual(before);
    }
  }, MODEL_TIMEOUT);

  test("connect, status, voices, unload", async () => {
    await withClient(async (client) => {
      expect(client.serverVersion).toBe(1);
      expect(client.sampleRate).toBe(24000);
      expect(client.socketPath).toBe(server!.socketPath);
      const status = await client.status();
      expect(status.version).toBe(1);
      expect(typeof status.synthesisModelLoaded).toBe("boolean");
      expect(status.requestsServed).toBeGreaterThan(0);
      expect(status.uptimeSeconds).toBeGreaterThan(0);
      expect(Array.isArray(await client.voices())).toBe(true);
      await client.unload();
      const after = await client.status();
      expect(after.synthesisModelLoaded).toBe(false);
      expect(after.transcriptionModelLoaded).toBe(false);
      expect(after.transcriptionModel).toBeNull();
    });
  });

  test.skipIf(Boolean(synthesisSkip))(
    "streams a synthesis and writes it as WAV",
    async () => {
      await withClient(async (client) => {
        const chunks: PCMAudio[] = [];
        let done: SynthesisDoneEvent | undefined;
        for await (const event of client.synthesize(SENTENCE)) {
          if (event.type === "audio") {
            expect(event.index).toBe(chunks.length);
            expect(event.audio.sampleRate).toBe(24000);
            expect(event.audio.format).toBe("s16le");
            chunks.push(event.audio);
          } else {
            done = event;
          }
        }
        expect(chunks.length).toBeGreaterThan(0);
        expect(done).toBeDefined();
        expect(done!.sampleRate).toBe(24000);
        expect(done!.chunks).toBe(chunks.length);
        const audio = PCMAudio.concat(chunks);
        expect(audio.sampleCount).toBe(done!.samples);
        expect(audio.duration).toBeGreaterThan(1);

        const dir = mkdtempSync("/tmp/arkv-ts-it-wav-");
        try {
          const path = join(dir, "fox.wav");
          await audio.writeWav(path);
          const back = await PCMAudio.readWav(path);
          expect(back.sampleRate).toBe(24000);
          expect(back.sampleCount).toBe(done!.samples);
          expect(back.data).toEqual(audio.data);
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      });
    },
    MODEL_TIMEOUT,
  );

  test.skipIf(Boolean(synthesisSkip || transcriptionSkip))(
    "transcribes the synthesized sentence with the default model",
    async () => {
      const audio = await sentenceAudio();
      expect(audio.sampleRate).toBe(24000);
      const text = await withClient(async (client) => {
        let final = "";
        for await (const event of client.transcribe(audio)) {
          if (event.type === "final") final = event.text;
        }
        return final;
      });
      const words = text.toLowerCase();
      expect(["quick", "brown", "fox", "lazy", "dog"].some((word) => words.includes(word))).toBe(true);
    },
    MODEL_TIMEOUT,
  );

  test.skipIf(Boolean(synthesisSkip))(
    "pipelines status, voices and a synthesis on one connection",
    async () => {
      await withClient(async (client) => {
        const synthesis = client.synthesizeAudio("Pipelining works.");
        const status = client.status();
        const voices = client.voices();
        const [synthesized, statusResult, names] = await Promise.all([synthesis, status, voices]);
        expect(synthesized.audio.sampleCount).toBe(synthesized.summary.samples);
        expect(synthesized.summary.samples).toBeGreaterThan(0);
        expect(statusResult.version).toBe(1);
        expect(Array.isArray(names)).toBe(true);
      });
    },
    MODEL_TIMEOUT,
  );

  test.skipIf(Boolean(synthesisSkip))(
    "stopping after the first chunk cancels, and the connection keeps working",
    async () => {
      const longText = Array.from({ length: 12 }, () => SENTENCE).join(" ");
      await withClient(async (client) => {
        let chunks = 0;
        const stream = client.synthesize(longText);
        for await (const event of stream) {
          if (event.type === "audio") chunks++;
          break;
        }
        expect(chunks).toBe(1);
        const status = await client.status();
        expect(status.version).toBe(1);
        // A following synthesis on the same connection still completes.
        const { summary } = await client.synthesizeAudio("Still here.");
        expect(summary.samples).toBeGreaterThan(0);
      });
    },
    MODEL_TIMEOUT,
  );

  test.skipIf(Boolean(synthesisSkip))(
    "creates a voice profile, lists it, and deletes it",
    async () => {
      const name = `bindings-test-ts-${Math.random().toString(36).slice(2, 10)}`;
      const audio = await sentenceAudio();
      const voicesDir = resolve(server!.dir, "voices");
      let path = "";
      try {
        await withClient(async (client) => {
          path = await client.createVoice(name, audio);
          expect(path).not.toBe("");
          expect(await client.voices()).toContain(name);
        });
      } finally {
        // Delete only this test's profile in the isolated server root.
        if (path) {
          const resolved = resolve(path);
          if (dirname(resolved) === voicesDir && basename(resolved, extname(resolved)) === name && existsSync(resolved)) {
            unlinkSync(resolved);
          }
        }
      }
      expect(existsSync(path)).toBe(false);
      await withClient(async (client) => {
        expect(await client.voices()).not.toContain(name);
      });
    },
    MODEL_TIMEOUT,
  );
});
