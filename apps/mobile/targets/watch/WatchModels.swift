import Foundation

struct WatchThread: Codable, Identifiable, Hashable {
  let environmentId: String
  let threadId: String
  let title: String
  let projectTitle: String
  let environmentTitle: String
  let status: String
  let updatedAt: String
  let canReply: Bool
  var id: String { environmentId + ":" + threadId }
}
struct WatchProject: Codable, Identifiable, Hashable {
  let environmentId: String
  let projectId: String
  let title: String
  let environmentTitle: String
  let model: String
  let runtimeMode: String
  let workspaceMode: String
  let defaultsKey: String
  let unavailableReason: String?
  var id: String { environmentId + ":" + projectId }
}
struct WatchMessage: Codable, Identifiable, Hashable {
  let id: String
  let role: String
  let text: String
  var messageId: String { id.lastIndex(of: ":").map { String(id[..<$0]) } ?? id }
  var part: Int { Int(id.split(separator: ":").last ?? "0") ?? 0 }
}
struct WatchDetail: Codable {
  let environmentId: String
  let threadId: String
  let title: String
  let status: String
  let canReply: Bool
  let loading: Bool
  let before: String?
  let hasEarlier: Bool
  let messages: [WatchMessage]
  let error: String?
  var id: String { environmentId + ":" + threadId }
}
struct WatchOutcome: Codable, Identifiable {
  let id: String
  let environmentId: String
  let threadId: String
  let status: String
  let message: String
}
struct WatchSnapshot: Codable {
  let version: Int
  let updatedAt: String
  let threads: [WatchThread]
  let threadOffset: Int
  let hasMoreThreads: Bool
  let projects: [WatchProject]
  let projectOffset: Int
  let hasMoreProjects: Bool
  let detail: WatchDetail?
  let outcomes: [WatchOutcome]
  let error: String?
}
struct PendingRequest: Codable {
  let id: String
  let type: String
  let createdAt: String
  let environmentId: String
  let threadId: String?
  let projectId: String?
  let defaultsKey: String?
  let text: String
  let draftKey: String

  var dictionary: [String: Any] {
    var value: [String: Any] = ["version": 1, "id": id, "type": type, "createdAt": createdAt,
                               "environmentId": environmentId, "text": text]
    if let threadId { value["threadId"] = threadId }
    if let projectId { value["projectId"] = projectId }
    if let defaultsKey { value["defaultsKey"] = defaultsKey }
    return value
  }
}

