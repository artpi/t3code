import Foundation
import SwiftUI
import WatchConnectivity

// The Watch keeps drafts and a single outstanding submission across app restarts.
// Transport receipt is distinct from the phone outbox and server acceptance.
final class WatchStore: NSObject, ObservableObject, WCSessionDelegate {
  @Published var voiceConfiguration: WatchVoiceConfiguration?
  @Published var transcription: WatchTranscriptionJob?
  @Published var snapshot: WatchSnapshot?
  @Published var reachable = false
  @Published var transportError: String?
  @Published var pending: PendingRequest?
  @Published var lastOutcome: WatchOutcome?
  @Published var lastSubmission: PendingRequest?
  @Published var conversation: [WatchMessage] = []
  @Published var conversationId: String?
  @Published var threads: [WatchThread] = []
  @Published var projects: [WatchProject] = []
  @Published var selectedProjectId: String?
  private var threadOffset = 0
  private var projectOffset = 0
  private let defaults = UserDefaults.standard
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var lastPayload: String?
  private var currentRead: (String, [String: Any]) = ("threads", ["limit": 20, "offset": 0])

  override init() {
    super.init()
    if let data = defaults.data(forKey: "voiceConfiguration.v1") { voiceConfiguration = try? decoder.decode(WatchVoiceConfiguration.self, from: data) }
    if let data = defaults.data(forKey: "transcription.v1") { transcription = try? decoder.decode(WatchTranscriptionJob.self, from: data) }
    if let data = defaults.data(forKey: "snapshot.v1") { snapshot = try? decoder.decode(WatchSnapshot.self, from: data) }
    threads = snapshot?.threads ?? []
    projects = snapshot?.projects ?? []
    selectedProjectId = defaults.string(forKey: "selectedProject.v1")
    if let data = defaults.data(forKey: "pending.v1") { pending = try? decoder.decode(PendingRequest.self, from: data) }
    if let data = defaults.data(forKey: "submission.v1") { lastSubmission = try? decoder.decode(PendingRequest.self, from: data) }
    if lastSubmission == nil { lastSubmission = pending }
    if let data = defaults.data(forKey: "outcome.v1") { lastOutcome = try? decoder.decode(WatchOutcome.self, from: data) }
    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
  }

  func draft(_ key: String) -> String { defaults.string(forKey: "draft." + key) ?? "" }
  func saveDraft(_ text: String, key: String) { defaults.set(text, forKey: "draft." + key) }

  func refreshCurrent() { request(currentRead.0, fields: currentRead.1) }

  func refreshThreads() { threadOffset = 0; request("threads", fields: ["limit": 20, "offset": 0]) }
  func moreThreads() { threadOffset += 20; request("threads", fields: ["limit": 20, "offset": threadOffset]) }
  func refreshProjects() { projectOffset = 0; request("projects", fields: ["limit": 20, "offset": 0]) }
  func moreProjects() { projectOffset += 20; request("projects", fields: ["limit": 20, "offset": projectOffset]) }
  func selectProject(_ project: WatchProject) {
    selectedProjectId = project.id
    defaults.set(project.id, forKey: "selectedProject.v1")
    request("project", fields: ["environmentId": project.environmentId, "projectId": project.projectId])
  }
  func thread(for request: PendingRequest) -> WatchThread? {
    threads.first(where: { $0.environmentId == request.environmentId && $0.threadId == request.destinationThreadId }) ??
      submissionThread(request, project: projects.first(where: { $0.environmentId == request.environmentId && $0.projectId == request.projectId }))
  }
  func openThread(environmentId: String, threadId: String, before: String? = nil) {
    let key = environmentId + ":" + threadId
    if conversationId != key {
      conversation = snapshot?.detail?.id == key ? snapshot?.detail?.messages ?? [] : []
      conversationId = key
    }
    var fields: [String: Any] = ["environmentId": environmentId, "threadId": threadId]
    if let before { fields["before"] = before }
    request("detail", fields: fields)
  }

  @discardableResult
  func submit(text: String, draftKey: String, thread: WatchThread? = nil, project: WatchProject? = nil, modelKey: String? = nil) -> PendingRequest? {
    guard pending == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 16000 else { return nil }
    guard let environmentId = project?.environmentId ?? thread?.environmentId else { return nil }
    let request = PendingRequest(id: UUID().uuidString, type: project == nil ? "reply" : "create",
      createdAt: ISO8601DateFormatter().string(from: Date()), environmentId: environmentId,
      threadId: thread?.threadId, projectId: project?.projectId, defaultsKey: project?.defaultsKey,
      text: text, draftKey: draftKey, modelKey: modelKey)
    // Persist before asking the phone to perform any mutation.
    defaults.set(try? encoder.encode(request), forKey: "pending.v1")
    defaults.set(try? encoder.encode(request), forKey: "submission.v1")
    lastSubmission = request
    pending = request
    lastOutcome = nil
    defaults.removeObject(forKey: "outcome.v1")
    send(request.dictionary, allowQueue: true)
    return request
  }

