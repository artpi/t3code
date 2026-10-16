import type { EnvironmentId, ScopedThreadRef, ThreadId } from "@t3tools/contracts";
import { Atom } from "effect/reactivity";

/** A new Watch thread is navigable before its server-side creation commits. */
export function createWatchThreadStateAtoms<T>(input: {
  readonly shellAtom: (ref: ScopedThreadRef) => Atom.Atom<object | null>;
  readonly stateAtom: (environmentId: EnvironmentId, threadId: ThreadId) => Atom.Atom<T>;
}) {
  const environments = Atom.family((environmentId: EnvironmentId) =>
    Atom.family((threadId: ThreadId) =>
      Atom.make((get) => {
        // A premature HTTP 404 is terminal in the shared conversation cache.
        // The shell confirms creation before any detail or delivery observer loads it.
        if (get(input.shellAtom({ environmentId, threadId })) === null) return null;
        return get(input.stateAtom(environmentId, threadId));
      }),
    ),
  );
  return {
    stateAtom: (environmentId: EnvironmentId, threadId: ThreadId) =>
      environments(environmentId)(threadId),
  };
}
