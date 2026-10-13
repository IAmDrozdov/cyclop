import AVFoundation
import Foundation
import Testing
@testable import Cyclop

/// Сборка транскрипта — чистые функции: слова дорожек на входе, строки и текст на выходе.
struct TranscriptTests {
    private static func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    @Test func linesBreakOnAPauseOverOneSecond() {
        let words = [Self.word("один", 0, 0.5), Self.word("два", 1.0, 1.5), Self.word("три", 3.0, 3.5)]
        let lines = TranscriptAssembly.lines(from: words, speaker: .me, offsetMs: 0)
        #expect(lines.map(\.text) == ["один два", "три"])
    }

    @Test func linesBreakAtSentencePunctuation() {
        let words = [Self.word("Привіт.", 0, 0.5), Self.word("Як", 0.6, 0.8), Self.word("справи?", 0.8, 1.2), Self.word("Добре", 1.3, 1.6)]
        let lines = TranscriptAssembly.lines(from: words, speaker: .other, offsetMs: 0)
        #expect(lines.map(\.text) == ["Привіт.", "Як справи?", "Добре"])
    }

    @Test func linesBreakAtSixtyWords() {
        let words = (0..<130).map { Self.word("w\($0)", Double($0) * 0.1, Double($0) * 0.1 + 0.05) }
        let lines = TranscriptAssembly.lines(from: words, speaker: .me, offsetMs: 0)
        #expect(lines.map { $0.text.split(separator: " ").count } == [60, 60, 10])
    }

    @Test func tracksAreMergedInSpokenOrderWithStartOffsets() {
        let mic = [Self.word("Я", 0, 0.5)]
        let system = [Self.word("Он", 0, 0.5)]
        // Дорожка системы началась на 2 с позже, значит её реплика идёт после.
        let lines = TranscriptAssembly.assemble(
            mic: mic, system: system, offsets: .init(mic: 0, system: 2000)
        )
        #expect(lines.map(\.speaker) == [.me, .other])
        #expect(lines[1].startMs == 2000)
        // А если раньше началась дорожка системы — порядок обратный.
        let reversed = TranscriptAssembly.assemble(
            mic: mic, system: system, offsets: .init(mic: 3000, system: 0)
        )
        #expect(reversed.map(\.speaker) == [.other, .me])
    }

    @Test func aSilentSideLeavesOnlyTheOtherOne() {
        let lines = TranscriptAssembly.assemble(
            mic: [], system: [Self.word("Hello.", 1, 2)], offsets: nil
        )
        #expect(lines.count == 1)
        #expect(lines[0].speaker == .other)
        #expect(TranscriptAssembly.assemble(mic: [], system: [], offsets: nil).isEmpty)
    }

    @Test func timeIsMinutesAndSecondsAndHoursOncePastOne() {
        #expect(TranscriptAssembly.time(ms: 5_000) == "0:05")
        #expect(TranscriptAssembly.time(ms: 62_000) == "1:02")
        #expect(TranscriptAssembly.time(ms: 3_723_000) == "1:02:03")
    }

    @Test func markdownHasTitleAndNamedLines() {
        let lines = TranscriptAssembly.assemble(
            mic: [Self.word("Привет.", 5, 6)], system: [Self.word("Hello.", 7, 8)], offsets: nil
        )
        let text = TranscriptAssembly.markdown(title: "Встреча X", lines: lines) {
            $0.speaker == .me ? "Я" : "Собеседник"
        }
        #expect(text == "# Встреча X\n\n**[0:05] Я:** Привет.\n\n**[0:07] Собеседник:** Hello.\n")
    }

    @Test func emptyAndZeroFrameFilesAreSilentSides() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let empty = dir.appendingPathComponent("empty.caf")
        try Data().write(to: empty)
        #expect(AudioTrack.isSilentSide(empty))

