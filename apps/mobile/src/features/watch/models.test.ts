import { describe, expect, it } from "vite-plus/test";
import { ProviderInstanceId } from "@t3tools/contracts";
import type { ModelOption } from "../../lib/modelOptions";
import { resolveWatchModel, watchStarredModels } from "./models";

function option(provider: string, model: string, patch: Partial<ModelOption> = {}): ModelOption {
  return {
    key: `${provider}:${model}`,
    label: model,
    subtitle: "",
    providerKey: provider,
    providerLabel: provider,
    providerDriver: "codex",
    isDefault: false,
    isLegacy: false,
    capabilities: null,
    selection: { instanceId: ProviderInstanceId.make(provider), model },
    ...patch,
  };
}

describe("Watch starred model choices", () => {
  it("keeps only starred, available models compatible with the project's runtime mode", () => {
    const models = [
      option("codex", "starred"),
      option("other", "starred"),
      option("codex", "not-starred"),
      option("codex", "hidden", { isHidden: true }),
      option("codex", "offline", { isUnavailable: true }),
      option("codex", "supervised", { supportedRuntimeModes: ["approval-required"] }),
    ];
    const favorites = ["starred", "hidden", "offline", "supervised"].map((model) => ({
      provider: "codex",
      model,
    }));
    expect(watchStarredModels(models, favorites, "full-access").map((model) => model.key)).toEqual([
      "codex:starred",
    ]);
    expect(watchStarredModels(models, [], "full-access")).toEqual([]);
  });

  it("rejects stale or forged selections and preserves the full selected model options", () => {
    const selected = option("codex", "chosen");
    const fallback = option("codex", "default").selection;
    expect(resolveWatchModel(selected.key, [selected], fallback)).toEqual(selected.selection);
    expect(() => resolveWatchModel(selected.key, [], fallback)).toThrow("no longer starred");
    expect(() => resolveWatchModel("other:chosen", [selected], fallback)).toThrow(
      "no longer starred",
    );
    expect(resolveWatchModel(undefined, [selected], fallback)).toEqual(fallback);
  });
});
