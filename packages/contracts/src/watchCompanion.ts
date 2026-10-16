import * as Schema from "effect/Schema";
import { EnvironmentId, ProjectId, ThreadId } from "./baseSchemas.ts";

// Local iPhone ↔ Watch transport only; no new server RPCs or auth credentials.
const RequestBase = {
  version: Schema.Literal(1),
  id: Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9-]{1,80}$/)),
  createdAt: Schema.String,
};
const Destination = { environmentId: EnvironmentId, threadId: ThreadId };
export const WatchRequest = Schema.Union([
  Schema.Struct({
    ...RequestBase,
    type: Schema.Literal("threads"),
    limit: Schema.Number,
    offset: Schema.optional(Schema.Number),
  }),
  Schema.Struct({
    ...RequestBase,
    type: Schema.Literal("projects"),
    limit: Schema.Number,
    offset: Schema.optional(Schema.Number),
  }),
  Schema.Struct({
    ...RequestBase,
    type: Schema.Literal("project"),
    environmentId: EnvironmentId,
    projectId: ProjectId,
  }),
  Schema.Struct({
    ...RequestBase,
    ...Destination,
    type: Schema.Literal("detail"),
    before: Schema.optional(Schema.String),
  }),
  Schema.Struct({
    ...RequestBase,
    ...Destination,
    type: Schema.Literal("reply"),
    text: Schema.String,
  }),
  Schema.Struct({
    ...RequestBase,
    type: Schema.Literal("create"),
    environmentId: EnvironmentId,
    projectId: ProjectId,
    defaultsKey: Schema.String,
    modelKey: Schema.optional(Schema.String),
    text: Schema.String,
  }),
  Schema.Struct({ ...RequestBase, type: Schema.Literal("cancel"), requestId: Schema.String }),
]);
export type WatchRequest = typeof WatchRequest.Type;

export const WatchThread = Schema.Struct({
  environmentId: Schema.String,
  threadId: Schema.String,
  title: Schema.String,
  projectTitle: Schema.String,
  environmentTitle: Schema.String,
  status: Schema.String,
  updatedAt: Schema.String,
  lastActivityAt: Schema.optional(Schema.String),
  canReply: Schema.Boolean,
});
export const WatchProject = Schema.Struct({
  environmentId: Schema.String,
  projectId: Schema.String,
  title: Schema.String,
  environmentTitle: Schema.String,
  model: Schema.String,
  defaultModelKey: Schema.optional(Schema.String),
  models: Schema.optional(
    Schema.Array(Schema.Struct({ key: Schema.String, label: Schema.String })),
  ),
  runtimeMode: Schema.String,
  workspaceMode: Schema.String,
  defaultsKey: Schema.String,
  unavailableReason: Schema.NullOr(Schema.String),
});
export const WatchMessage = Schema.Struct({
  id: Schema.String,
  role: Schema.String,
  text: Schema.String,
});
export const WatchOutcome = Schema.Struct({
  id: Schema.String,
  environmentId: Schema.String,
  threadId: Schema.String,
  status: Schema.Literals(["queued", "accepted", "failed", "cancelled"]),
  message: Schema.String,
});
export const WatchSnapshot = Schema.Struct({
  version: Schema.Literal(1),
  updatedAt: Schema.String,
  threads: Schema.Array(WatchThread),
  threadOffset: Schema.Number,
  hasMoreThreads: Schema.Boolean,
  projects: Schema.Array(WatchProject),
  projectOffset: Schema.Number,
  hasMoreProjects: Schema.Boolean,
  detail: Schema.NullOr(
    Schema.Struct({
      environmentId: Schema.String,
      threadId: Schema.String,
      title: Schema.String,
      status: Schema.String,
      canReply: Schema.Boolean,
      loading: Schema.Boolean,
      before: Schema.NullOr(Schema.String),
      hasEarlier: Schema.Boolean,
      messages: Schema.Array(WatchMessage),
      error: Schema.NullOr(Schema.String),
    }),
  ),
  outcomes: Schema.Array(WatchOutcome),
  error: Schema.NullOr(Schema.String),
});
export type WatchSnapshot = typeof WatchSnapshot.Type;
export type WatchOutcome = typeof WatchOutcome.Type;
export type WatchProject = typeof WatchProject.Type;