  func respond(text: String, thread: WatchThread) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let key = "thread." + thread.id
    saveDraft(text, key: key)
    guard text.utf16.count <= 16000 else {
      transportError = "Your reply is too long. Keep it under 16,000 characters. Your draft is saved."
      return
    }
    guard pending == nil else {
      transportError = "Your reply is saved. Wait for the pending message before sending it."
      return
    }
    submit(text: text, draftKey: key, thread: thread)
    openThread(environmentId: thread.environmentId, threadId: thread.threadId)
  }

  func retryPending() {
    guard let pending else { return }
    send(pending.dictionary, allowQueue: true)
  }

  func cancelPending() {
    guard let pending else { return }
    // Cancellation is confirmed by the phone. A transfer may already be in flight.
    for transfer in WCSession.default.outstandingUserInfoTransfers where transfer.userInfo["id"] as? String == pending.id {
      transfer.cancel()
    }
    request("cancel", fields: ["requestId": pending.id])
  }

  func clearOutcome() { lastOutcome = nil; defaults.removeObject(forKey: "outcome.v1") }

  private func request(_ type: String, fields: [String: Any] = [:]) {
    if type != "cancel" { currentRead = (type, fields) }
    var value = fields
    value["version"] = 1
    value["id"] = UUID().uuidString
    value["createdAt"] = ISO8601DateFormatter().string(from: Date())
    value["type"] = type
    send(value, allowQueue: false)
  }

  private func send(_ value: [String: Any], allowQueue: Bool) {
    let session = WCSession.default
    guard session.activationState == .activated else {
      transportError = "Connecting to your iPhone…"
      return
    }
    transportError = nil
    if session.isReachable {
      session.sendMessage(value, replyHandler: { _ in }, errorHandler: { error in
        DispatchQueue.main.async { self.transportError = "Open T3 Code on your iPhone, then retry. " + error.localizedDescription }
      })
    } else if allowQueue {
      if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["id"] as? String == value["id"] as? String }) {
        session.transferUserInfo(value)
      }
      transportError = "Saved on Watch. Waiting for your iPhone."
    } else {
      transportError = "Open T3 Code on your iPhone to refresh."
    }
  }

  private func receive(_ value: [String: Any]) {
    if let configuration = value["voiceTranscription"],
       let data = try? JSONSerialization.data(withJSONObject: configuration),
       let configuration = try? decoder.decode(WatchVoiceConfiguration.self, from: data) {
      voiceConfiguration = configuration
      defaults.set(data, forKey: "voiceConfiguration.v1")
    }
    if let job = transcription, let results = value["transcriptions"],
       let data = try? JSONSerialization.data(withJSONObject: results),
       let decoded = try? decoder.decode([WatchTranscriptionResult].self, from: data),
       let result = decoded.first(where: { $0.id == job.id }) {
      saveTranscription(applyingWatchTranscriptionResult(result, to: job))
    }
    // Immediate delivery and application context carry the same snapshot.
    // Ignore the second copy before decoding or publishing SwiftUI state.
    guard let json = value["payload"] as? String, json != lastPayload, let data = json.data(using: .utf8),
          let incoming = try? decoder.decode(WatchSnapshot.self, from: data), incoming.version == 1 else { return }
    // An opportunistic context transfer can arrive after a newer immediate update.
    if let previous = snapshot, incoming.updatedAt < previous.updatedAt { return }
    lastPayload = json
    snapshot = incoming
    let threadIDs = Set(incoming.threads.map(\.id))
    threads = incoming.threadOffset == 0 ? incoming.threads + threads.filter { !threadIDs.contains($0.id) } : threads.filter { !threadIDs.contains($0.id) } + incoming.threads
    let projectIDs = Set(incoming.projects.map(\.id))
    projects = incoming.projectOffset == 0 ? incoming.projects + projects.filter { !projectIDs.contains($0.id) } : projects.filter { !projectIDs.contains($0.id) } + incoming.projects
    defaults.set(data, forKey: "snapshot.v1")
    transportError = nil
    if let detail = incoming.detail, detail.id == conversationId {
      if detail.before == nil {
        let lastParts = Dictionary(detail.messages.map { ($0.messageId, $0.part) }, uniquingKeysWith: max)
        conversation.removeAll { message in
          lastParts[message.messageId].map { message.part > $0 } ?? false
        }
      }
      var merged = Dictionary(conversation.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      for message in detail.messages { merged[message.id] = message }
      // Keep chronological page order; message IDs are not chronological.
      let incomingIDs = Set(detail.messages.map(\.id))
      if detail.before != nil {
        conversation = detail.messages + conversation.filter { !incomingIDs.contains($0.id) }
      } else {
        conversation = conversation.filter { !incomingIDs.contains($0.id) } + detail.messages
      }
      conversation = conversation.map { merged[$0.id] ?? $0 }
      if let submission = lastSubmission,
         detail.environmentId == submission.environmentId, detail.threadId == submission.destinationThreadId,
         conversation.contains(where: { $0.messageId == "watch-" + submission.id }) {
        lastSubmission = nil
        defaults.removeObject(forKey: "submission.v1")
      }
    }
    if let pending, let outcome = incoming.outcomes.first(where: { $0.id == pending.id }) {
      lastOutcome = outcome
      defaults.set(try? encoder.encode(outcome), forKey: "outcome.v1")
      if outcome.status == "accepted" || outcome.status == "failed" || outcome.status == "cancelled" {
        if outcome.status == "accepted", draft(pending.draftKey) == pending.text {
          saveDraft("", key: pending.draftKey)
        }
        self.pending = nil
        defaults.removeObject(forKey: "pending.v1")
      }
    }
  }

  private func saveTranscription(_ job: WatchTranscriptionJob?) {
    transcription = job
    if let job { defaults.set(try? encoder.encode(job), forKey: "transcription.v1") }
    else { defaults.removeObject(forKey: "transcription.v1") }
  }
  private var recordingsDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }
  func startTranscription(audio: URL, draftKey: String, originalText: String) throws {
    guard transcription == nil else { return }
    let id = UUID().uuidString
    let name = "whisper-" + id + ".m4a"
    let destination = recordingsDirectory.appendingPathComponent(name)
    try FileManager.default.copyItem(at: audio, to: destination)
    let job = WatchTranscriptionJob(id: id, draftKey: draftKey, fileName: name,
      originalText: originalText, createdAt: Date().timeIntervalSince1970, status: "queued")
    saveTranscription(job)
    transferRecording(job)
  }
  private func transferRecording(_ job: WatchTranscriptionJob) {
    guard Date().timeIntervalSince1970 - job.createdAt < 86400 else {
      var expired = job; expired.status = "failed"; expired.error = "The transfer expired. Retry or discard your recording."
      saveTranscription(expired); return
    }
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["id"] as? String == job.id }) else { return }
    let url = recordingsDirectory.appendingPathComponent(job.fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
      var failed = job; failed.status = "failed"; failed.error = "Recording is missing. Record again."
      saveTranscription(failed); return
    }
    session.transferFile(url, metadata: ["kind": "whisper-audio-v1", "id": job.id,
      "draftKey": job.draftKey, "createdAt": job.createdAt])
  }
  func refreshTranscription() {
    guard let job = transcription else { return }
    if job.status == "queued" { transferRecording(job) }
    send(["type": "transcriptionStatus"], allowQueue: false)
  }
  func retryTranscription() {
    guard var job = transcription else { return }
    cancelTranscriptionTransport(job.id)
    job.id = UUID().uuidString
    job.createdAt = Date().timeIntervalSince1970
    job.status = "queued"; job.error = nil; job.text = nil
    saveTranscription(job)
    transferRecording(job)
  }
  private func cancelTranscriptionTransport(_ id: String) {
    for transfer in WCSession.default.outstandingFileTransfers where transfer.file.metadata?["id"] as? String == id { transfer.cancel() }
    send(["version": 1, "id": UUID().uuidString, "type": "cancelTranscription", "requestId": id,
      "createdAt": ISO8601DateFormatter().string(from: Date())], allowQueue: true)
  }
  func discardTranscription() {
    guard let job = transcription else { return }
    cancelTranscriptionTransport(job.id)
    try? FileManager.default.removeItem(at: recordingsDirectory.appendingPathComponent(job.fileName))
    saveTranscription(nil)
  }
  func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    DispatchQueue.main.async {
      guard let error, var job = self.transcription,
            fileTransfer.file.metadata?["id"] as? String == job.id else { return }
      job.status = "failed"; job.error = "Could not send recording to iPhone. " + error.localizedDescription
      self.saveTranscription(job)
    }
  }

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    DispatchQueue.main.async {
      self.reachable = session.isReachable
      self.receive(session.receivedApplicationContext)
      self.retryPending()
      if let job = self.transcription, job.status == "queued" { self.transferRecording(job) }
      self.refreshCurrent()
    }
  }
  func sessionReachabilityDidChange(_ session: WCSession) {
    DispatchQueue.main.async {
      self.reachable = session.isReachable
      if session.isReachable {
        self.retryPending(); self.refreshCurrent()
        self.send(["type": "transcriptionStatus"], allowQueue: false)
      }
    }
  }
  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    DispatchQueue.main.async { self.receive(message) }
  }
  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    DispatchQueue.main.async { self.receive(applicationContext) }
  }
}
