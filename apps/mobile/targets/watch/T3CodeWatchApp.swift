import SwiftUI

private struct WatchMessageText: View, Equatable {
  let text: String
  var formatMarkdown = true

  private func inline(_ value: AttributedString) -> Text {
    var styled = value
    for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
      styled[run.range].font = .system(.footnote, design: .monospaced)
    }
    return Text(styled).font(.footnote)
  }

  var body: some View {
    if formatMarkdown {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(watchMarkdownBlocks(text)) { block in
          switch block.style {
          case .heading(let level):
            Text(block.text).font(level <= 2 ? .headline : .subheadline).bold().accessibilityAddTraits(.isHeader)
          case .code:
            Text(String(block.text.characters)).font(.system(.caption, design: .monospaced))
              .padding(6).frame(maxWidth: .infinity, alignment: .leading)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
          case .quote:
            HStack(alignment: .top, spacing: 6) {
              Rectangle().fill(.secondary).frame(width: 2)
              inline(block.text).italic()
            }.fixedSize(horizontal: false, vertical: true)
          case .list(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
              Text(marker).font(.footnote).monospacedDigit()
              inline(block.text)
            }
          case .paragraph: inline(block.text)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text(text).font(.footnote)
    }
  }
}

private struct OverscrollRefresh: ViewModifier {
  let refresh: () -> Void
  @State private var trigger = OverscrollRefreshTrigger()
  @State private var isScrolling = false

  func body(content: Content) -> some View {
    content
      .scrollBounceBehavior(.always)
      .onScrollPhaseChange { _, phase in
        isScrolling = phase != .idle && phase != .animating
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top < -24
      } action: { _, pastThreshold in
        if trigger.update(pastThreshold: pastThreshold, isScrolling: isScrolling) { refresh() }
      }
  }
}

@main
struct T3CodeWatchApp: App {
  @StateObject private var store = WatchStore()
  var body: some Scene {
    WindowGroup { ThreadListView().environmentObject(store) }
  }
}

private struct ConnectionFooter: View {
  @EnvironmentObject var store: WatchStore
  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = store.transportError ?? store.snapshot?.error {
        Text(error).foregroundStyle(.orange)
      }
      if let updated = store.snapshot?.updatedAt, let date = Self.timestampFormatter.date(from: updated) {
        Text("Updated \(date, style: .relative) ago").foregroundStyle(.secondary)
      }
    }.font(.caption2)
  }
}

struct ThreadListView: View {
  @EnvironmentObject var store: WatchStore
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    NavigationStack {
      List {
        NavigationLink { ComposeView(thread: nil) } label: { Label("New thread", systemImage: "square.and.pencil") }
          .tint(.blue)
        if let pending = store.pending, let thread = store.thread(for: pending) {
          NavigationLink { ThreadView(thread: thread) } label: { Label("Pending message", systemImage: "paperplane") }
        }
        if store.threads.isEmpty {
          Text(store.snapshot == nil ? "Open T3 Code on your iPhone to load threads." : "No threads yet. Start one in an existing project.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(store.threads) { thread in
          NavigationLink { ThreadView(thread: thread) } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(thread.title).font(.headline).lineLimit(2)
              Text(thread.projectTitle + " · " + thread.environmentTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              Text(thread.status.capitalized).font(.caption2).foregroundStyle(statusColor(thread.status))
              if let age = watchRelativeDay(thread.lastActivityAt ?? thread.updatedAt) {
                Text(age).font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Last activity: \(age)")
              }
            }.padding(.vertical, 3)
          }
        }
        if store.snapshot?.hasMoreThreads == true {
          Button("Load more threads") { store.moreThreads() }
        }
        ConnectionFooter()
      }
      .modifier(OverscrollRefresh { store.refreshThreads(); store.retryPending() })
      .navigationTitle("T3 Code")
      .onAppear { store.refreshThreads() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { store.retryPending(); store.refreshCurrent() } }
    }
  }
}

private func statusColor(_ status: String) -> Color {
  if status.contains("Needs") || status == "waiting" { return .orange }
  if status == "failed" { return .red }
  if status == "running" || status == "starting" || status == "preparing" { return .cyan }
  return .secondary
}

