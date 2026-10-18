import Foundation

@main
struct ProtocolTests {
  static func main() throws {
    precondition(mergeWatchTranscript("  funkcję and add tests  ", original: "Zmień tę", current: "Zmień tę") == "Zmień tę funkcję and add tests")
    precondition(mergeWatchTranscript("hello", original: "", current: "edited while waiting") == nil)
    precondition(mergeWatchTranscript(" ", original: "draft", current: "draft") == nil)
    precondition(mergeWatchTranscript("hello", original: "", current: "") == "hello")
    let voiceJob = WatchTranscriptionJob(id: "job", draftKey: "new-thread", fileName: "audio.m4a", originalText: "draft", createdAt: 0, status: "queued")
    let transcriptResult = WatchTranscriptionResult(id: "job", draftKey: "new-thread", status: "ready", text: "Cześć, hello", error: nil)
    let readyJob = applyingWatchTranscriptionResult(transcriptResult, to: voiceJob)
    precondition(readyJob.status == "ready" && readyJob.text == "Cześć, hello")
    precondition(applyingWatchTranscriptionResult(WatchTranscriptionResult(id: "job", draftKey: nil, status: "transcribing", text: nil, error: nil), to: readyJob) == readyJob)
    precondition(applyingWatchTranscriptionResult(WatchTranscriptionResult(id: "old-job", draftKey: nil, status: "ready", text: "stale", error: nil), to: voiceJob) == voiceJob)
    precondition(applyingWatchTranscriptionResult(WatchTranscriptionResult(id: "job", draftKey: "other-draft", status: "ready", text: "stale", error: nil), to: voiceJob) == voiceJob)
    precondition(applyingWatchTranscriptionResult(WatchTranscriptionResult(id: "job", draftKey: nil, status: "cancelled", text: nil, error: nil), to: voiceJob).status == "failed")
    let uploadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: uploadDirectory) }
    let audioURL = uploadDirectory.appendingPathComponent("audio.m4a")
    let uploadURL = uploadDirectory.appendingPathComponent("upload")
    let audioBytes = Data([0, 1, 255, 13, 10])
    try audioBytes.write(to: audioURL)
    try makeWatchWhisperUpload(audio: audioURL, output: uploadURL, boundary: "test-boundary")
    let multipart = try Data(contentsOf: uploadURL)
    precondition(multipart.range(of: audioBytes) != nil)
    let readable = String(decoding: multipart, as: UTF8.self)
    precondition(readable.contains("whisper-1"))
    precondition(readable.contains("filename=\"recording.m4a\""))
    precondition(!readable.contains("name=\"language\""))
    precondition(!readable.contains("name=\"prompt\""))
    precondition(readable.hasSuffix("--test-boundary--\r\n"))
    try Data().write(to: audioURL)
    do { try makeWatchWhisperUpload(audio: audioURL, output: uploadURL, boundary: "test"); fatalError("Empty audio accepted") }
    catch { }
    let markdown = watchMarkdownBlocks("# Heading\n\n**Bold** and `code`\n\n- First\n- Second\n\n```swift\nlet answer = 42\n```\n\n> Quote")
    precondition(markdown.map(\.style) == [.heading(1), .paragraph, .list("•"), .list("•"), .code, .quote])
    precondition(String(markdown[1].text.characters) == "Bold and code")
    precondition(markdown[1].text.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    precondition(String(markdown[4].text.characters).contains("let answer = 42"))
    let linked = watchMarkdownBlocks("[Docs](https://example.com)")
    precondition(linked[0].text.runs.first?.link?.absoluteString == "https://example.com")
    let chunks = [WatchMessage(id: "answer:0", role: "assistant", text: "**Bold"),
                  WatchMessage(id: "answer:1", role: "assistant", text: " text**")]
    let grouped = messageGroupsNewestFirst(chunks)
    precondition(grouped.count == 1 && grouped[0].text == "**Bold text**")
    precondition(grouped[0].startsAtBeginning)
    precondition(!messageGroupsNewestFirst([chunks[1]])[0].startsAtBeginning)
    precondition(watchMarkdownBlocks(grouped[0].text)[0].text.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    let dateNow = ISO8601DateFormatter().date(from: "2026-03-30T08:00:00Z")!
    precondition(watchRelativeDay("2026-03-30T07:00:00.000Z", now: dateNow, calendar: calendar) == "Today")
    precondition(watchRelativeDay("2026-03-29T08:00:00Z", now: dateNow, calendar: calendar) == "Yesterday")
    precondition(watchRelativeDay("2026-03-27T08:00:00Z", now: dateNow, calendar: calendar) == "3 days ago")
    precondition(watchRelativeDay("2026-03-30T22:30:00Z", now: dateNow, calendar: calendar) == "Today")
    precondition(watchRelativeDay("not-a-date", now: dateNow, calendar: calendar) == nil)

    var refresh = OverscrollRefreshTrigger()
    let now = Date(timeIntervalSince1970: 100)
    precondition(!refresh.update(pastThreshold: true, isScrolling: false, now: now))
    precondition(!refresh.update(pastThreshold: false, isScrolling: true, now: now))
    precondition(!refresh.update(pastThreshold: false, isScrolling: true, now: now))
    precondition(refresh.update(pastThreshold: true, isScrolling: true, now: now))
    precondition(!refresh.update(pastThreshold: true, isScrolling: true, now: now))
    precondition(!refresh.update(pastThreshold: false, isScrolling: true, now: now))
    precondition(!refresh.update(pastThreshold: true, isScrolling: true, now: now.addingTimeInterval(1)))
    precondition(!refresh.update(pastThreshold: false, isScrolling: true, now: now.addingTimeInterval(4)))
    precondition(refresh.update(pastThreshold: true, isScrolling: true, now: now.addingTimeInterval(4)))

    let messages = [
      WatchMessage(id: "older:0", role: "user", text: "First"),
      WatchMessage(id: "newer:0", role: "assistant", text: "Start of response"),
      WatchMessage(id: "newer:1", role: "assistant", text: "End of response"),
    ]
    precondition(newestMessagesFirst(messages).map(\.id) == ["newer:0", "newer:1", "older:0"])
    precondition(newestMessagesFirst([]).isEmpty)

    // This fixture is produced by the TypeScript WatchSnapshot schema in
    // protocol.test.ts; decode it with the actual watchOS wire models.
    guard CommandLine.arguments.count == 2 else { fatalError("Pass a WatchSnapshot JSON fixture") }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: data)
    precondition(snapshot.version == 1)
    precondition(snapshot.detail?.messages.first?.text == "Hello from the phone 👋")
    precondition(snapshot.threads.first?.environmentId == "remote")
    precondition(snapshot.threads.first?.lastActivityAt == "2026-10-14T10:00:00.000Z")
    precondition(snapshot.outcomes.first?.status == "queued")
    precondition(snapshot.projects.first?.models?.first?.key == "codex:starred")
    precondition(snapshot.projects.first?.defaultModelKey == "codex:starred")

    let request = PendingRequest(id: "stable-request", type: "reply", createdAt: "2026-10-15T10:00:00Z",
      environmentId: "remote", threadId: "thread", projectId: nil, defaultsKey: nil,
      text: "A dictated reply 🗣️", draftKey: "thread.remote:thread")
    let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(request))
    precondition(restored.dictionary["id"] as? String == request.id)
    precondition(restored.dictionary["text"] as? String == request.text)
    precondition(restored.dictionary["projectId"] == nil)
    precondition(JSONSerialization.isValidJSONObject(restored.dictionary))
    let create = PendingRequest(id: "create-request", type: "create", createdAt: request.createdAt,
      environmentId: "remote", threadId: nil, projectId: "project", defaultsKey: "defaults",
      text: request.text, draftKey: "new-thread", modelKey: "codex:starred")
    let recoveredCreate = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(create))
    precondition(recoveredCreate.dictionary["modelKey"] as? String == "codex:starred")
    precondition(optimisticSubmission(restored, environmentId: "remote", threadId: "thread", messages: [])?.text == request.text)
    precondition(optimisticSubmission(restored, environmentId: "another-environment", threadId: "thread", messages: []) == nil)
    precondition(optimisticSubmission(restored, environmentId: "remote", threadId: "another-thread", messages: []) == nil)
    let delivered = WatchMessage(id: "watch-stable-request:0", role: "user", text: request.text)
    precondition(optimisticSubmission(restored, environmentId: "remote", threadId: "thread", messages: [delivered]) == nil)
    precondition(optimisticSubmission(recoveredCreate, environmentId: "remote", threadId: "thread", messages: []) == nil)
    let newThread = submissionThread(recoveredCreate)!
    precondition(newThread.threadId == "watch-create-request")
    precondition(!newThread.canReply)
    precondition(optimisticSubmission(recoveredCreate, environmentId: "remote", threadId: newThread.threadId, messages: [])?.text == request.text)
    let initialMessage = WatchMessage(id: "watch-create-request:0", role: "user", text: request.text)
    precondition(optimisticSubmission(recoveredCreate, environmentId: "remote", threadId: newThread.threadId, messages: [initialMessage]) == nil)
    precondition(submissionDeliveryLabel(nil, threadStatus: "idle") == "Delivering to iPhone")
    precondition(submissionDeliveryLabel(snapshot.outcomes.first, threadStatus: "running") == "Queued on iPhone")
    let accepted = WatchOutcome(id: request.id, environmentId: "remote", threadId: "thread", status: "accepted", message: "Accepted by server")
    precondition(submissionDeliveryLabel(accepted, threadStatus: "idle") == "Waiting for agent")
    precondition(submissionDeliveryLabel(accepted, threadStatus: "running") == "Running")
    let failed = WatchOutcome(id: request.id, environmentId: "remote", threadId: "thread", status: "failed", message: "Connection lost")
    precondition(submissionDeliveryLabel(failed, threadStatus: "running").contains("Connection lost"))
    let result = try JSONSerialization.data(withJSONObject: restored.dictionary, options: [.sortedKeys])
    FileHandle.standardOutput.write(result)
  }
}
