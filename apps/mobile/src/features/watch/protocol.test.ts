import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as Schema from "effect/Schema";
import * as Effect from "effect/Effect";
import * as HostProcess from "@t3tools/shared/HostProcess";
import { describe, expect, it } from "@effect/vitest";
import {
  WatchRequest,
  WatchSnapshot,
  WatchTranscriptionContext,
  WatchAudioTransferMetadata,
  WatchTranscriptionControl,
} from "@t3tools/contracts/watch-companion";
import { encodeWatchSnapshot } from "./model";

const decodeRequest = Schema.decodeUnknownSync(WatchRequest);
const decodeSnapshot = Schema.decodeUnknownSync(WatchSnapshot);
const decodeTranscription = Schema.decodeUnknownSync(WatchTranscriptionContext);
const decodeAudio = Schema.decodeUnknownSync(WatchAudioTransferMetadata);
const decodeTranscriptionControl = Schema.decodeUnknownSync(WatchTranscriptionControl);
const fixture = {
  version: 1,
  updatedAt: "2026-10-15T10:00:00.000Z",
  threadOffset: 0,
  hasMoreThreads: false,
  threads: [
    {
      environmentId: "remote",
      threadId: "thread",
      title: "Investigate a bug",
      projectTitle: "T3 Code",
      environmentTitle: "Laptop",
      status: "running",
      updatedAt: "2026-10-15T10:00:00.000Z",
      lastActivityAt: "2026-10-14T10:00:00.000Z",
      canReply: true,
    },
  ],
  projectOffset: 0,
  projects: [
    {
      environmentId: "remote",
      projectId: "project",
      title: "T3 Code",
      environmentTitle: "Laptop",
      model: "starred",
      defaultModelKey: "codex:starred",
      models: [{ key: "codex:starred", label: "Starred model · Codex" }],
      runtimeMode: "full-access",
      workspaceMode: "local",
      defaultsKey: "defaults",
      unavailableReason: null,
    },
  ],
  hasMoreProjects: false,
  detail: {
    environmentId: "remote",
    threadId: "thread",
    title: "Investigate a bug",
    status: "running",
    canReply: true,
    loading: false,
    before: null,
    hasEarlier: false,
    error: null,
    messages: [{ id: "message:0", role: "assistant", text: "Hello from the phone 👋" }],
  },
  outcomes: [
    {
      id: "request",
      environmentId: "remote",
      threadId: "thread",
      status: "queued",
      message: "Queued on iPhone",
    },
  ],
  error: null,
} satisfies WatchSnapshot;

