import AVFoundation
import SwiftUI

/// Owns only microphone capture. WatchStore owns recordings once they are queued for the phone.
final class WatchAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
  @Published var recording = false
  @Published var elapsed = 0
  @Published var error: String?
  private var recorder: AVAudioRecorder?
  private var timer: Timer?
  private var url: URL?
  private var generation = 0
  var onRecordingFinished: ((URL) -> Void)?

  func start() {
    generation += 1
    let generation = generation
    AVAudioApplication.requestRecordPermission { [self] granted in
      DispatchQueue.main.async {
        guard self.generation == generation else { return }
        guard granted else { self.error = "Allow microphone access in Watch Settings to record."; return }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.record, mode: .default)
          try session.setActive(true)
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
          self.url = url
          let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
          self.recorder = recorder
          recorder.delegate = self
          guard recorder.record(forDuration: 300) else { throw CocoaError(.fileWriteUnknown) }
          self.recording = true
          self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Int(self.recorder?.currentTime ?? 0)
          }
        } catch {
          self.error = "Could not start recording. Try again."
          self.cancel()
        }
      }
    }
  }
  func stop() { recorder?.stop() }
  func cancel() {
    generation += 1
    onRecordingFinished = nil
    recorder?.delegate = nil
    recorder?.stop()
    recorder = nil
    timer?.invalidate(); timer = nil
    recording = false
    if let url { try? FileManager.default.removeItem(at: url) }
    url = nil
    try? AVAudioSession.sharedInstance().setActive(false)
  }
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    timer?.invalidate(); timer = nil
    recording = false
    try? AVAudioSession.sharedInstance().setActive(false)
    guard flag, let url else { error = "Recording was interrupted. Try again."; cancel(); return }
    onRecordingFinished?(url)
    cancel()
  }
  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    self.error = "Recording was interrupted. Try again."
    cancel()
  }
}

struct WatchWhisperView: View {
  @EnvironmentObject var store: WatchStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var recorder = WatchAudioRecorder()
  @Binding var text: String
  let draftKey: String
  @State private var originalText = ""
  @State private var reviewError: String?
  private var job: WatchTranscriptionJob? { store.transcription?.draftKey == draftKey ? store.transcription : nil }

  var body: some View {
    List {
      if let job {
        if job.status == "ready", let transcript = job.text {
          Text(transcript)
          Button("Use text", systemImage: "checkmark") {
            guard let merged = mergeWatchTranscript(transcript, original: job.originalText, current: text) else {
              reviewError = "Your draft changed. Keep it, or discard this recording and try again."
              return
            }
            text = merged
            store.saveDraft(merged, key: draftKey)
            store.discardTranscription()
            dismiss()
          }
        } else if job.status == "failed" {
          Text(job.error ?? "Could not transcribe. Try again.").foregroundStyle(.orange)
          Button("Retry", systemImage: "arrow.clockwise") { store.retryTranscription() }
        } else {
          Text(job.status == "transcribing" ? "Transcribing on iPhone…" : "Waiting for iPhone…")
          Text("You can leave this screen. Your recording is saved until you use or discard it.")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Button("Discard recording", role: .destructive) { store.discardTranscription(); dismiss() }
      } else if store.transcription != nil {
        Text("Finish or discard the recording in your other draft first.")
      } else if recorder.recording {
        Text(String(format: "%d:%02d", recorder.elapsed / 60, recorder.elapsed % 60)).monospacedDigit()
        Button("Finish recording", systemImage: "stop.fill") { recorder.stop() }
        Button("Cancel", role: .cancel) { recorder.cancel(); dismiss() }
      } else {
        Text("Whisper detects your language automatically, including mixed Polish and English.")
          .font(.caption2).foregroundStyle(.secondary)
        Button("Start recording", systemImage: "mic.fill") {
          originalText = text
          recorder.onRecordingFinished = { url in
            do { try store.startTranscription(audio: url, draftKey: draftKey, originalText: originalText) }
            catch { reviewError = "Could not save your recording. Try again." }
          }
          recorder.start()
        }
        .disabled(store.voiceConfiguration?.ready != true || store.voiceConfiguration?.provider != "whisper")
        if store.voiceConfiguration?.ready != true || store.voiceConfiguration?.provider != "whisper" {
          Text("Select Whisper and save your API key in the iPhone’s Microphone settings. Unlock the iPhone once after restarting.").font(.caption2)
        }
      }
      if let error = reviewError ?? recorder.error { Text(error).foregroundStyle(.orange) }
    }
    .navigationTitle("Whisper")
    .onAppear { store.refreshTranscription() }
    .onDisappear { recorder.cancel() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { recorder.cancel() }
    }
  }
}
