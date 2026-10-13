import AVFoundation
import Foundation

/// What the store needs from speech recognition; a fake stands in for it in tests.
protocol SpeechEngine: Sendable {
    var engineName: String { get }
    var modelName: String { get }
    /// Whether the models are on disk. Reads files only, never the network.
    var modelsReady: Bool { get }
    /// The only place that fetches models; processing a meeting never calls it.
    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Recognises one track's file, language detected by the model; `splitAtPauses` recognises each stretch between pauses on its own.
    func words(in audio: URL, splitAtPauses: Bool) async throws -> [TimedWord]
    /// Which remote voice spoke when, on the same file the recogniser read.
    func voiceTurns(in audio: URL) async throws -> [VoiceTurn]
}

/// A track that holds no frames: the recorder died before its first buffer, or the side said nothing.
enum AudioTrack {
    /// Empty file, or a readable one with zero frames. Handing one to the recogniser raises an uncatchable ObjC exception.
    static func isSilentSide(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size else { return true }
        if size == 0 { return true }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length == 0
    }
}
