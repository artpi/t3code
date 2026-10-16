import SwiftUI

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
        NavigationLink { ProjectListView() } label: { Label("New thread", systemImage: "square.and.pencil") }
          .tint(.blue)
        if store.pending != nil || store.lastOutcome != nil {
          NavigationLink { DeliveryView() } label: { Label("Message delivery", systemImage: "paperplane") }
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
            }.padding(.vertical, 3)
          }
        }
        if store.snapshot?.hasMoreThreads == true {
          Button("Load more threads") { store.moreThreads() }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { store.refreshThreads(); store.retryPending() }
        ConnectionFooter()
      }
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
  private var detail: WatchDetail? { store.snapshot?.detail?.id == thread.id ? store.snapshot?.detail : nil }
  var body: some View {
    List {
      VStack(alignment: .leading, spacing: 4) {
        Text(detail?.title ?? thread.title).font(.headline)
        Text(thread.projectTitle).font(.caption2).foregroundStyle(.secondary)
        Text((detail?.status ?? thread.status).capitalized).font(.caption).foregroundStyle(statusColor(detail?.status ?? thread.status))
      }
      NavigationLink { ComposeView(thread: thread, project: nil) } label: { Label("Reply", systemImage: "mic") }
        .disabled(!(detail?.canReply ?? thread.canReply))
      if detail?.hasEarlier == true, let first = store.conversation.first {
        Button("Load earlier messages") { store.openThread(environmentId: thread.environmentId, threadId: thread.threadId, before: first.id) }
      }
      if detail?.loading == true { ProgressView("Loading conversation") }
      if let error = detail?.error { Text(error).font(.caption).foregroundStyle(.orange) }
      if store.conversation.isEmpty && detail?.loading == false { Text("No messages yet").foregroundStyle(.secondary) }
      ForEach(store.conversationId == thread.id ? store.conversation : []) { message in
        VStack(alignment: .leading, spacing: 5) {
          Text(message.role == "user" ? "You" : message.role.capitalized).font(.caption2).foregroundStyle(message.role == "user" ? .blue : .secondary)
          Text(message.text).font(.footnote)
        }.padding(.vertical, 4)
      }
      Button("Refresh") { store.openThread(environmentId: thread.environmentId, threadId: thread.threadId) }
      ConnectionFooter()
    }
    .navigationTitle("Thread")
    .onAppear { store.openThread(environmentId: thread.environmentId, threadId: thread.threadId) }
  }
}

struct ProjectListView: View {
  @EnvironmentObject var store: WatchStore
  var body: some View {
    List {
      Text("Choose a project").font(.headline)
      ForEach(store.projects) { project in
        NavigationLink { ComposeView(thread: nil, project: project) } label: {
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
    }.navigationTitle("New thread").onAppear { store.refreshProjects() }
  }
}

struct ComposeView: View {
  @EnvironmentObject var store: WatchStore
  let thread: WatchThread?
  let project: WatchProject?
  @State private var text = ""
  @State private var showingDelivery = false
  private var draftKey: String { project.map { "project." + $0.id } ?? "thread." + thread!.id }
  private var currentProject: WatchProject? {
    guard let project else { return nil }
    return store.projects.first(where: { $0.id == project.id }) ?? project
  }
  var body: some View {
    List {
      VStack(alignment: .leading, spacing: 3) {
        Text(project?.title ?? thread?.title ?? "Message").font(.headline)
        Text(project?.environmentTitle ?? thread?.environmentTitle ?? "").font(.caption2).foregroundStyle(.secondary)
      }
      TextField("Dictate a message", text: $text, axis: .vertical)
        .accessibilityIdentifier("watch.message")
      Text("Use the microphone in text entry, then review your message here.").font(.caption2).foregroundStyle(.secondary)
      if let project = currentProject {
        if let reason = project.unavailableReason {
          Text(reason).font(.caption).foregroundStyle(.orange)
          Button("Reload settings") { store.selectProject(project) }
        } else {
          Text(project.model).font(.caption)
          Text("\(project.workspaceMode.capitalized) · \(project.runtimeMode)").font(.caption2).foregroundStyle(.secondary)
        }
      }
      Button(project == nil ? "Send reply" : "Start thread", systemImage: "paperplane.fill") {
        store.submit(text: text, draftKey: draftKey, thread: thread, project: currentProject)
        showingDelivery = true
      }
      .tint(.blue)
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 16000 || store.pending != nil || (project != nil && currentProject?.unavailableReason != nil))
      if store.pending != nil { NavigationLink("Check pending message") { DeliveryView() } }
      ConnectionFooter()
    }
    .navigationTitle(project == nil ? "Reply" : "New thread")
    .onAppear { text = store.draft(draftKey); if let project { store.selectProject(project) } }
    .onChange(of: text) { _, value in store.saveDraft(value, key: draftKey) }
    .navigationDestination(isPresented: $showingDelivery) { DeliveryView() }
  }
}

struct DeliveryView: View {
  @EnvironmentObject var store: WatchStore
  var body: some View {
    List {
      Label(store.lastOutcome?.message ?? "Saved on Watch", systemImage: store.lastOutcome?.status == "accepted" ? "checkmark.circle" : "paperplane")
      if let pending = store.pending {
        Text(pending.text).font(.footnote)
        Button("Check delivery") { store.retryPending() }
        if store.lastOutcome?.status == "queued" { Button("Cancel queued message", role: .destructive) { store.cancelPending() } }
      }
      if let outcome = store.lastOutcome, outcome.status == "accepted" || outcome.status == "queued" {
        NavigationLink("Open thread") {
          ThreadView(thread: store.threads.first(where: { $0.environmentId == outcome.environmentId && $0.threadId == outcome.threadId }) ??
            WatchThread(environmentId: outcome.environmentId, threadId: outcome.threadId, title: "New thread", projectTitle: "", environmentTitle: "", status: "Preparing", updatedAt: "", canReply: false))
        }
      }
      if store.lastOutcome?.status == "failed" || store.lastOutcome?.status == "cancelled" {
        Text("Your draft is saved. Go back to review and send again.").font(.caption)
      }
      ConnectionFooter()
    }.navigationTitle("Delivery")
  }
}
