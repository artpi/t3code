import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/shell";
import type { WatchOutcome, WatchSnapshot } from "@t3tools/contracts/watch-companion";

export function watchThreadStatus(thread: EnvironmentThreadShell): string {
  if (thread.hasPendingApprovals) return "Needs approval";
  if (thread.hasPendingUserInput) return "Needs input";
  return thread.runtime?.status ?? thread.latestRun?.status ?? "idle";
}

export function watchPageLimit(value: number): number {
  return Number.isFinite(value) ? Math.max(1, Math.min(20, Math.floor(value))) : 20;
}

/** Keep each connectivity payload bounded even for a single enormous response. */
export function watchMessagePage(
  messages: ReadonlyArray<{ readonly id: string; readonly role: string; readonly text: string }>,
  before?: string,
): { messages: NonNullable<WatchSnapshot["detail"]>["messages"]; hasEarlier: boolean } {
  let messageIndex = messages.length - 1;
  let part: number | undefined;
  if (before !== undefined) {
    const separator = before.lastIndexOf(":");
    const index = messages.findIndex((message) => message.id === before.slice(0, separator));
    const parsed = Number(before.slice(separator + 1));
    if (index >= 0 && Number.isInteger(parsed) && parsed >= 0) {
      messageIndex = index;
      part = parsed - 1;
    }
  }
  const page: Array<{ id: string; role: string; text: string }> = [];
  while (messageIndex >= 0 && page.length < 8) {
    const message = messages[messageIndex]!;
    const text = message.text || "[Attachment]";
    let chunk = Math.min(part ?? Infinity, Math.ceil(text.length / 1500) - 1);
    for (; chunk >= 0 && page.length < 8; chunk--) {
      page.unshift({
        id: `${message.id}:${chunk}`,
        role: message.role,
        text: text.slice(chunk * 1500, (chunk + 1) * 1500),
      });
    }
    if (chunk >= 0) return { messages: page, hasEarlier: true };
    messageIndex--;
    part = undefined;
  }
  return { messages: page, hasEarlier: messageIndex >= 0 };
}

export function deliveryOutcome(input: {
  readonly id: string;
  readonly environmentId: string;
  readonly threadId: string;
  readonly queued: boolean;
  readonly accepted: boolean;
  readonly failure: string | null;
}): WatchOutcome {
  return {
    id: input.id,
    environmentId: input.environmentId,
    threadId: input.threadId,
    status: input.accepted ? "accepted" : input.failure ? "failed" : "queued",
    message: input.accepted
      ? "Accepted by server"
      : (input.failure ?? (input.queued ? "Queued on iPhone" : "Checking delivery on iPhone")),
  };
}

export function watchPageOffset(value: number | undefined): number {
  return value !== undefined && Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
}

/** Leave room for property-list overhead beneath WatchConnectivity's context limit. */
export function encodeWatchSnapshot(snapshot: WatchSnapshot): string {
  const pending = snapshot.outcomes.filter((row) => row.status === "queued");
  const recent = snapshot.outcomes.filter((row) => row.status !== "queued").slice(-8);
  const wire = {
    ...snapshot,
    threads: snapshot.threads.map((row) => ({
      ...row,
      title: row.title.slice(0, 96),
      projectTitle: row.projectTitle.slice(0, 64),
      environmentTitle: row.environmentTitle.slice(0, 48),
    })),
    projects: snapshot.projects.map((row) => ({
      ...row,
      title: row.title.slice(0, 80),
      environmentTitle: row.environmentTitle.slice(0, 48),
      model: row.model.slice(0, 96),
      ...(row.defaultsKey.length > 4096
        ? { defaultsKey: "", unavailableReason: "These project settings require your iPhone" }
        : {}),
    })),
    detail: snapshot.detail
      ? {
          ...snapshot.detail,
          title: snapshot.detail.title.slice(0, 96),
          messages: [...snapshot.detail.messages],
          error: snapshot.detail.error?.slice(0, 500) ?? null,
        }
      : null,
    outcomes: [...pending, ...recent].map((row) => ({
      ...row,
      message: row.message.slice(0, 500),
    })),
    error: snapshot.error?.slice(0, 500) ?? null,
  };
  let payload = JSON.stringify(wire);
  // At most three UTF-8 bytes per UTF-16 code unit, including non-ASCII replies.
  while (payload.length > 19000 && wire.detail && wire.detail.messages.length > 1) {
    wire.detail.messages.shift();
    wire.detail.hasEarlier = true;
    payload = JSON.stringify(wire);
  }
  return payload;
}
