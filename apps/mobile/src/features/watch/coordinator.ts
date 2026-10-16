import { Atom, AsyncResult } from "effect/reactivity";
import { AppState } from "react-native";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import {
  AuthFilesystemReadScope,
  AuthOrchestrationOperateScope,
  CommandId,
  MessageId,
  ThreadId,
  DEFAULT_PROVIDER_INTERACTION_MODE,
  type EnvironmentId,
  type ProjectId,
  type ModelSelection,
} from "@t3tools/contracts";
import {
  WatchRequest,
  type WatchSnapshot,
  type WatchProject,
} from "@t3tools/contracts/watch-companion";
import { resolveNewThreadEnvMode, resolveProjectSettings } from "@t3tools/shared/projectSettings";
import { parseT3ProjectFile } from "@t3tools/shared/t3ProjectFile";
import { resolveModelPreferences } from "@t3tools/shared/serverSettings";
import { mobilePreferencesAtom } from "../../state/preferences";
import { appAtomRegistry as registry } from "../../state/atom-registry";
import { environmentProjects, projectEnvironment } from "../../state/projects";
import {
  environmentThreadShells,
  environmentThreads,
  threadEnvironment,
} from "../../state/threads";
import { environmentPresentations } from "../../state/presentation";
import { environmentSession, readEnvironmentScope } from "../../state/session";
import { vcsEnvironment } from "../../state/vcs";
import {
  threadOutboxManager,
  enqueueThreadOutboxMessage,
  type QueuedThreadMessage,
} from "../../state/thread-outbox";
import { acknowledgedThreadMessagesAtom } from "../../state/acknowledged-thread-messages";
import { dispatchingQueuedMessageIdAtom } from "../../state/use-thread-outbox";
import { removeThreadOutboxMessage } from "../../state/thread-outbox-removal";
import { threadComposerErrorsAtom } from "../../state/thread-composer-error";
import { scopedThreadKey } from "../../lib/scopedEntities";
import {
  buildModelOptions,
  resolveDefaultableModelSelection,
  resolveNewTaskModelSelection,
  type ModelOption,
} from "../../lib/modelOptions";
import { watchStarredModels, resolveWatchModel } from "./models";
import { WatchJournal } from "./journal";
import {
  deliveryOutcome,
  watchMessagePage,
  watchPageLimit,
  watchPageOffset,
  watchThreadStatus,
  watchThreadActivityAt,
  encodeWatchSnapshot,
} from "./model";
import { watchNative } from "./native";
import { deliverWatchSubmission, validateWatchSubmission } from "./submission";
import { isMissingWatchProjectFile } from "./projectFile";
import { createWatchThreadStateAtoms } from "./threadState";

type Selection = { environmentId: EnvironmentId; threadId: ThreadId; before?: string };
type ProjectSelection = { environmentId: EnvironmentId; projectId: ProjectId };
const decodeRequest = Schema.decodeUnknownSync(WatchRequest);
const selectionAtom = Atom.make<Selection | null>(null);
const projectSelectionAtom = Atom.make<ProjectSelection | null>(null);
const threadLimitAtom = Atom.make(20);
const threadOffsetAtom = Atom.make(0);
const projectOffsetAtom = Atom.make(0);
const projectLimitAtom = Atom.make(20);
const watchThreadStates = createWatchThreadStateAtoms({
  shellAtom: environmentThreadShells.threadShellAtom,
  stateAtom: environmentThreads.stateAtom,
});

