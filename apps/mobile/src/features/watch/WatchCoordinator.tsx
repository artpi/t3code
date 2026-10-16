import { useEffect } from "react";
import { watchNative } from "./native";

/** Keep the optional companion's subscriptions out of normal upstream builds. */
export function WatchCoordinator() {
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
