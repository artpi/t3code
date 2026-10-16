import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { Atom, AtomRegistry } from "effect/reactivity";
import { expect, it } from "vite-plus/test";
import { createWatchThreadStateAtoms } from "./threadState";

it("opens optimistic threads immediately but waits for server creation before loading their conversations", () => {
  const registry = AtomRegistry.make();
  const environmentId = EnvironmentId.make("phone");
  const ids = [ThreadId.make("watch-first"), ThreadId.make("watch-second")];
  const server = new Map<ThreadId, string[]>();
  const loads: ThreadId[] = [];
  const shells = Atom.family((_threadId: ThreadId) => Atom.make<object | null>(null));
  // Like the shared HTTP loader, a definitive miss stays unavailable for this subscription.
  const details = Atom.family((threadId: ThreadId) =>
    Atom.make(() => {
      loads.push(threadId);
      const messages = server.get(threadId);
      return messages ? { status: "live", messages } : { status: "deleted", messages: [] };
    }),
  );
  const watch = createWatchThreadStateAtoms({
    shellAtom: (ref) => shells(ref.threadId),
    stateAtom: (_environmentId, threadId) => details(threadId),
  });
  const observers: Array<() => void> = [];
  try {
    for (const id of ids) {
      const state = watch.stateAtom(environmentId, id);
      // Detail and delivery tracking can both observe the optimistic destination.
      observers.push(registry.mount(state), registry.mount(state));
      expect(registry.get(state)).toBeNull();
    }
    expect(loads).toEqual([]);

    for (const id of ids) {
      server.set(id, ["User message", "Assistant response"]);
      registry.set(shells(id), { id });
      expect(registry.get(watch.stateAtom(environmentId, id))).toEqual({
        status: "live",
        messages: ["User message", "Assistant response"],
      });
    }
    expect(loads).toEqual(ids);

    registry.set(shells(ids[0]!), null);
    expect(registry.get(watch.stateAtom(environmentId, ids[0]!))).toBeNull();
    expect(registry.get(watch.stateAtom(environmentId, ids[1]!))?.status).toBe("live");
  } finally {
    for (const dispose of observers) dispose();
    registry.dispose();
  }
});