struct ThreadView: View {
  @EnvironmentObject var store: WatchStore
  let thread: WatchThread
  @State private var requestedBefore: String?
  private var detail: WatchDetail? { store.snapshot?.detail?.id == thread.id ? store.snapshot?.detail : nil }
  private var messages: [WatchMessage] { store.conversationId == thread.id ? store.conversation : [] }
  private var reply: PendingRequest? {
    optimisticSubmission(store.lastSubmission, environmentId: thread.environmentId, threadId: thread.threadId, messages: messages)
  }
  private var outcome: WatchOutcome? {
    store.lastOutcome?.id == reply?.id ? store.lastOutcome : nil
  }
  private var liveStatus: String { detail?.status ?? store.threads.first(where: { $0.id == thread.id })?.status ?? thread.status }
  private var displayedStatus: String { reply.map { _ in submissionDeliveryLabel(outcome, threadStatus: liveStatus) } ?? liveStatus.capitalized }
  var body: some View {
    ScrollViewReader { proxy in
      List {
        VStack(alignment: .leading, spacing: 4) {
          Text(detail?.title ?? thread.title).font(.headline)
          Text(thread.projectTitle).font(.caption2).foregroundStyle(.secondary)
          Text(displayedStatus).font(.caption).foregroundStyle(statusColor(liveStatus))
        }
        .id("thread-top")
        if store.voiceConfiguration?.provider == "whisper" || store.transcription?.draftKey == "thread." + thread.id {
          NavigationLink { ComposeView(thread: thread) } label: { Label("Respond", systemImage: "mic") }
            .disabled(!(detail?.canReply ?? thread.canReply) || store.pending != nil)
        } else {
          TextFieldLink(prompt: Text("Respond")) { Label("Respond", systemImage: "mic") }
            onSubmit: { text in store.respond(text: text, thread: thread) }
            .disabled(!(detail?.canReply ?? thread.canReply) || store.pending != nil)
        }
        if let reply {
          VStack(alignment: .leading, spacing: 5) {
            Text("You").font(.caption2).foregroundStyle(.blue)
            WatchMessageText(text: reply.text).equatable()
            Text(submissionDeliveryLabel(outcome, threadStatus: liveStatus))
              .font(.caption2).foregroundStyle(outcome?.status == "failed" ? .orange : .secondary)
          }.padding(.vertical, 4)
          if store.pending?.id == reply.id && outcome?.status == "queued" {
            Button("Cancel queued message", role: .destructive) { store.cancelPending() }
          }
        }
        if store.pending == nil, let reply, !store.draft(reply.draftKey).isEmpty {
          NavigationLink("Review saved message") { ComposeView(thread: reply.type == "create" ? nil : thread) }
        } else if store.pending == nil && !store.draft("thread." + thread.id).isEmpty {
          NavigationLink("Review saved reply") { ComposeView(thread: thread) }
        }
        if messages.isEmpty && reply == nil && detail?.loading == true { ProgressView("Loading conversation") }
        if let error = detail?.error, reply?.type != "create" { Text(error).font(.caption).foregroundStyle(.orange) }
        if messages.isEmpty && reply == nil && detail?.loading == false { Text("No messages yet").foregroundStyle(.secondary) }
        ForEach(messageGroupsNewestFirst(messages)) { message in
          VStack(alignment: .leading, spacing: 5) {
            Text(message.role == "user" ? "You" : message.role.capitalized).font(.caption2).foregroundStyle(message.role == "user" ? .blue : .secondary)
            WatchMessageText(text: message.text, formatMarkdown: message.startsAtBeginning).equatable()
          }.padding(.vertical, 4)
        }
        if detail?.hasEarlier == true, let first = messages.first {
          ProgressView("Loading older messages")
            .id(first.id)
            .onAppear {
              guard requestedBefore != first.id else { return }
              requestedBefore = first.id
              store.openThread(environmentId: thread.environmentId, threadId: thread.threadId, before: first.id)
            }
        }
        ConnectionFooter()
      }
      .modifier(OverscrollRefresh {
        requestedBefore = nil
        store.openThread(environmentId: thread.environmentId, threadId: thread.threadId)
      })
      .navigationTitle("Thread")
      .onAppear { store.openThread(environmentId: thread.environmentId, threadId: thread.threadId) }
      .onChange(of: store.lastSubmission?.id) { _, _ in
        if store.lastSubmission?.environmentId == thread.environmentId && store.lastSubmission?.destinationThreadId == thread.threadId {
          proxy.scrollTo("thread-top", anchor: .top)
        }
      }
    }
  }
}

