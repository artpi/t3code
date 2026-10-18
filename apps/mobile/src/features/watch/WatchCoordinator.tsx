import { useAtomValue } from "@effect/atom-react";
import { AsyncResult, Atom } from "effect/reactivity";
import { mobilePreferencesAtom } from "../../state/preferences";
import { useEffect } from "react";
import { watchNative } from "./native";

const watchTranscriptionProviderAtom = Atom.make((get) => {
  const preferences = get(mobilePreferencesAtom);
  return AsyncResult.isSuccess(preferences)
    ? (preferences.value.voiceTranscriptionProvider ?? "apple")
    : null;
});

/** Keep the optional companion's subscriptions out of normal upstream builds. */
export function WatchCoordinator() {
  const transcriptionProvider = useAtomValue(watchTranscriptionProviderAtom);
  useEffect(() => {
    if (transcriptionProvider === null) return;
    void watchNative?.configureTranscription?.(transcriptionProvider === "whisper").catch(() => {});
  }, [transcriptionProvider]);
  useEffect(() => {
    let disposed = false;
    let stop: (() => void) | undefined;
    void watchNative
      ?.isEnabled()
      .then(async (enabled) => {
        if (!enabled || disposed) return;
        const { startWatchCoordinator } = await import("./coordinator");
        if (!disposed) stop = await startWatchCoordinator();
        if (disposed) stop?.();
      })
      .catch((error: unknown) => console.warn("Watch companion could not start", error));
    return () => {
      disposed = true;
      stop?.();
    };
  }, []);
  return null;
}
