import Foundation

@main
struct ProtocolTests {
  static func main() throws {
    // This fixture is produced by the TypeScript WatchSnapshot schema in
    // protocol.test.ts; decode it with the actual watchOS wire models.
    guard CommandLine.arguments.count == 2 else { fatalError("Pass a WatchSnapshot JSON fixture") }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: data)
    precondition(snapshot.version == 1)
    precondition(snapshot.detail?.messages.first?.text == "Hello from the phone 👋")
    precondition(snapshot.threads.first?.environmentId == "remote")
    precondition(snapshot.outcomes.first?.status == "queued")

    let request = PendingRequest(id: "stable-request", type: "reply", createdAt: "2026-10-15T10:00:00Z",
      environmentId: "remote", threadId: "thread", projectId: nil, defaultsKey: nil,
      text: "A dictated reply 🗣️", draftKey: "thread.remote:thread")
    let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(request))
    precondition(restored.dictionary["id"] as? String == request.id)
    precondition(restored.dictionary["text"] as? String == request.text)
    precondition(restored.dictionary["projectId"] == nil)
    precondition(JSONSerialization.isValidJSONObject(restored.dictionary))
    let result = try JSONSerialization.data(withJSONObject: restored.dictionary, options: [.sortedKeys])
    FileHandle.standardOutput.write(result)
  }
}
