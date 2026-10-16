import { describe, expect, it } from "vite-plus/test";
import { RunId } from "@t3tools/contracts";
import {
  deliveryOutcome,
  watchMessagePage,
  watchPageLimit,
  watchPageOffset,
  watchThreadActivityAt,
} from "./model";

it("dates threads by the last completed turn, with activity fallbacks for active and new threads", () => {
  const thread = {
    createdAt: "2026-10-10T10:00:00Z",
    latestUserMessageAt: "2026-10-12T10:00:00Z",
    latestRun: null,
  };
  const run = {
    runId: RunId.make("run"),
    status: "completed" as const,
    requestedAt: "2026-10-13T10:00:00Z",
    startedAt: "2026-10-13T10:01:00Z",
    completedAt: "2026-10-13T10:05:00Z",
    assistantMessageId: null,
  };
  expect(watchThreadActivityAt({ ...thread, latestRun: run })).toBe(run.completedAt);
  expect(watchThreadActivityAt({ ...thread, latestRun: { ...run, completedAt: null } })).toBe(
    run.startedAt,
  );
  expect(watchThreadActivityAt(thread)).toBe(thread.latestUserMessageAt);
  expect(watchThreadActivityAt({ ...thread, latestUserMessageAt: null })).toBe(thread.createdAt);
});

describe("Watch conversation pagination", () => {
  it("can read a very large response completely in bounded pages", () => {
    const text = "An answer with code\n".repeat(1600);
    const message = { id: "message:with:colons", role: "assistant", text };
    const pages = [];
    let page = watchMessagePage([message]);
    pages.unshift(...page.messages);
    while (page.hasEarlier) {
      expect(page.messages.length).toBeLessThanOrEqual(8);
      expect(page.messages.every((row) => row.text.length <= 1500)).toBe(true);
      page = watchMessagePage([message], page.messages[0]!.id);
      pages.unshift(...page.messages);
    }
    expect(pages.map((row) => row.text).join("")).toBe(text);
    expect(new Set(pages.map((row) => row.id)).size).toBe(pages.length);
  });

  it("preserves conversation order across message boundaries", () => {
    const messages = Array.from({ length: 14 }, (_, id) => ({
      id: String(id),
      role: id % 2 ? "assistant" : "user",
      text: `Message ${id}`,
    }));
    const recent = watchMessagePage(messages);
    const earlier = watchMessagePage(messages, recent.messages[0]!.id);
    expect([...earlier.messages, ...recent.messages].map((row) => row.text)).toEqual(
      messages.map((row) => row.text),
    );
    expect(earlier.hasEarlier).toBe(false);
  });

  it("retains content when a cursor disappears during synchronization", () => {
    expect(
      watchMessagePage([{ id: "current", role: "user", text: "Hello" }], "removed:0").messages[0]
        ?.text,
    ).toBe("Hello");
  });

  it("bounds malformed page requests and permits later offsets", () => {
    expect(watchPageLimit(Infinity)).toBe(20);
    expect(watchPageLimit(100000)).toBe(20);
    expect(watchPageOffset(-1)).toBe(0);
    expect(watchPageOffset(500)).toBe(500);
  });
});

it("only reports server acceptance with explicit evidence", () => {
  const input = {
    id: "request",
    environmentId: "remote",
    threadId: "thread",
    queued: false,
    accepted: false,
    failure: null,
  };
  expect(deliveryOutcome(input)).toMatchObject({
    status: "queued",
    message: "Checking delivery on iPhone",
  });
  expect(deliveryOutcome({ ...input, accepted: true })).toMatchObject({ status: "accepted" });
  expect(deliveryOutcome({ ...input, failure: "Permission revoked" })).toMatchObject({
    status: "failed",
    message: "Permission revoked",
  });
});
