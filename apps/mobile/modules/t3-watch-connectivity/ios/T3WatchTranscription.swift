import Foundation
import Security
import UIKit
import WatchConnectivity

/// Phone-owned Whisper jobs survive suspension; neither credentials nor audio enter the JS mailbox.
// Delegate callbacks and all mailbox entry points run on the main queue.
final class T3WatchTranscription: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  static let shared = T3WatchTranscription()
  static let sessionID = "t3.watch.whisper.uploads.v1"
  private let defaults = UserDefaults.standard
  private let storageKey = "t3.watch.whisper.jobs.v1"
  private let apiKeyName = "t3code.voice-input.openai-api-key"
  private var responses: [Int: Data] = [:]
  private var keyReady = false
  private var activated = false
  private var unlockObserver: NSObjectProtocol?
  var backgroundCompletion: (() -> Void)?
  private lazy var directory: URL = {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("watch-whisper", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return url
  }()
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.timeoutIntervalForResource = 900
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()
  private var jobs: [[String: Any]] {
    get { defaults.array(forKey: storageKey) as? [[String: Any]] ?? [] }
    set {
      let active = newValue.filter { $0["status"] as? String == "transcribing" }
      let finished = newValue.filter { $0["status"] as? String != "transcribing" }.suffix(32)
      defaults.set(active + finished, forKey: storageKey)
    }
  }
  private func keyQuery() -> [String: Any] {
    let name = Data(apiKeyName.utf8)
    // Expo SecureStore's unauthenticated alias; use the same item, never a second copy of the key.
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app:no-auth",
            kSecAttrAccount as String: name, kSecAttrGeneric as String: name]
  }
  private func apiKey() -> String? {
    var query = keyQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var configuration: [String: Any] {
    ["provider": defaults.bool(forKey: "t3.watch.whisper.enabled") ? "whisper" : "apple",
     "ready": keyReady]
  }
  func configure(enabled: Bool) {
    defaults.set(enabled, forKey: "t3.watch.whisper.enabled")
    refresh()
  }
  func refresh() {
    // Migrate keys saved by earlier iOS-only builds without changing their value.
    SecItemUpdate(keyQuery() as CFDictionary,
      [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
    keyReady = !(apiKey()?.isEmpty ?? true)
    _ = session
    publish()
  }
  func activate() {
    refresh()
    guard !activated else { return }
    activated = true
    if unlockObserver == nil {
      unlockObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
        object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    // Reconcile interrupted handoff without automatically billing for an uncertain retry.
    let interrupted = jobs.filter { $0["status"] as? String == "transcribing" }.compactMap { $0["id"] as? String }
    session.getAllTasks { tasks in
      DispatchQueue.main.async {
        let active = Set(tasks.compactMap(\.taskDescription))
        for id in interrupted {
          guard !active.contains(id), self.jobs.contains(where: {
            $0["id"] as? String == id && $0["status"] as? String == "transcribing"
          }) else { continue }
          self.finish(id, error: "Transcription was interrupted. Retry from your Watch.")
        }
      }
    }
  }
  func decorate(_ context: [String: Any]) -> [String: Any] {
    var context = context
    context["voiceTranscription"] = configuration
    let latest = jobs.last(where: { $0["status"] as? String == "transcribing" }) ?? jobs.last
    context["transcriptions"] = latest.map { job in
      [job.filter { ["id", "draftKey", "status", "text", "error"].contains($0.key) }]
    } ?? []
    // Keep the current transcript retrievable without exceeding WatchConnectivity's context limit.
    // The latest thread snapshot is retained separately and returns after review/discard.
    if let data = try? JSONSerialization.data(withJSONObject: context), data.count > 65000 {
      context.removeValue(forKey: "payload")
    }
    return context
  }
  private func publish() { T3WatchMailbox.shared.publishTranscription() }
  func cancel(_ id: String) {
    guard UUID(uuidString: id) != nil else { return }
    var cancelled = defaults.dictionary(forKey: "t3.watch.whisper.cancelled") ?? [:]
    let now = Date().timeIntervalSince1970
    cancelled = cancelled.filter { ($0.value as? Double ?? 0) > now - 86400 }
    cancelled[id] = now
    defaults.set(cancelled, forKey: "t3.watch.whisper.cancelled")
    session.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
    var current = jobs.filter { $0["id"] as? String != id }
    current.append(["id": id, "status": "cancelled"])
    jobs = current
    cleanFiles(id)
    publish()
  }
  func receive(_ file: WCSessionFile) {
    guard let metadata = file.metadata, let id = metadata["id"] as? String,
          UUID(uuidString: id) != nil, let draftKey = metadata["draftKey"] as? String,
          draftKey.utf8.count <= 512, metadata["kind"] as? String == "whisper-audio-v1",
          let created = metadata["createdAt"] as? Double,
          abs(Date().timeIntervalSince1970 - created) < 86400 else { return }
    // File and control transfers use different queues; remember cancellation for the transfer's full lifetime.
    if let cancelled = defaults.dictionary(forKey: "t3.watch.whisper.cancelled")?[id] as? Double,
       Date().timeIntervalSince1970 - cancelled < 86400 { return }
    if jobs.contains(where: { $0["id"] as? String == id }) { publish(); return }
    guard jobs.filter({ $0["status"] as? String == "transcribing" }).count < 4 else { return }
    var current = jobs
    current.append(["id": id, "draftKey": draftKey, "status": "transcribing"])
    jobs = current
    let audio = directory.appendingPathComponent(id + ".m4a")
    do {
      // WCSession deletes its temporary file after this delegate returns. Copy synchronously.
      let attributes = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
      guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 25_000_000 else {
        finish(id, error: "The recording is empty or too large. Try a shorter recording."); return
      }
      try FileManager.default.copyItem(at: file.fileURL, to: audio)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: audio.path)
      guard defaults.bool(forKey: "t3.watch.whisper.enabled") else {
        finish(id, error: "Select Whisper in your iPhone’s Microphone settings."); return
      }
      guard let key = apiKey(), !key.isEmpty else {
        finish(id, error: "Open T3 Code on your iPhone and save your Whisper API key."); return
      }
      let boundary = "T3Watch-" + id
      let upload = directory.appendingPathComponent(id + ".multipart")
      DispatchQueue.global(qos: .utility).async {
        do {
          try makeWatchWhisperUpload(audio: audio, output: upload, boundary: boundary)
          try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: upload.path)
          var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
          request.httpMethod = "POST"
          request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
          request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
          // Deliberately omit language and prompt for mixed-language dictation.
          let preparedRequest = request
          DispatchQueue.main.async {
            guard self.jobs.contains(where: { $0["id"] as? String == id && $0["status"] as? String == "transcribing" }) else {
              self.cleanFiles(id); return
            }
            let task = self.session.uploadTask(with: preparedRequest, fromFile: upload)
            task.taskDescription = id
            task.resume()
          }
        } catch {
          DispatchQueue.main.async {
            self.cleanFiles(id)
            self.finish(id, error: "Could not prepare the recording. Retry from your Watch.")
          }
        }
      }
      publish()
    } catch { finish(id, error: "Could not prepare the recording. Retry from your Watch.") }
  }
  private func cleanFiles(_ id: String) {
    for suffix in [".m4a", ".multipart"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + suffix)) }
  }
  private func finish(_ id: String, text: String? = nil, error: String? = nil) {
    guard let index = jobs.firstIndex(where: { $0["id"] as? String == id }),
          jobs[index]["status"] as? String != "cancelled" else { return }
    var current = jobs
    current[index]["status"] = text == nil ? "failed" : "ready"
    current[index]["text"] = text
    current[index]["error"] = error
    jobs = current
    cleanFiles(id)
    publish()
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    var response = responses[dataTask.taskIdentifier] ?? Data()
    guard response.count + data.count <= 1_000_000 else { dataTask.cancel(); return }
    response.append(data)
    responses[dataTask.taskIdentifier] = response
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let data = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
    guard let id = task.taskDescription else { return }
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    if error == nil, status == 200,
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       text.utf16.count <= 16000, text.utf8.count <= 48000 {
      finish(id, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
      let message = status == 401 ? "Update your OpenAI API key on the iPhone." :
        status == 429 ? "Check your OpenAI API credits and retry." :
        "Whisper could not transcribe this recording. Retry from your Watch."
      finish(id, error: message)
    }
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    backgroundCompletion?()
    backgroundCompletion = nil
  }
}
