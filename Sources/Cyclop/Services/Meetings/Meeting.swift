import Foundation

/// One journal row: a folder holding the audio of a call and, later, its transcript.
struct Meeting: Identifiable, Equatable {
    enum State: Equatable {
        /// The folder of the recording that is running now.
        case recording
        /// Audio on disk; the speech models are not there yet.
        case waitingForModels
        /// Queued for, or being turned into, a transcript.
        case processing
        /// `transcript.json` exists.
        case ready
        /// Processing failed; the audio is kept and Retry tries again.
        case failed
    }

    /// The folder's name, `2026-10-13 14-30`; unique within the journal.
    let id: String
    let folder: URL
    let startedAt: Date
    /// Nil after a forced quit, when nothing wrote the length down.
    let duration: TimeInterval?
    let state: State
    /// The system track never carried sound.
    var systemSilent = false
    /// No uncompressed tracks are left waiting: `audio.m4a` is there, or the meeting has no audio to compress.
    var audioReady = true
}

/// `meta.json` of a meeting. Absent keys decode to nil, so a file written by an older build still reads.
struct MeetingMeta: Codable, Equatable {
    /// Where each track's first sound landed, from the start of the earlier one.
    struct Offsets: Codable, Equatable {
        var mic: Int?
        var system: Int?
    }

    var startedAt: Date
    var durationMs: Int?
    var startOffsetMs: Offsets?
    var error: String?
    var systemSilent: Bool?

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case durationMs = "duration_ms"
        case startOffsetMs = "start_offset_ms"
        case error
        case systemSilent = "system_silent"
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

/// Names of the files inside a meeting folder.
enum MeetingFile {
    static let meta = "meta.json"
    static let mic = "mic.caf"
    static let system = "system.caf"
    static let audio = "audio.m4a"
    static let transcript = "transcript.md"
    static let transcriptData = "transcript.json"
}