export async function startWatchCoordinator(): Promise<() => void> {
  if (!watchNative) return () => {};
  const native = watchNative;
  const journal = new WatchJournal();
  await journal.load();
  await threadOutboxManager.load();
  const errorAtom = Atom.make<string | null>(null);
  const recoveryRequestAtom = Atom.make<WatchRequest | null>(null);
  const journalRevisionAtom = Atom.make(0);
  const saveEntry = async (id: string, entry: Parameters<WatchJournal["save"]>[1]) => {
    await journal.save(id, entry);
    registry.set(journalRevisionAtom, registry.get(journalRevisionAtom) + 1);
  };
  let stopped = false;
  let draining = false;
  let rerun = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const accepted = new Set<string>();

  const snapshotAtom = Atom.make((get) => {
    get(journalRevisionAtom);
    const recovery = get(recoveryRequestAtom);
    if (recovery && "environmentId" in recovery) {
      get(environmentSession.sessionStateAtom(recovery.environmentId));
      get(threadEnvironment.snapshotAtom(recovery.environmentId));
    }
    const projects = get(environmentProjects.projectsAtom);
    const preferences = Option.getOrNull(AsyncResult.value(get(mobilePreferencesAtom)));
    const shells = get(environmentThreadShells.navigationThreadShellsAtom);
    const presentations = get(environmentPresentations.presentationsAtom);
    // Grants can change without a shell/config change.
    for (const id of presentations.keys()) get(environmentSession.sessionStateAtom(id));
    const selected = get(selectionAtom);
    const selectedProject = get(projectSelectionAtom);
    const queue = Object.values(get(threadOutboxManager.queuedMessagesByThreadKeyAtom)).flat();
    const acknowledged = get(acknowledgedThreadMessagesAtom);
    const failures = get(threadComposerErrorsAtom);
    const selectedResult = selected
      ? get(watchThreadStates.stateAtom(selected.environmentId, selected.threadId))
      : null;
    const state = selectedResult ? Option.getOrNull(AsyncResult.value(selectedResult)) : null;
    const projection = state ? Option.getOrNull(state.data) : null;
    const threadShell = selected
      ? shells.find(
          (row) => row.environmentId === selected.environmentId && row.id === selected.threadId,
        )
      : null;
    const threadRows = shells
      .filter((row) => !row.archivedAt)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    const threadLimit = get(threadLimitAtom);
    const projectLimit = get(projectLimitAtom);
    const threadOffset = get(threadOffsetAtom);
    const projectOffset = get(projectOffsetAtom);
    const prepared = new Map<
      string,
      {
        row: WatchProject;
        models: ReadonlyArray<ModelOption>;
        message: Omit<
          QueuedThreadMessage,
          "threadId" | "messageId" | "commandId" | "text" | "createdAt"
        >;
      }
    >();
    const projectPage = projects.slice(projectOffset, projectOffset + projectLimit);
    const chosen = projects.find(
      (row) =>
        row.id === selectedProject?.projectId &&
        row.environmentId === selectedProject.environmentId,
    );
    if (chosen && !projectPage.includes(chosen)) projectPage.push(chosen);
    const projectRows = projectPage.map((project): WatchProject => {
      const presentation = presentations.get(project.environmentId);
      const config = presentation?.serverConfig;
      const isSelected =
        selectedProject?.environmentId === project.environmentId &&
        selectedProject.projectId === project.id;
      let unavailableReason: string | null = !isSelected
        ? "Select this project to load its settings"
        : null;
      if (!config || presentation?.connection.phase !== "connected")
        unavailableReason = "Connect this environment on your iPhone";
      if (!readEnvironmentScope(project.environmentId, AuthOrchestrationOperateScope))
        unavailableReason = "This connection cannot start threads";
      let modelSelection: ModelSelection | null = null;
      let mode = "local";
      let runtimeMode = "full-access";
      let branch: string | null = null;
      let defaultsKey = "";
      let models: ReadonlyArray<ModelOption> = [];
      if (config && isSelected && !unavailableReason) {
        if (!readEnvironmentScope(project.environmentId, AuthFilesystemReadScope))
          unavailableReason = "Project settings require file access on your iPhone";
        else {
          const fileResult = get(
            projectEnvironment.readFile({
              environmentId: project.environmentId,
              input: { cwd: project.workspaceRoot, relativePath: "t3.json" },
            }),
          );
          const refsResult = get(
            vcsEnvironment.listRefs({
              environmentId: project.environmentId,
              input: { cwd: project.workspaceRoot, limit: 100 },
            }),
          );
          const file = Option.getOrNull(AsyncResult.value(fileResult));
          const refs = Option.getOrNull(AsyncResult.value(refsResult));
          // Ref streams remain waiting between emissions; their first value is usable.
          if (AsyncResult.isInitial(fileResult) || AsyncResult.isInitial(refsResult))
            unavailableReason = "Loading project settings…";
          if (
            (AsyncResult.isFailure(fileResult) && !isMissingWatchProjectFile(fileResult.cause)) ||
            AsyncResult.isFailure(refsResult)
          )
            unavailableReason = "Project settings unavailable; open this project on your iPhone";
          if (file?.truncated) unavailableReason = "Project settings file is too large";
          const resolved = resolveProjectSettings(
            config.settings,
            project.id,
            project,
            file ? parseT3ProjectFile(file.contents) : null,
          );
          const preferred = resolveDefaultableModelSelection(
            config,
            resolved.settings.defaultModelSelection,
            project.id,
          );
          const modelOptions = buildModelOptions(config, preferred, undefined, project.id);
          modelSelection = resolveNewTaskModelSelection({
            draftSelection: null,
            stickySelection: null,
            projectDefaultSelection: preferred,
            modelOptions,
          });
          mode =
            project.isScratch || refs?.isRepo === false
              ? "local"
              : resolveNewThreadEnvMode({
                  projectSettings: resolved,
                  workspaceRoot: project.workspaceRoot,
                  newProjectsRoot: config.newProjectsRoot,
                  projectHasThreads: shells.some(
                    (row) =>
                      row.environmentId === project.environmentId && row.projectId === project.id,
                  ),
                });
          runtimeMode = resolved.settings.defaultRuntimeMode;
          models = watchStarredModels(
            modelOptions,
            resolveModelPreferences(config.settings, {
              favorites: preferences?.modelFavorites ?? [],
            }).favorites,
            resolved.settings.defaultRuntimeMode,
          );
          const preferredBranch =
            refs?.refs.find((ref) => ref.isDefault) ?? refs?.refs.find((ref) => ref.current);
          branch =
            mode === "worktree"
              ? (preferredBranch?.name ?? null)
              : (refs?.refs.find((ref) => ref.current)?.name ?? null);
          if (!modelSelection) unavailableReason = "Configure an available model on your iPhone";
          if (mode === "worktree" && !branch)
            unavailableReason = "Choose a default branch on your iPhone";
          if (modelSelection) {
            const message = {
              environmentId: project.environmentId,
              attachments: [],
              modelSelection,
              runtimeMode: resolved.settings.defaultRuntimeMode,
              interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
              dispatchMode: "queue" as const,
              creation: {
                projectId: project.id,
                projectTitle: project.title,
                projectCwd: project.workspaceRoot,
                workspaceMode: mode as "local" | "worktree",
                branch,
                worktreePath: null,
                startFromOrigin: resolved.settings.newWorktreesStartFromOrigin,
              },
            };
            defaultsKey = JSON.stringify(message);
            const row = {
              environmentId: project.environmentId,
              projectId: project.id,
              title: project.title,
              environmentTitle: presentation?.entry.target.label ?? "Environment",
              model: modelSelection.model,
              defaultModelKey: `${modelSelection.instanceId}:${modelSelection.model}`,
              models: models.map((option) => ({
                key: option.key,
                label: `${option.label} · ${option.providerLabel}`,
              })),
              runtimeMode,
              workspaceMode: mode,
              defaultsKey,
              unavailableReason,
            };
            prepared.set(`${project.environmentId}:${project.id}`, { row, message, models });
          }
        }
      }
      return {
        environmentId: project.environmentId,
        projectId: project.id,
        title: project.title,
        environmentTitle: presentation?.entry.target.label ?? "Environment",
        model: modelSelection?.model ?? "",
        ...(modelSelection
          ? { defaultModelKey: `${modelSelection.instanceId}:${modelSelection.model}` }
          : {}),
        models: models.map((option) => ({
          key: option.key,
          label: `${option.label} · ${option.providerLabel}`,
        })),
        runtimeMode,
        workspaceMode: mode,
        defaultsKey,
        unavailableReason,
      };
    });
    const page = watchMessagePage(projection?.messages ?? [], selected?.before);
    const outcomes = [...journal.entries]
      .sort(([, a], [, b]) =>
        (a.recordedAt ?? a.message?.createdAt ?? "").localeCompare(
          b.recordedAt ?? b.message?.createdAt ?? "",
        ),
      )
      .filter(
        ([, entry], index, rows) => entry.outcome.status === "queued" || index >= rows.length - 24,
      )
      .map(([id, entry]) => {
        if (
          entry.outcome.status === "accepted" ||
          entry.outcome.status === "cancelled" ||
          entry.outcome.status === "failed"
        )
          return entry.outcome;
        const message = entry.message;
        if (!message) return entry.outcome;
        const deliveryResult = get(
          watchThreadStates.stateAtom(message.environmentId, message.threadId),
        );
        const deliveryState = deliveryResult
          ? Option.getOrNull(AsyncResult.value(deliveryResult))
          : null;
        const deliveryProjection = deliveryState ? Option.getOrNull(deliveryState.data) : null;
        const seen =
          deliveryProjection?.messages.some((row) => row.id === message.messageId) === true ||
          acknowledged.some((row) => row.messageId === message.messageId) ||
          projection?.messages.some((row) => row.id === message.messageId) === true;
        if (seen) accepted.add(id);
        const failure = failures[scopedThreadKey(message.environmentId, message.threadId)];
        return deliveryOutcome({
          id,
          environmentId: message.environmentId,
          threadId: message.threadId,
          queued: queue.some((row) => row.messageId === message.messageId),
          accepted: accepted.has(id),
          failure: failure?.messageId === message.messageId ? failure.message : null,
        });
      });
    const snapshot: WatchSnapshot = {
      version: 1,
      updatedAt: "",
      threads: threadRows.slice(threadOffset, threadOffset + threadLimit).map((row) => ({
        environmentId: row.environmentId,
        threadId: row.id,
        title: row.title,
        projectTitle:
          projects.find(
            (project) =>
              project.environmentId === row.environmentId && project.id === row.projectId,
          )?.title ?? "Project",
        environmentTitle: presentations.get(row.environmentId)?.entry.target.label ?? "Environment",
        status:
          presentations.get(row.environmentId)?.connection.phase === "connected"
            ? watchThreadStatus(row)
            : "Offline · " + watchThreadStatus(row),
        updatedAt: row.updatedAt,
        lastActivityAt: watchThreadActivityAt(row),
        canReply: readEnvironmentScope(row.environmentId, AuthOrchestrationOperateScope),
      })),
      threadOffset,
      hasMoreThreads: threadRows.length > threadOffset + threadLimit,
      projects: projectRows,
      projectOffset,
      hasMoreProjects: projects.length > projectOffset + projectLimit,
      detail: selected
        ? {
            environmentId: selected.environmentId,
            threadId: selected.threadId,
            title: threadShell?.title ?? projection?.thread.title ?? "New thread",
            status: threadShell ? watchThreadStatus(threadShell) : "Preparing",
            canReply:
              readEnvironmentScope(selected.environmentId, AuthOrchestrationOperateScope) &&
              threadShell != null,
            loading: !projection || state?.history.loading === true,
            before: selected.before ?? null,
            hasEarlier: page.hasEarlier || state?.history.hasMoreHistory === true,
            messages: page.messages,
            error:
              presentations.get(selected.environmentId)?.connection.phase !== "connected"
                ? "Environment offline. Showing saved messages."
                : state?.status === "deleted"
                  ? "This thread is no longer available."
                  : state
                    ? (Option.getOrNull(state.error) ?? state.history.error)
                    : null,
          }
        : null,
      outcomes,
      error: get(errorAtom),
    };
    return {
      snapshot,
      prepared,
      workPending:
        recovery !== null ||
        outcomes.some((row) => row.status === "queued") ||
        snapshot.detail?.loading === true ||
        projectRows.some((row) => row.unavailableReason === "Loading project settings…") ||
        [...presentations.values()].some(
          (value) =>
            value.connection.phase === "connecting" || value.connection.phase === "reconnecting",
        ),
    };
  });

  let previousPayload: string | null = null;
  const publish = async () => {
    if (stopped) return;
    const { snapshot } = registry.get(snapshotAtom);
    for (const outcome of snapshot.outcomes) {
      const entry = journal.entries.get(outcome.id);
      if (
        entry &&
        (outcome.status === "accepted" || outcome.status === "failed") &&
        entry.outcome.status !== outcome.status
      )
        await saveEntry(outcome.id, { ...entry, outcome });
    }
    const latest = registry.get(snapshotAtom).snapshot;
    await native.setWorkPending(registry.get(snapshotAtom).workPending);
    const content = JSON.stringify(latest);
    if (content === previousPayload) return;
    if (
      await native.publish({
        payload: encodeWatchSnapshot({ ...latest, updatedAt: new Date().toISOString() }),
      })
    )
      previousPayload = content;
  };
  const schedule = () => {
    if (stopped || timer !== undefined) return;
    timer = setTimeout(() => {
      timer = undefined;
      void publish().catch((cause: unknown) => console.warn("Watch update failed", cause));
    }, 500);
  };

  const handle = async (request: WatchRequest) => {
    const age = Date.now() - Date.parse(request.createdAt);
    if (!Number.isFinite(age) || age > 7 * 86400_000 || age < -300_000)
      throw new Error("This request expired. Review your draft and send again.");
    switch (request.type) {
      case "threads":
        registry.set(selectionAtom, null);
        registry.set(threadOffsetAtom, watchPageOffset(request.offset));
        registry.set(threadLimitAtom, watchPageLimit(request.limit));
        return;
      case "projects":
        registry.set(selectionAtom, null);
        registry.set(projectOffsetAtom, watchPageOffset(request.offset));
        registry.set(projectSelectionAtom, null);
        registry.set(projectLimitAtom, watchPageLimit(request.limit));
        return;
      case "project":
        registry.set(projectSelectionAtom, {
          environmentId: request.environmentId,
          projectId: request.projectId,
        });
        return;
      case "detail": {
        const previous = registry.get(selectionAtom);
        registry.set(selectionAtom, {
          environmentId: request.environmentId,
          threadId: request.threadId,
          ...(request.before ? { before: request.before } : {}),
        });
        const result = registry.get(
          watchThreadStates.stateAtom(request.environmentId, request.threadId),
        );
        const state = result ? Option.getOrNull(AsyncResult.value(result)) : null;
        if (
          request.before &&
          previous?.threadId === request.threadId &&
          state?.history.hasMoreHistory &&
          !watchMessagePage(Option.getOrNull(state.data)?.messages ?? [], request.before).hasEarlier
        ) {
          await threadEnvironment.loadEarlierHistory.run(registry, {
            environmentId: request.environmentId,
            input: { threadId: request.threadId },
          });
        }
        return;
      }
      case "cancel": {
        const entry = journal.entries.get(request.requestId);
        if (!entry || !entry.message || entry.outcome.status !== "queued")
          throw new Error("This request can no longer be cancelled.");
        const message = entry.message;
        const removed = await removeThreadOutboxMessage(
          message,
          threadOutboxManager.revisionOf(message.messageId),
          () => registry.get(dispatchingQueuedMessageIdAtom) !== message.messageId,
        );
        if (!removed)
          throw new Error("Delivery has already started. Check the thread before sending again.");
        await saveEntry(request.requestId, {
          ...entry,
          outcome: { ...entry.outcome, status: "cancelled", message: "Cancelled before delivery" },
        });
        return;
      }
    }
    const prior = journal.entries.get(request.id);
    const observed = registry
      .get(snapshotAtom)
      .snapshot.outcomes.find((row) => row.id === request.id);
    const queued = Object.values(
      registry.get(threadOutboxManager.queuedMessagesByThreadKeyAtom),
    ).flat();
    const entry = await deliverWatchSubmission({
      id: request.id,
      // If the phone died after removing its outbox item but before saving the
      // acknowledgment, replay the original command to retrieve its receipt.
      reconcile:
        prior?.message != null &&
        observed?.status === "queued" &&
        !queued.some((row) => row.messageId === prior.message?.messageId),
      store: { entries: journal.entries, save: saveEntry },
      enqueue: enqueueThreadOutboxMessage,
      prepare: () => {
        validateWatchSubmission(
          request,
          readEnvironmentScope(request.environmentId, AuthOrchestrationOperateScope),
        );
        let message: QueuedThreadMessage;
        if (request.type === "create") {
          const project = registry
            .get(snapshotAtom)
            .prepared.get(`${request.environmentId}:${request.projectId}`);
          if (!project || project.row.unavailableReason)
            throw new Error(
              project?.row.unavailableReason ?? "Select the project again to load its settings.",
            );
          if (project.row.defaultsKey !== request.defaultsKey)
            throw new Error(
              "Project settings changed. Select the project again and review before starting.",
            );
          message = {
            ...project.message,
            modelSelection: resolveWatchModel(
              request.modelKey,
              project.models,
              project.message.modelSelection,
            ),
            threadId: ThreadId.make(`watch-${request.id}`),
            messageId: MessageId.make(`watch-${request.id}`),
            commandId: CommandId.make(`watch-${request.id}`),
            text: request.text.trim(),
            createdAt: request.createdAt,
          };
        } else {
          const thread = registry.get(
            environmentThreadShells.threadShellAtom({
              environmentId: request.environmentId,
              threadId: request.threadId,
            }),
          );
          if (!thread || thread.archivedAt)
            throw new Error("This thread is unavailable. Refresh the thread list.");
          message = {
            environmentId: request.environmentId,
            threadId: thread.id,
            messageId: MessageId.make(`watch-${request.id}`),
            commandId: CommandId.make(`watch-${request.id}`),
            text: request.text.trim(),
            attachments: [],
            modelSelection: thread.modelSelection,
            runtimeMode: thread.runtimeMode,
            interactionMode: thread.interactionMode,
            dispatchMode: "queue",
            createdAt: request.createdAt,
          };
        }
        return message;
      },
    });
    const message = entry.message;
    if (!message) return;
    registry.set(selectionAtom, {
      environmentId: message.environmentId,
      threadId: message.threadId,
    });
  };

  const drain = async () => {
    if (draining) {
      rerun = true;
      return;
    }
    draining = true;
    try {
      do {
        rerun = false;
        let waitingForRecovery = false;
        for (const raw of await native.pendingRequests()) {
          let request: WatchRequest | undefined;
          try {
            request = decodeRequest(raw);
            if (
              (request.type === "reply" || request.type === "create") &&
              !journal.entries.has(request.id)
            ) {
              // A native wake can precede connection/session hydration. Keep the
              // request in the mailbox until grants and destinations are known.
              const session = registry.get(
                environmentSession.sessionStateAtom(request.environmentId),
              );
              let ready =
                AsyncResult.isSuccess(session) &&
                registry.get(threadEnvironment.snapshotAtom(request.environmentId)) !== null;
              if (
                ready &&
                request.type === "create" &&
                readEnvironmentScope(request.environmentId, AuthOrchestrationOperateScope)
              ) {
                const selected = registry.get(projectSelectionAtom);
                if (
                  selected?.environmentId !== request.environmentId ||
                  selected.projectId !== request.projectId
                ) {
                  registry.set(projectSelectionAtom, {
                    environmentId: request.environmentId,
                    projectId: request.projectId,
                  });
                }
                const { environmentId, projectId } = request;
                const project = registry
                  .get(snapshotAtom)
                  .snapshot.projects.find(
                    (row) => row.environmentId === environmentId && row.projectId === projectId,
                  );
                ready =
                  project !== undefined &&
                  project.unavailableReason !== "Loading project settings…";
              }
              if (!ready) {
                waitingForRecovery = true;
                if (registry.get(recoveryRequestAtom)?.id !== request.id)
                  registry.set(recoveryRequestAtom, request);
                registry.set(
                  errorAtom,
                  "Waiting for the iPhone connection. Open T3 Code on your iPhone to continue.",
                );
                continue;
              }
            }
            registry.set(errorAtom, null);
            await handle(request);
          } catch (cause) {
            const error =
              cause instanceof Error ? cause.message : "Could not process Watch request";
            registry.set(errorAtom, error);
            if (request?.type === "reply" || request?.type === "create") {
              // Persist rejections too: a delayed duplicate must not start work
              // after the Watch has already told the user this request failed.
              if (!journal.entries.has(request.id)) {
                await saveEntry(request.id, {
                  message: null,
                  enqueued: false,
                  recordedAt: request.createdAt,
                  outcome: {
                    id: request.id,
                    environmentId: request.environmentId,
                    threadId: request.type === "reply" ? request.threadId : `watch-${request.id}`,
                    status: "failed",
                    message: error,
                  },
                });
              }
            }
          }
          const id =
            request?.id ??
            (typeof raw === "object" && raw !== null && "id" in raw && typeof raw.id === "string"
              ? raw.id
              : null);
          await publish();
          if (id) await native.finish(id);
        }
        if (!waitingForRecovery) registry.set(recoveryRequestAtom, null);
      } while (rerun);
    } finally {
      draining = false;
      schedule();
    }
  };
  const unsubscribe = registry.subscribe(snapshotAtom, () => {
    schedule();
    if (registry.get(recoveryRequestAtom) !== null) void drain().catch(console.warn);
  });
  const subscription = native.addListener("onRequestsChanged", () => {
    previousPayload = null;
    void drain().catch(console.warn);
    schedule();
  });
  const appStateSubscription = AppState.addEventListener("change", (state) => {
    if (state !== "active") return;
    previousPayload = null;
    void drain().catch(console.warn);
    schedule();
  });
  await drain();
  schedule();
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
    subscription.remove();
    appStateSubscription.remove();
    unsubscribe();
  };
}
