import { expect, it } from "vite-plus/test";
import * as Cause from "effect/Cause";
import { isMissingWatchProjectFile } from "./projectFile";

it("allows an absent optional config while retaining access and workspace failures", () => {
  const missing = {
    _tag: "ProjectReadFileError",
    relativePath: "t3.json",
    operation: "realpath-target",
    cause: { cause: { code: "ENOENT" } },
  };
  expect(isMissingWatchProjectFile(Cause.fail(missing))).toBe(true);
  expect(
    isMissingWatchProjectFile(Cause.fail({ ...missing, operation: "realpath-workspace-root" })),
  ).toBe(false);
  expect(isMissingWatchProjectFile(Cause.fail({ ...missing, cause: { code: "EACCES" } }))).toBe(
    false,
  );
  expect(isMissingWatchProjectFile(Cause.fail({ _tag: "EnvironmentAuthorizationError" }))).toBe(
    false,
  );
  expect(isMissingWatchProjectFile(Cause.die(new Error("ENOENT")))).toBe(false);
});
