import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const storage = vi.hoisted(() => ({
  getItemAsync: vi.fn(),
  setItemAsync: vi.fn(),
  deleteItemAsync: vi.fn(),
  AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: "after-first-unlock-this-device-only",
}));
vi.mock("expo-secure-store", () => storage);
vi.mock("../watch/native", () => ({ watchNative: null }));

import {
  deleteWhisperApiKey,
  loadWhisperApiKey,
  saveWhisperApiKey,
  whisperTranscriber,
} from "./whisperTranscription";

const request = vi.fn<typeof fetch>();
let parts: Map<string, unknown>;
const options = () => ({ signal: new AbortController().signal });

beforeEach(() => {
  vi.resetAllMocks();
  storage.getItemAsync.mockResolvedValue("test-api-key");
  vi.stubGlobal("fetch", request);
  parts = new Map();
  vi.stubGlobal(
    "FormData",
    class {
      append(name: string, value: unknown) {
        parts.set(name, value);
      }
    },
  );
  request.mockResolvedValue(
    new Response(JSON.stringify({ text: "  Cześć, let's fix ten bug.  " })),
  );
});
afterEach(() => vi.unstubAllGlobals());

describe("Whisper transcription", () => {
  it("uploads the recording without forcing a language and preserves mixed Polish and English", async () => {
    const prepared = await whisperTranscriber.prepare(options());
    const { signal } = options();
    await expect(prepared.transcribe("file:///recording.m4a", { signal })).resolves.toBe(
      "Cześć, let's fix ten bug.",
    );
    expect(parts).toEqual(
      new Map<string, unknown>([
        ["file", { uri: "file:///recording.m4a", name: "recording.m4a", type: "audio/mp4" }],
        ["model", "whisper-1"],
        ["response_format", "json"],
      ]),
    );
    expect(request).toHaveBeenCalledWith("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      body: expect.anything(),
      headers: { Authorization: "Bearer test-api-key" },
      signal,
    });
  });

  it("migrates an existing key to access after the first unlock", async () => {
    await expect(loadWhisperApiKey()).resolves.toBe("test-api-key");
    expect(storage.setItemAsync).toHaveBeenCalledWith(
      "t3code.voice-input.openai-api-key",
      "test-api-key",
      {
        keychainAccessible: storage.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
      },
    );
  });

  it("serializes key migration with replacement and deletion", async () => {
    let resolve!: (key: string) => void;
    storage.getItemAsync.mockReturnValueOnce(
      new Promise<string>((done) => {
        resolve = done;
      }),
    );
    const loading = loadWhisperApiKey();
    const replacement = saveWhisperApiKey("replacement");
    const deletion = deleteWhisperApiKey();
    await Promise.resolve();
    expect(storage.setItemAsync).not.toHaveBeenCalled();
    resolve("old-key");
    await Promise.all([loading, replacement, deletion]);
    expect(storage.setItemAsync.mock.calls.map((call) => call[1])).toEqual([
      "old-key",
      "replacement",
    ]);
    expect(storage.deleteItemAsync.mock.invocationCallOrder[0]).toBeGreaterThan(
      storage.setItemAsync.mock.invocationCallOrder[1]!,
    );
  });

  it("captures the API key before recording", async () => {
    const prepared = await whisperTranscriber.prepare(options());
    storage.getItemAsync.mockResolvedValue("replacement-key");
    await prepared.transcribe("file:///recording.m4a", options());
    expect(request.mock.calls[0]?.[1]?.headers).toEqual({ Authorization: "Bearer test-api-key" });
    expect(storage.getItemAsync).toHaveBeenCalledTimes(1);
  });

  it("requires a key before recording starts", async () => {
    storage.getItemAsync.mockResolvedValue(" ");
    await expect(whisperTranscriber.prepare(options())).rejects.toThrow("Settings → Microphone");
    expect(request).not.toHaveBeenCalled();
  });

  it("reports Keychain read errors without exposing the underlying error", async () => {
    storage.getItemAsync.mockRejectedValue(new Error("sensitive details"));
    await expect(whisperTranscriber.prepare(options())).rejects.toThrow(
      "Could not read the Whisper API key.",
    );
  });

  it.each([
    [401, "Update it"],
    [429, "API credits"],
    [413, "shorter recording"],
    [500, "Try again"],
  ])("handles HTTP %s without displaying raw server content", async (status, message) => {
    request.mockResolvedValue(new Response("sensitive details", { status }));
    const prepared = await whisperTranscriber.prepare(options());
    await expect(prepared.transcribe("file:///recording.m4a", options())).rejects.toThrow(message);
  });

  it.each([{}, { text: 42 }, null])("rejects invalid transcripts: %s", async (result) => {
    request.mockResolvedValue(new Response(JSON.stringify(result)));
    const prepared = await whisperTranscriber.prepare(options());
    await expect(prepared.transcribe("file:///recording.m4a", options())).rejects.toThrow(
      "invalid transcript",
    );
  });

  it("reports network failures", async () => {
    request.mockRejectedValue(new Error("network failed"));
    const prepared = await whisperTranscriber.prepare(options());
    await expect(prepared.transcribe("file:///recording.m4a", options())).rejects.toThrow(
      "Check your connection",
    );
  });

  it("does not start an upload after cancellation", async () => {
    const prepared = await whisperTranscriber.prepare(options());
    const controller = new AbortController();
    controller.abort();
    await expect(
      prepared.transcribe("file:///recording.m4a", { signal: controller.signal }),
    ).rejects.toMatchObject({ code: "cancelled" });
    expect(request).not.toHaveBeenCalled();
  });

  it("discards a response arriving after cancellation", async () => {
    const prepared = await whisperTranscriber.prepare(options());
    const controller = new AbortController();
    request.mockImplementation(async () => {
      controller.abort();
      return new Response(JSON.stringify({ text: "discard me" }));
    });
    await expect(
      prepared.transcribe("file:///recording.m4a", { signal: controller.signal }),
    ).rejects.toMatchObject({ code: "cancelled" });
  });

  it("stores and deletes the key only in device-local secure storage", async () => {
    await saveWhisperApiKey("  replacement-key  ");
    await deleteWhisperApiKey();
    expect(storage.setItemAsync).toHaveBeenCalledWith(
      "t3code.voice-input.openai-api-key",
      "replacement-key",
      {
        keychainAccessible: storage.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
      },
    );
    expect(storage.deleteItemAsync).toHaveBeenCalledWith("t3code.voice-input.openai-api-key");
  });
});