        let zero = dir.appendingPathComponent("zero.caf")
        _ = try AVAudioFile(forWriting: zero, settings: AudioLevel.pcmSettings(sampleRate: 16000, channels: 1))
        #expect(AudioTrack.isSilentSide(zero))
        #expect(AudioTrack.isSilentSide(dir.appendingPathComponent("absent.caf")))
    }

    // MARK: - Голоса собеседников

    private func spoken(_ text: String, _ start: Double) -> TimedWord {
        TimedWord(text: text, start: start, end: start + 0.4)
    }

    @Test func aVoiceNeedsHalfTheWordAndALeadOfAFifth() {
        let word = TimedWord(text: "слово", start: 0, end: 1)
        // A закрывает 0.6 слова, B — 0.3: хватает порога и отрыва.
        let clear = [VoiceTurn(voice: "x", start: 0, end: 0.6), VoiceTurn(voice: "y", start: 0.7, end: 1)]
        // Здесь 0.45 и 0.40: ни порога, ни отрыва.
        let vague = [VoiceTurn(voice: "x", start: 0, end: 0.45), VoiceTurn(voice: "y", start: 0.55, end: 0.95)]
        let other = TimedWord(text: "ещё", start: 2, end: 3)
        let second = [VoiceTurn(voice: "y", start: 2, end: 3)]

        // Третье слово целиком голоса x: решённых голосов два, буквы вообще есть.
        let third = TimedWord(text: "и", start: 4, end: 5)
        let thirdTurn = [VoiceTurn(voice: "x", start: 4, end: 5)]

        #expect(TranscriptAssembly.voices(of: [word, other], turns: clear + second) == [0, 1])
        #expect(TranscriptAssembly.voices(of: [word, other, third], turns: vague + second + thirdTurn) == [nil, 0, 1])
    }

    @Test func oneRemoteVoiceGetsNoLetter() {
        let words = [spoken("раз", 0), spoken("два", 0.5)]
        let turns = [VoiceTurn(voice: "only", start: 0, end: 2)]
        let lines = TranscriptAssembly.lines(from: words, speaker: .other, offsetMs: 0, turns: turns)
        #expect(lines.allSatisfy { $0.voice == nil && $0.voiceLetter == nil })
    }

    @Test func lettersFollowFirstAppearanceAndAChangeOfVoiceBreaksTheLine() {
        let words = [spoken("a", 0), spoken("b", 0.5), spoken("c", 1.0), spoken("d", 1.5)]
        // Голос "z" заговорил первым, "q" — вторым, потом снова "z".
        let turns = [
            VoiceTurn(voice: "z", start: 0, end: 0.9),
            VoiceTurn(voice: "q", start: 0.9, end: 1.4),
            VoiceTurn(voice: "z", start: 1.4, end: 2),
        ]
        let lines = TranscriptAssembly.lines(from: words, speaker: .other, offsetMs: 0, turns: turns)
        #expect(lines.map(\.text) == ["a b", "c", "d"])
        #expect(lines.map(\.voiceLetter) == ["A", "B", "A"])
    }

    @Test func anUndecidedWordTakesItsNeighboursVoiceInTheLine() {
        let words = [spoken("a", 0), spoken("b", 0.5), spoken("c", 1.0)]
        // Слово "b" не покрыто никем.
        let turns = [VoiceTurn(voice: "z", start: 0, end: 0.45), VoiceTurn(voice: "z", start: 0.95, end: 1.5),
                     VoiceTurn(voice: "q", start: 3, end: 4)]
        let lines = TranscriptAssembly.lines(from: words, speaker: .other, offsetMs: 0, turns: turns)
        #expect(lines.map(\.text) == ["a b c"])
        #expect(lines[0].voice == nil || lines[0].voiceLetter == "A")
    }

    @Test func markdownNamesALetteredVoice() {
        let lines = [TranscriptLine(speaker: .other, voice: 1, startMs: 0, endMs: 500, text: "Hi.")]
        let text = TranscriptAssembly.markdown(title: "T", lines: lines) { "S \($0.voiceLetter ?? "-")" }
        #expect(text.contains("S B:"))
    }
}
