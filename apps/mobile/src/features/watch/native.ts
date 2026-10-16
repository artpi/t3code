import { requireOptionalNativeModule, type EventSubscription, type NativeModule } from "expo";
import { Platform } from "react-native";

type WatchEvents = { onRequestsChanged: () => void };
interface WatchNativeModule extends NativeModule<WatchEvents> {
  isEnabled(): Promise<boolean>;
  pendingRequests(): Promise<ReadonlyArray<unknown>>;
  finish(id: string): Promise<void>;
  setWorkPending(pending: boolean): Promise<void>;
  publish(payload: { payload: string }): Promise<boolean>;
  addListener(event: "onRequestsChanged", listener: () => void): EventSubscription;
}
export const watchNative =
  Platform.OS === "ios"
    ? requireOptionalNativeModule<WatchNativeModule>("T3WatchConnectivity")
    : null;