describe("phone–watch protocol", () => {
  it("validates native transcription metadata without requiring a thread snapshot", () => {
    expect(
      decodeTranscription({
        voiceTranscription: { provider: "whisper", ready: true },
        transcriptions: [
          {
            id: "recording",
            draftKey: "new-thread",
            status: "ready",
            text: "Zmień tę funkcję and add tests.",
          },
        ],
      }).transcriptions[0]?.text,
    ).toBe("Zmień tę funkcję and add tests.");
    expect(() =>
      decodeTranscription({
        voiceTranscription: { provider: "unknown", ready: true },
        transcriptions: [],
      }),
    ).toThrow();
    expect(() =>
      decodeTranscription({
        voiceTranscription: { provider: "apple", ready: false },
        transcriptions: [{ id: "recording", status: "unknown" }],
      }),
    ).toThrow();
  });

  it("validates file metadata and native cancellation independently of thread commands", () => {
    const id = "C27799E9-8789-4B41-97AC-B30AD4FAE7E8";
    const metadata = { kind: "whisper-audio-v1", id, draftKey: "new-thread", createdAt: 123 };
    expect(decodeAudio(metadata)).toEqual(metadata);
    expect(() => decodeAudio({ ...metadata, id: "../../audio" })).toThrow();
    expect(
      decodeTranscriptionControl({
        version: 1,
        id,
        createdAt: fixture.updatedAt,
        type: "cancelTranscription",
        requestId: id,
      }),
    ).toMatchObject({ requestId: id });
    expect(decodeTranscriptionControl({ type: "transcriptionStatus" })).toEqual({
      type: "transcriptionStatus",
    });
  });

  it("accepts selected starred models and older project snapshots", () => {
    expect(
      decodeRequest({
        version: 1,
        id: "create-request",
        createdAt: fixture.updatedAt,
        type: "create",
        environmentId: "remote",
        projectId: "project",
        defaultsKey: "defaults",
        modelKey: "codex:starred",
        text: "Start here",
      }),
    ).toMatchObject({ modelKey: "codex:starred" });
    const { models: _models, defaultModelKey: _key, ...legacyProject } = fixture.projects[0]!;
    expect(decodeSnapshot({ ...fixture, projects: [legacyProject] }).projects[0]?.model).toBe(
      "starred",
    );
  });
  it("bounds Unicode-heavy updates while keeping older conversation pages reachable", () => {
    const payload = encodeWatchSnapshot({
      ...fixture,
      threads: Array.from({ length: 20 }, (_, index) => ({
        ...fixture.threads[0]!,
        threadId: `thread-${index}`,
        title: "日".repeat(2000),
        projectTitle: "日".repeat(2000),
        environmentTitle: "日".repeat(2000),
      })),
      detail: {
        ...fixture.detail,
        messages: Array.from({ length: 8 }, (_, index) => ({
          id: `message:${index}`,
          role: "assistant",
          text: "日".repeat(1500),
        })),
      },
    });
    expect(new TextEncoder().encode(payload).byteLength).toBeLessThan(64000);
    const decoded = decodeSnapshot(JSON.parse(payload));
    expect(decoded.threads).toHaveLength(20);
    expect(decoded.detail?.hasEarlier).toBe(true);
    expect(decoded.detail?.messages.length).toBeLessThan(8);
  });
  it("rejects incompatible versions and unsafe request identifiers", () => {
    const request = {
      version: 1,
      type: "threads",
      id: "request",
      createdAt: fixture.updatedAt,
      limit: 20,
    };
    expect(decodeRequest(request)).toMatchObject({ type: "threads" });
    expect(() => decodeRequest({ ...request, version: 2 })).toThrow();
    expect(() => decodeRequest({ ...request, id: "../../receipt" })).toThrow();
    expect(() => decodeSnapshot({ ...fixture, version: 2 })).toThrow();
  });

  it.effect(
    "round-trips the actual Swift models against the TypeScript contracts",
    () =>
      Effect.gen(function* () {
        if ((yield* HostProcess.Platform) !== "darwin") return;
        const directory = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-watch-protocol-"));
        const targets = NodePath.resolve(import.meta.dirname, "../../../targets");
        try {
          const file = NodePath.join(directory, "snapshot.json");
          const binary = NodePath.join(directory, "protocol-tests");
          NodeFS.writeFileSync(file, JSON.stringify(decodeSnapshot(fixture)));
          NodeChildProcess.execFileSync(
            "xcrun",
            [
              "swiftc",
              NodePath.join(targets, "watch/WatchModels.swift"),
              NodePath.join(targets, "watch-tests/ProtocolTests.swift"),
              NodePath.join(
                targets,
                "../modules/t3-watch-connectivity/ios/WatchWhisperUpload.swift",
              ),
              "-o",
              binary,
            ],
            { timeout: 30000 },
          );
          const reply = decodeRequest(
            JSON.parse(NodeChildProcess.execFileSync(binary, [file], { encoding: "utf8" })),
          );
          expect(reply).toMatchObject({
            version: 1,
            type: "reply",
            id: "stable-request",
            environmentId: "remote",
            threadId: "thread",
            text: "A dictated reply 🗣️",
          });
        } finally {
          NodeFS.rmSync(directory, { recursive: true, force: true });
        }
      }),
    35000,
  );
});
