import type { WatchJournalEntry } from "./journal";
import type { QueuedThreadMessage } from "../../state/thread-outbox-model";
import type { WatchRequest } from "@t3tools/contracts/watch-companion";

export function validateWatchSubmission(
  request: Extract<WatchRequest, { type: "reply" | "create" }>,
  canOperate: boolean,
) {
  if (!request.text.trim() || request.text.length > 16000)
    throw new Error("Enter a message of 1–16,000 characters.");
  if (!canOperate)
    throw new Error("This connection cannot send messages. Check permissions on your iPhone.");
}

type SubmissionStore = {
  readonly entries: ReadonlyMap<string, WatchJournalEntry>;
  readonly save: (id: string, entry: WatchJournalEntry) => Promise<void>;
};

/** A prepared receipt freezes IDs and settings across a crash between writes. */
export async function deliverWatchSubmission(input: {
  readonly id: string;
  readonly store: SubmissionStore;
  readonly prepare: () => QueuedThreadMessage;
  readonly enqueue: (message: QueuedThreadMessage) => Promise<void>;
  readonly reconcile?: boolean;
}): Promise<WatchJournalEntry> {
  let entry = input.store.entries.get(input.id);
  if ((entry?.enqueued && !input.reconcile) || (entry && entry.outcome.status !== "queued"))
    return entry;
  if (!entry) {
    const message = input.prepare();
    entry = {
      message,
      enqueued: false,
      outcome: {
        id: input.id,
        environmentId: message.environmentId,
        threadId: message.threadId,
        status: "queued",
        message: "Preparing on iPhone",
      },
    };
    await input.store.save(input.id, entry);
  }
  if (entry.message === null) throw new Error("Invalid pending Watch receipt");
  await input.enqueue(entry.message);
  const queued = {
    ...entry,
    enqueued: true,
    outcome: { ...entry.outcome, message: "Queued on iPhone" },
  };
  await input.store.save(input.id, queued);
  return queued;
}
