import ExpoModulesCore
import UIKit
import WatchConnectivity

// Own the session outside the module: watch messages can wake iOS before JS
// installs a listener. Retain the mailbox until JS durably handles each request.
final class T3WatchMailbox: NSObject, WCSessionDelegate {
  static let shared = T3WatchMailbox()
  var onChange: (() -> Void)?
  var observerID: UUID?
  private let defaults = UserDefaults.standard
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var hasPendingWork = false
  private let key = "t3.watch.mailbox.v1"
  private(set) var enabled = false

  func activate() {
    guard Bundle.main.object(forInfoDictionaryKey: "T3WatchCompanionEnabled") as? Bool == true,
          WCSession.isSupported() else { return }
    enabled = true
    WCSession.default.delegate = self
    WCSession.default.activate()
    T3WatchTranscription.shared.activate()
  }

  var requests: [[String: Any]] { defaults.array(forKey: key) as? [[String: Any]] ?? [] }

  private func receive(_ request: [String: Any]) {
    if request["type"] as? String == "cancelTranscription", let id = request["requestId"] as? String {
      T3WatchTranscription.shared.cancel(id)
      return
    }
    if request["type"] as? String == "transcriptionStatus" {
      publishTranscription()
      return
    }
    guard let id = request["id"] as? String else { return }
    var pending = requests
    if !pending.contains(where: { $0["id"] as? String == id }) {
      // Only interactive requests are accepted; bound malformed/abandoned mail.
      guard pending.count < 64 else { return }
      pending.append(request)
      defaults.set(pending, forKey: key)
    }
    if backgroundTask == .invalid {
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "T3 Watch request") {
        self.endBackgroundTask()
      }
    }
    onChange?()
  }

  func finish(_ id: String) {
    defaults.set(requests.filter { $0["id"] as? String != id }, forKey: key)
    if requests.isEmpty && !hasPendingWork { endBackgroundTask() }
  }

  func setWorkPending(_ pending: Bool) {
    hasPendingWork = pending
    if !pending && requests.isEmpty { endBackgroundTask() }
  }

  private func endBackgroundTask() {
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }

  func publish(_ payload: [String: Any]) throws -> Bool {
    guard enabled, WCSession.default.activationState == .activated else { return false }
    defaults.set(payload, forKey: "t3.watch.context.v1")
    let payload = T3WatchTranscription.shared.decorate(payload)
    try WCSession.default.updateApplicationContext(payload)
    if WCSession.default.isReachable {
      WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: { _ in })
    }
    return true
  }

  func publishTranscription() {
    guard enabled, WCSession.default.activationState == .activated else { return }
    let context = T3WatchTranscription.shared.decorate(defaults.dictionary(forKey: "t3.watch.context.v1") ?? [:])
    try? WCSession.default.updateApplicationContext(context)
    if WCSession.default.isReachable { WCSession.default.sendMessage(context, replyHandler: nil, errorHandler: { _ in }) }
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    if Thread.isMainThread { T3WatchTranscription.shared.receive(file) }
    else { DispatchQueue.main.sync { T3WatchTranscription.shared.receive(file) } }
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any],
               replyHandler: @escaping ([String: Any]) -> Void) {
    DispatchQueue.main.async {
      self.receive(message)
      replyHandler(["received": true])
    }
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    DispatchQueue.main.async { self.receive(message) }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    DispatchQueue.main.async { self.receive(userInfo) }
  }

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
               error: Error?) {
    DispatchQueue.main.async { self.publishTranscription(); self.onChange?() }
  }
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  func sessionReachabilityDidChange(_ session: WCSession) {
    DispatchQueue.main.async { self.publishTranscription(); self.onChange?() }
  }
}

public class T3WatchAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                          completionHandler: @escaping () -> Void) {
    guard identifier == T3WatchTranscription.sessionID else { completionHandler(); return }
    T3WatchTranscription.shared.backgroundCompletion = completionHandler
    T3WatchTranscription.shared.activate()
  }

  public func application(_ application: UIApplication,
                          didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    T3WatchMailbox.shared.activate()
    return true
  }
}

public class T3WatchConnectivityModule: Module {
  private let observerID = UUID()
  public func definition() -> ModuleDefinition {
    Name("T3WatchConnectivity")
    Events("onRequestsChanged")
    OnStartObserving("onRequestsChanged") {
      DispatchQueue.main.async {
        T3WatchMailbox.shared.observerID = self.observerID
        T3WatchMailbox.shared.onChange = { [weak self] in self?.emit(event: "onRequestsChanged") }
      }
    }
    OnDestroy {
      let observerID = self.observerID
      DispatchQueue.main.async {
        // A previous Expo runtime can finish teardown after its replacement starts.
        guard T3WatchMailbox.shared.observerID == observerID else { return }
        T3WatchMailbox.shared.onChange = nil
        T3WatchMailbox.shared.observerID = nil
      }
    }
    AsyncFunction("configureTranscription") { (enabled: Bool) in
      guard T3WatchMailbox.shared.enabled else { return }
      T3WatchTranscription.shared.configure(enabled: enabled)
    }.runOnQueue(.main)
    AsyncFunction("refreshTranscription") {
      guard T3WatchMailbox.shared.enabled else { return }
      T3WatchTranscription.shared.refresh()
    }.runOnQueue(.main)
    AsyncFunction("isEnabled") { T3WatchMailbox.shared.enabled }.runOnQueue(.main)
    AsyncFunction("pendingRequests") { T3WatchMailbox.shared.requests }.runOnQueue(.main)
    AsyncFunction("finish") { (id: String) in T3WatchMailbox.shared.finish(id) }.runOnQueue(.main)
    AsyncFunction("setWorkPending") { (pending: Bool) in
      T3WatchMailbox.shared.setWorkPending(pending)
    }.runOnQueue(.main)
    AsyncFunction("publish") { (payload: [String: Any]) in
      return try T3WatchMailbox.shared.publish(payload)
    }.runOnQueue(.main)
  }
}
