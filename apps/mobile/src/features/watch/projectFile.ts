import * as Cause from "effect/Cause";

/** Missing optional t3.json is different from losing access to project settings. */
export function isMissingWatchProjectFile(cause: Cause.Cause<unknown>): boolean {
  return cause.reasons.some((reason) => {
    if (reason._tag !== "Fail") return false;
    const error = reason.error;
    if (
      typeof error !== "object" ||
      error === null ||
      !("_tag" in error) ||
      error._tag !== "ProjectReadFileError" ||
      !("relativePath" in error) ||
      error.relativePath !== "t3.json" ||
      !("operation" in error) ||
      (error.operation !== "realpath-target" && error.operation !== "open")
    )
      return false;
    let nested: unknown = error;
    for (let depth = 0; depth < 8 && typeof nested === "object" && nested !== null; depth++) {
      if ("code" in nested && nested.code === "ENOENT") return true;
      if (
        "message" in nested &&
        typeof nested.message === "string" &&
        nested.message.includes("ENOENT")
      )
        return true;
      nested = "cause" in nested ? nested.cause : null;
    }
    return false;
  });
}
