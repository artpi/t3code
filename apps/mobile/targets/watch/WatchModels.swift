import Foundation

struct OverscrollRefreshTrigger {
  private var lastRefresh: Date?
  private var wasPastThreshold = false

  mutating func update(pastThreshold: Bool, isScrolling: Bool, now: Date = Date()) -> Bool {
    defer { wasPastThreshold = pastThreshold }
    guard isScrolling, pastThreshold, !wasPastThreshold,
          lastRefresh.map({ now.timeIntervalSince($0) >= 3 }) ?? true else { return false }
    lastRefresh = now
    return true
  }
}

struct WatchThread: Codable, Identifiable, Hashable {
  let environmentId: String
  let threadId: String
  let title: String
  let projectTitle: String
  let environmentTitle: String
  let status: String
  let updatedAt: String
  let canReply: Bool
  var lastActivityAt: String? = nil
  var id: String { environmentId + ":" + threadId }
}
struct WatchModel: Codable, Identifiable, Hashable {
  let key: String
  let label: String
  var id: String { key }
}
struct WatchProject: Codable, Identifiable, Hashable {
  let environmentId: String
  let projectId: String
  let title: String
  let environmentTitle: String
  let model: String
  let defaultModelKey: String?
  let models: [WatchModel]?
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

// Reverse messages, keeping the pieces of a long response in reading order.
func newestMessagesFirst(_ messages: [WatchMessage]) -> [WatchMessage] {
  var groups: [[WatchMessage]] = []
  for message in messages {
    if groups.last?.last?.messageId == message.messageId {
      groups[groups.count - 1].append(message)
    } else {
      groups.append([message])
    }
  }
  return groups.reversed().flatMap { $0 }
}

struct WatchMessageGroup: Identifiable {
  let id: String
  let role: String
  var text: String
  let startsAtBeginning: Bool
}

func messageGroupsNewestFirst(_ messages: [WatchMessage]) -> [WatchMessageGroup] {
  var groups: [WatchMessageGroup] = []
  for message in newestMessagesFirst(messages) {
    if groups.last?.id == message.messageId {
      groups[groups.count - 1].text += message.text
    } else {
      groups.append(WatchMessageGroup(id: message.messageId, role: message.role, text: message.text,
        startsAtBeginning: message.part == 0))
    }
  }
  return groups
}

enum WatchMarkdownStyle: Equatable {
  case paragraph, heading(Int), code, quote, list(String)
}

struct WatchMarkdownBlock: Identifiable {
  let id: Int
  let style: WatchMarkdownStyle
  var text: AttributedString
}

func watchMarkdownBlocks(_ source: String) -> [WatchMarkdownBlock] {
  guard let parsed = try? AttributedString(markdown: source) else {
    return [WatchMarkdownBlock(id: 0, style: .paragraph, text: AttributedString(source))]
  }
  var blocks: [WatchMarkdownBlock] = []
  for run in parsed.runs {
    let components = run.presentationIntent?.components ?? []
    let id = components.first?.identity ?? 0
    var style = WatchMarkdownStyle.paragraph
    var ordinal: Int?
    var listStyle: String?
    for component in components {
      switch component.kind {
      case .header(let level): style = .heading(level)
      case .codeBlock: style = .code
      case .blockQuote: if style == .paragraph { style = .quote }
      case .listItem(let number): if ordinal == nil { ordinal = number }
      case .orderedList: if listStyle == nil { listStyle = "ordered" }
      case .unorderedList: if listStyle == nil { listStyle = "unordered" }
      case .table, .tableRow, .tableCell, .tableHeaderRow:
        // Keep tables readable as source on the small display.
        return [WatchMarkdownBlock(id: 0, style: .code, text: AttributedString(source))]
      default: break
      }
    }
    if let listStyle, style == .paragraph {
      style = .list(listStyle == "ordered" ? "\(ordinal ?? 1)." : "•")
    }
    let text = AttributedString(parsed[run.range])
    if blocks.last?.id == id {
      blocks[blocks.count - 1].text += text
    } else {
      blocks.append(WatchMarkdownBlock(id: id, style: style, text: text))
    }
  }
  return blocks.isEmpty ? [WatchMarkdownBlock(id: 0, style: .paragraph, text: AttributedString(source))] : blocks
}

private enum WatchDates {
  static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  static let standard = ISO8601DateFormatter()
}

func watchRelativeDay(_ timestamp: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
  guard let date = WatchDates.fractional.date(from: timestamp) ?? WatchDates.standard.date(from: timestamp) else { return nil }
  let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
  if days <= 0 { return "Today" }
  if days == 1 { return "Yesterday" }
  return "\(days) days ago"
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
  var modelKey: String? = nil
  var destinationThreadId: String? { type == "create" ? "watch-" + id : threadId }

  var dictionary: [String: Any] {
    var value: [String: Any] = ["version": 1, "id": id, "type": type, "createdAt": createdAt,
                               "environmentId": environmentId, "text": text]
    if let threadId { value["threadId"] = threadId }
    if let projectId { value["projectId"] = projectId }
    if let defaultsKey { value["defaultsKey"] = defaultsKey }
    if let modelKey { value["modelKey"] = modelKey }
    return value
  }
}

func optimisticSubmission(_ request: PendingRequest?, environmentId: String, threadId: String,
                     messages: [WatchMessage]) -> PendingRequest? {
  guard let request, request.environmentId == environmentId,
        request.destinationThreadId == threadId,
        !messages.contains(where: { $0.messageId == "watch-" + request.id }) else { return nil }
  return request
}

func submissionThread(_ request: PendingRequest, project: WatchProject? = nil) -> WatchThread? {
  guard let id = request.destinationThreadId else { return nil }
  return WatchThread(environmentId: request.environmentId, threadId: id,
    title: request.type == "create" ? String(request.text.prefix(80)) : "Thread",
    projectTitle: project?.title ?? "", environmentTitle: project?.environmentTitle ?? "Environment",
    status: "Preparing", updatedAt: request.createdAt, canReply: false)
}

func submissionDeliveryLabel(_ outcome: WatchOutcome?, threadStatus: String) -> String {
  switch outcome?.status {
  case "accepted":
    return ["running", "starting", "preparing"].contains(threadStatus) ? threadStatus.capitalized : "Waiting for agent"
  case "queued": return "Queued on iPhone"
  case "failed": return "Couldn’t send: " + (outcome?.message ?? "Try again")
  case "cancelled": return "Cancelled — message saved"
  default: return "Delivering to iPhone"
  }
}

