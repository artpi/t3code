import { Atom } from "effect/reactivity";

import { environmentCatalog } from "../connection/catalog";

export const primaryEnvironmentIdAtom = Atom.make((get) => {
  for (const [environmentId, entry] of get(environmentCatalog.catalogValueAtom).entries) {
    if (entry.target._tag === "PrimaryConnectionTarget") {
      return environmentId;
    }
  }
  return null;
}).pipe(Atom.withLabel("web-primary-environment-id"));

export const environmentCatalogReadyAtom = Atom.make(
  (get) => get(environmentCatalog.catalogValueAtom).isReady,
).pipe(Atom.withLabel("web-environment-catalog-ready"));