struct ProjectListView: View {
  @EnvironmentObject var store: WatchStore
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    List {
      Text("Choose a project").font(.headline)
      ForEach(store.projects) { project in
        Button { store.selectProject(project); dismiss() } label: {
          VStack(alignment: .leading) {
            Text(project.title)
            Text(project.environmentTitle).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      if store.projects.isEmpty { Text("Add a project on your iPhone first.").font(.footnote) }
      if store.snapshot?.hasMoreProjects == true {
        Button("More projects") { store.moreProjects() }
      }
      Button("Refresh") { store.refreshProjects() }
      ConnectionFooter()
    }.navigationTitle("Project").onAppear { store.refreshProjects() }
  }
}

struct ComposeView: View {
  @EnvironmentObject var store: WatchStore
  @Environment(\.dismiss) private var dismiss
  let thread: WatchThread?
  @State private var selectedModelKey = ""
  @State private var text = ""
  @State private var createdThread: WatchThread?
  private var draftKey: String { thread.map { "thread." + $0.id } ?? "new-thread" }
  private var currentProject: WatchProject? {
    guard thread == nil else { return nil }
    return store.projects.first(where: { $0.id == store.selectedProjectId })
  }
  private var models: [WatchModel] { currentProject?.models ?? [] }
  private var canStart: Bool {
    thread != nil || (currentProject?.unavailableReason == nil && currentProject != nil && models.contains { $0.key == selectedModelKey })
  }
  private func reconcileModel() {
    if !models.contains(where: { $0.key == selectedModelKey }) {
      selectedModelKey = models.first(where: { $0.key == currentProject?.defaultModelKey })?.key ?? models.first?.key ?? ""
    }
  }
  var body: some View {
    List {
      VStack(alignment: .leading, spacing: 3) {
        Text(thread?.title ?? "New thread").font(.headline)
        if let thread { Text(thread.environmentTitle).font(.caption2).foregroundStyle(.secondary) }
      }
      if thread == nil {
        NavigationLink { ProjectListView() } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text("Project").font(.caption2).foregroundStyle(.secondary)
            Text(currentProject?.title ?? "Choose a project")
            if let project = currentProject { Text(project.environmentTitle).font(.caption2).foregroundStyle(.secondary) }
          }
        }
      }
      TextField("Dictate a message", text: $text, axis: .vertical)
        .accessibilityIdentifier("watch.message")
      if store.voiceConfiguration?.provider == "whisper" || store.transcription?.draftKey == draftKey {
        NavigationLink {
          WatchWhisperView(text: $text, draftKey: draftKey)
        } label: {
          Label(store.transcription?.draftKey == draftKey ? "Review recording" : "Record with Whisper", systemImage: "mic.fill")
        }
      } else {
        Text("Use the microphone in text entry, then review your message here.").font(.caption2).foregroundStyle(.secondary)
      }
      if let project = currentProject {
        if let reason = project.unavailableReason {
          Text(reason).font(.caption).foregroundStyle(.orange)
          Button("Reload settings") { store.selectProject(project) }
        } else {
          if models.isEmpty {
            Text("Star an available model on your iPhone to start a thread.").font(.caption).foregroundStyle(.secondary)
          } else {
            Picker("Model", selection: $selectedModelKey) {
              ForEach(models) { model in Text(model.label).tag(model.key) }
            }
            .pickerStyle(.navigationLink)
          }
          Text("Project defaults: \(project.workspaceMode.capitalized) · \(project.runtimeMode)").font(.caption2).foregroundStyle(.secondary)
        }
      }
      Button(thread != nil ? "Send reply" : "Start thread", systemImage: "paperplane.fill") {
        if let thread {
          store.respond(text: text, thread: thread)
          dismiss()
        } else {
          if let request = store.submit(text: text, draftKey: draftKey, project: currentProject, modelKey: selectedModelKey) {
            createdThread = submissionThread(request, project: currentProject)
          }
        }
      }
      .tint(.blue)
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 16000 || store.pending != nil || !canStart)
      if let pending = store.pending, let thread = store.thread(for: pending) {
        NavigationLink("Pending message") { ThreadView(thread: thread) }
      }
      ConnectionFooter()
    }
    .navigationTitle(thread != nil ? "Reply" : "New thread")
    .onAppear {
      text = store.draft(draftKey)
      if thread == nil {
        if text.isEmpty, let project = currentProject {
          let previousKey = "project." + project.id
          text = store.draft(previousKey)
          if !text.isEmpty {
            store.saveDraft(text, key: draftKey)
            store.saveDraft("", key: previousKey)
          }
        }
        store.refreshProjects()
        if let project = currentProject { store.selectProject(project) }
      }
      reconcileModel()
    }
    .onChange(of: currentProject?.id) { _, _ in
      selectedModelKey = ""
      reconcileModel()
    }
    .onChange(of: models) { _, _ in reconcileModel() }
    .onChange(of: text) { _, value in store.saveDraft(value, key: draftKey) }
    .navigationDestination(item: $createdThread) { ThreadView(thread: $0) }
  }
}
