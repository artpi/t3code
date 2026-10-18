import Foundation

/// Stream a bounded M4A file into the multipart file consumed by a background URLSession upload.
func makeWatchWhisperUpload(audio: URL, output: URL, boundary: String) throws {
  let size = try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber
  guard let size, size.intValue > 0, size.intValue <= 25_000_000,
        !boundary.contains("\r"), !boundary.contains("\n") else { throw CocoaError(.fileReadCorruptFile) }
  let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"
  FileManager.default.createFile(atPath: output.path, contents: nil)
  let writer = try FileHandle(forWritingTo: output)
  defer { try? writer.close() }
  try writer.write(contentsOf: Data(prefix.utf8))
  let reader = try FileHandle(forReadingFrom: audio)
  defer { try? reader.close() }
  while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
  try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
  try writer.synchronize()
}
