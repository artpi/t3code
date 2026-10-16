import { describe, expect, it } from "vite-plus/test";
import { CommandId, EnvironmentId, MessageId, ThreadId } from "@t3tools/contracts";
import type { WatchJournalEntry } from "./journal";
import type { QueuedThreadMessage } from "../../state/thread-outbox-model";
import { deliverWatchSubmission } from "./submission";

const message = {
  environmentId: EnvironmentId.make("remote"),
  threadId: ThreadId.make("watch-request"),
  messageId: MessageId.make("watch-request"),
  commandId: CommandId.make("watch-request"),
  text: "Please investigate",
  attachments: [],
  createdAt: "2026-10-15T10:00:00.000Z",
};
function fixture() {
  const entries = new Map<string, WatchJournalEntry>();
  const writes: string[] = [];
  const deliveries: QueuedThreadMessage[] = [];
  const store = {
    entries,
    save: async (id: string, entry: WatchJournalEntry) => {
      writes.push(entry.enqueued ? "queued" : "prepared");
      entries.set(id, entry);
    },
  };
  const prepare = () => message;
  const enqueue = async (value: QueuedThreadMessage) => {
    deliveries.push(value);
  };
  return { entries, writes, deliveries, store, prepare, enqueue };
}

describe("Watch submission recovery", () => {
  it("persists a frozen request before delivery and does not resend an acknowledged phone enqueue", async () => {
    const f = fixture();
    const first = await deliverWatchSubmission({ ...f, id: "request" });
    await deliverWatchSubmission({
      ...f,
      id: "request",
      prepare: () => {
        throw new Error("Defaults changed");
      },
    });
    expect(f.writes).toEqual(["prepared", "queued"]);
    expect(f.deliveries).toEqual([message]);
    expect(first.outcome).toMatchObject({ status: "queued", message: "Queued on iPhone" });
  });

  it("replays the same command after a crash between outbox persistence and receipt persistence", async () => {
    const f = fixture();
    let fail = true;
    const store = {
      entries: f.entries,
      save: async (id: string, entry: WatchJournalEntry) => {
        if (entry.enqueued && fail) {
          fail = false;
          throw new Error("Process interrupted");
        }
        await f.store.save(id, entry);
      },
    };
    await expect(deliverWatchSubmission({ ...f, store, id: "request" })).rejects.toThrow(
      "interrupted",
    );
    expect(f.entries.get("request")?.enqueued).toBe(false);
    await deliverWatchSubmission({
      ...f,
      store,
      id: "request",
      prepare: () => {
        throw new Error("Must retain original settings");
      },
    });
    expect(f.deliveries).toEqual([message, message]);
    expect(new Set(f.deliveries.map((row) => row.commandId)).size).toBe(1);
    expect(f.entries.get("request")?.enqueued).toBe(true);
  });

  it("does not deliver if saving the initial request fails", async () => {
    const f = fixture();
    await expect(
      deliverWatchSubmission({
        ...f,
        id: "request",
        store: {
          entries: f.entries,
          save: async () => {
            throw new Error("Disk full");
          },
        },
      }),
    ).rejects.toThrow("Disk full");
    expect(f.deliveries).toEqual([]);
  });

  it("retains the payload when enqueue fails, and resumes it after restarting", async () => {
    const f = fixture();
    await expect(
      deliverWatchSubmission({
        ...f,
        id: "request",
        enqueue: async () => {
          throw new Error("Outbox unavailable");
        },
      }),
    ).rejects.toThrow();
    const restarted = new Map(f.entries);
    await deliverWatchSubmission({
      ...f,
      id: "request",
      store: {
        entries: restarted,
        save: async (id, entry) => {
          restarted.set(id, entry);
        },
      },
      prepare: () => ({ ...message, text: "A changed draft must not replace the original" }),
    });
    expect(f.deliveries).toEqual([message]);
  });

  it("never re-enqueues accepted or cancelled requests", async () => {
    const f = fixture();
    for (const status of ["accepted", "cancelled"] as const) {
      f.entries.set(status, {
        message,
        enqueued: false,
        outcome: {
          id: status,
          environmentId: message.environmentId,
          threadId: message.threadId,
          status,
          message: status,
        },
      });
      await deliverWatchSubmission({ ...f, id: status });
    }
    expect(f.deliveries).toEqual([]);
  });
});

it("rejects submission to an environment without operate permission before creating a receipt", async () => {
  const { validateWatchSubmission } = await import("./submission");
  const request = {
    version: 1 as const,
    type: "reply" as const,
    id: "request",
    environmentId: message.environmentId,
    threadId: message.threadId,
    createdAt: message.createdAt,
    text: "Please investigate",
  };
  expect(() => validateWatchSubmission(request, false)).toThrow("permissions");
  expect(() => validateWatchSubmission(request, true)).not.toThrow();
  expect(() => validateWatchSubmission({ ...request, text: "   " }, true)).toThrow(
    "Enter a message",
  );
  expect(() => validateWatchSubmission({ ...request, text: "x".repeat(16001) }, true)).toThrow(
    "16,000",
  );
});

it("keeps a rejected receipt terminal when a delayed duplicate arrives after permissions change", async () => {
  const f = fixture();
  f.entries.set("rejected", {
    message: null,
    enqueued: false,
    outcome: {
      id: "rejected",
      environmentId: message.environmentId,
      threadId: message.threadId,
      status: "failed",
      message: "Permission denied",
    },
  });
  await deliverWatchSubmission({ ...f, id: "rejected", prepare: () => message });
  expect(f.deliveries).toEqual([]);
});

it("reconciles a lost acknowledgment with the original command after the outbox item is gone", async () => {
  const f = fixture();
  await deliverWatchSubmission({ ...f, id: "request" });
  f.deliveries.length = 0;
  await deliverWatchSubmission({
    ...f,
    id: "request",
    reconcile: true,
    prepare: () => {
      throw new Error("The original frozen command must be replayed");
    },
  });
  expect(f.deliveries).toEqual([message]);
  expect(f.deliveries[0]?.commandId).toBe(message.commandId);
});
