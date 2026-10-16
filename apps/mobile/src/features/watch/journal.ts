import { Directory, File, Paths } from "expo-file-system";
import * as Schema from "effect/Schema";
import { WatchOutcome } from "@t3tools/contracts/watch-companion";
import {
  QueuedThreadMessageSchema,
  decodeQueuedThreadMessage,
  encodeQueuedThreadMessage,
  type QueuedThreadMessage,
} from "../../state/thread-outbox-model";
import { writeFileAtomically } from "../../lib/atomic-file";

const Entry = Schema.Struct({
  message: Schema.NullOr(QueuedThreadMessageSchema),
  outcome: WatchOutcome,
  enqueued: Schema.Boolean,
  recordedAt: Schema.optional(Schema.String),
});
const decodeEntry = Schema.decodeUnknownSync(Entry);
export interface WatchJournalEntry {
  readonly message: QueuedThreadMessage | null;
  readonly recordedAt?: string;
  readonly outcome: WatchOutcome;
  readonly enqueued: boolean;
}

/** Persist the frozen payload before enqueuing; retries always reuse its IDs/settings. */
export class WatchJournal {
  private directory = new Directory(Paths.document, "watch-requests-v1");
  readonly entries = new Map<string, WatchJournalEntry>();

  async load() {
    this.directory.create({ idempotent: true, intermediates: true });
    for (const file of this.directory.list()) {
      if (!(file instanceof File) || !file.name.endsWith(".json")) continue;
      const data = decodeEntry(JSON.parse(await file.text()));
      // Requests expire after seven days. Retain unresolved deliveries until
      // reconciled, but release old terminal receipts and their prompt text.
      if (
        data.outcome.status !== "queued" &&
        Date.now() -
          Date.parse(data.recordedAt ?? data.message?.createdAt ?? new Date().toISOString()) >
          8 * 86400_000
      ) {
        file.delete();
        continue;
      }
      this.entries.set(data.outcome.id, {
        message: data.message === null ? null : decodeQueuedThreadMessage(data.message),
        recordedAt: data.recordedAt,
        outcome: data.outcome,
        enqueued: data.enqueued,
      });
    }
  }

  async save(id: string, entry: WatchJournalEntry) {
    await writeFileAtomically(
      new File(this.directory, `${encodeURIComponent(id)}.json`),
      JSON.stringify({
        message: entry.message === null ? null : encodeQueuedThreadMessage(entry.message),
        recordedAt: entry.recordedAt ?? entry.message?.createdAt ?? new Date().toISOString(),
        outcome: entry.outcome,
        enqueued: entry.enqueued,
      }),
    );
    this.entries.set(id, {
      ...entry,
      recordedAt: entry.recordedAt ?? entry.message?.createdAt ?? new Date().toISOString(),
    });
  }
}
