import type { ModelSelection, RuntimeMode } from "@t3tools/contracts";
import type { ModelOption } from "../../lib/modelOptions";

export function watchStarredModels(
  options: ReadonlyArray<ModelOption>,
  favorites: ReadonlyArray<{ readonly provider: string; readonly model: string }>,
  runtimeMode: RuntimeMode,
) {
  const keys = new Set(favorites.map((favorite) => `${favorite.provider}:${favorite.model}`));
  return options.filter(
    (option) =>
      keys.has(option.key) &&
      !option.isUnavailable &&
      !option.isHidden &&
      (!option.supportedRuntimeModes?.length || option.supportedRuntimeModes.includes(runtimeMode)),
  );
}

export function resolveWatchModel(
  key: string | undefined,
  options: ReadonlyArray<ModelOption>,
  defaultSelection: ModelSelection | undefined,
) {
  // Older installed Watch apps send only project defaults.
  if (key === undefined) return defaultSelection;
  const option = options.find((option) => option.key === key);
  if (!option)
    throw new Error("This model is no longer starred or available. Choose a model again.");
  return option.selection;
}
