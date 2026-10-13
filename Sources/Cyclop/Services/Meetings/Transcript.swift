import Foundation

/// One recognised word with its time on its own track, in seconds.
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A stretch of the system track in which one remote voice spoke, in seconds.
struct VoiceTurn: Equatable, Sendable {
    var voice: String
    var start: Double
    var end: Double
}

/// One line of a transcript; times are in milliseconds from the start of the meeting.
struct TranscriptLine: Codable, Equatable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case me, other
    }

    var speaker: Speaker
    /// Which remote voice, once voices are told apart; nil is just «Собеседник».
    var voice: Int?
    var startMs: Int
    var endMs: Int
    var text: String

    enum CodingKeys: String, CodingKey {
        case speaker, voice, text
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

/// Pure functions from timed words to ordered lines and rendered text.
enum TranscriptAssembly {
    static let pauseBreak = 1.0
    static let wordLimit = 60

    /// Smallest share of a word a voice must cover, and the lead it needs over the runner-up.
    static let coverageNeeded = 0.5
    static let leadNeeded = 0.2

    /// Splits one track's words into lines at a pause over a second, at sentence punctuation, at sixty words
    /// and, when voice turns are given, at a change of voice.
    static func lines(
        from words: [TimedWord], speaker: TranscriptLine.Speaker, offsetMs: Int, turns: [VoiceTurn] = []
    ) -> [TranscriptLine] {
        let voices = voices(of: words, turns: turns)
        var out: [TranscriptLine] = []

        for run in runs(of: words) {
            let resolved = inherited(run.map { voices[$0.index] })
            var start = 0
            for i in 1...run.count where i == run.count || resolved[i] != resolved[start] {
                let chunk = run[start..<i]
                out.append(TranscriptLine(
                    speaker: speaker,
                    voice: resolved[start],
                    startMs: Int((chunk.first!.word.start * 1000).rounded()) + offsetMs,
                    endMs: Int((chunk.last!.word.end * 1000).rounded()) + offsetMs,
                    text: chunk.map(\.word.text).joined(separator: " ")
                ))
                start = i
            }
        }
        return out
    }

    /// Words grouped at pauses, sentence ends and the word limit, each remembering its place in the track.
    private static func runs(of words: [TimedWord]) -> [[(index: Int, word: TimedWord)]] {
        var out: [[(index: Int, word: TimedWord)]] = []
        var current: [(index: Int, word: TimedWord)] = []
        for (index, word) in words.enumerated() {
            if let last = current.last, word.start - last.word.end > pauseBreak {
                out.append(current)
                current = []
            }
            current.append((index, word))
            let endsSentence = [".", "?", "!"].contains { word.text.hasSuffix($0) }
            if endsSentence || current.count >= wordLimit {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The voice of each word by index of first appearance, or nil when undecided. Fewer than two
    /// distinct voices means the remote side is one person and nobody gets a letter.
    static func voices(of words: [TimedWord], turns: [VoiceTurn]) -> [Int?] {
        guard !turns.isEmpty else { return Array(repeating: nil, count: words.count) }
        var order: [String] = []
        let decided: [String?] = words.map { word in
            let length = word.end - word.start
            guard length > 0 else { return nil }
            var coverage: [String: Double] = [:]
            for turn in turns {
                let overlap = min(word.end, turn.end) - max(word.start, turn.start)
                if overlap > 0 { coverage[turn.voice, default: 0] += overlap / length }
            }
            let ranked = coverage.sorted { $0.value > $1.value }
            guard let best = ranked.first, best.value >= coverageNeeded else { return nil }
            let second = ranked.count > 1 ? ranked[1].value : 0
            guard best.value - second >= leadNeeded else { return nil }
            if !order.contains(best.key) { order.append(best.key) }
            return best.key
        }
        guard order.count > 1 else { return Array(repeating: nil, count: words.count) }
        return decided.map { $0.flatMap { order.firstIndex(of: $0) } }
    }

    /// An undecided word takes the voice of the nearest decided word before it in its line, else after it.
    private static func inherited(_ voices: [Int?]) -> [Int?] {
        var out = voices
        var previous: Int?
        for i in out.indices {
            if let voice = out[i] { previous = voice } else { out[i] = previous }
        }
        var next: Int?
        for i in out.indices.reversed() {
            if let voice = out[i] { next = voice } else { out[i] = next }
        }
        return out
    }

    /// Both tracks merged in the order spoken; a missing track is a silent side. On a tie the microphone goes first.
    static func assemble(
        mic: [TimedWord], system: [TimedWord], offsets: MeetingMeta.Offsets?, turns: [VoiceTurn] = []
    ) -> [TranscriptLine] {
        let mine = lines(from: mic, speaker: .me, offsetMs: offsets?.mic ?? 0)
        let theirs = lines(from: system, speaker: .other, offsetMs: offsets?.system ?? 0, turns: turns)
        return (mine + theirs).enumerated()
            .sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }
            .map(\.element)
    }

    /// `0:05`, and `1:02:03` from an hour up.
    static func time(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func markdown(title: String, lines: [TranscriptLine], name: (TranscriptLine) -> String) -> String {
        var out = "# \(title)\n"
        for line in lines {
            out += "\n**[\(time(ms: line.startMs))] \(name(line)):** \(line.text)\n"
        }
        return out
    }
}

extension TranscriptLine {
    /// `A`, `B`, … for the voice index; nil for the unlettered other side.
    var voiceLetter: String? {
        guard let voice else { return nil }
        return voice < 26 ? String(UnicodeScalar(UInt8(65 + voice))) : "\(voice + 1)"
    }
}

/// `transcript.json`: written after the Markdown file, and the mark of a finished meeting.
struct TranscriptFile: Codable, Equatable {
    var engine: String
    var model: String
    var createdAt: Date
    var segments: [TranscriptLine]

    enum CodingKeys: String, CodingKey {
        case engine, model, segments
        case createdAt = "created_at"
    }
}
