import Foundation
import Testing
@testable import Cyclop

/// Нарезка дорожки на фразы по паузам: каждая фраза распознаётся отдельно.
struct SpeechSpansTests {
    private static let rate = 16_000

    /// Тон там, где `true`, тишина там, где `false`; по секундам из списка.
    private static func track(_ parts: [(Double, Bool)]) -> [Float] {
        parts.flatMap { seconds, loud in
            (0..<Int(seconds * Double(rate))).map { loud ? 0.3 * sin(Float($0) * 0.1) : 0 }
        }
    }

    @Test func aPauseSplitsTwoPhrasesAndEachKeepsAMargin() {
        let samples = Self.track([(1, false), (2, true), (1.5, false), (3, true), (1, false)])
        let spans = SpeechSpans.split(samples, sampleRate: Self.rate)
        #expect(spans.count == 2)
        // Первая фраза 1–3 с, вторая 4,5–7,5 с; поля по 0,24 с.
        #expect(abs(Double(spans[0].lowerBound) / Double(Self.rate) - 0.76) < 0.09)
        #expect(abs(Double(spans[0].upperBound) / Double(Self.rate) - 3.24) < 0.09)
        #expect(abs(Double(spans[1].lowerBound) / Double(Self.rate) - 4.26) < 0.09)
        #expect(abs(Double(spans[1].upperBound) / Double(Self.rate) - 7.74) < 0.09)
    }

    @Test func aShortGapInsideAPhraseDoesNotSplitIt() {
        let samples = Self.track([(2, true), (0.24, false), (2, true)])
        #expect(SpeechSpans.split(samples, sampleRate: Self.rate) == [0..<samples.count])
    }

    @Test func silenceGivesNoSpans() {
        #expect(SpeechSpans.split(Self.track([(3, false)]), sampleRate: Self.rate).isEmpty)
        #expect(SpeechSpans.split([], sampleRate: Self.rate).isEmpty)
    }

    @Test func aClickIsWidenedToWhatTheRecogniserAccepts() {
        let samples = Self.track([(2, false), (0.08, true), (2, false)])
        let spans = SpeechSpans.split(samples, sampleRate: Self.rate)
        #expect(spans.count == 1)
        #expect(spans[0].count >= Int(SpeechSpans.shortestSeconds * Double(Self.rate)))
    }

    @Test func quietNoiseUnderTheLoudestPhraseIsAPause() {
        // Шум на 50 дБ тише речи считается паузой.
        var samples = Self.track([(2, true), (1, false), (2, true)])
        for i in (2 * Self.rate)..<(3 * Self.rate) { samples[i] = 0.001 * sin(Float(i)) }
        #expect(SpeechSpans.split(samples, sampleRate: Self.rate).count == 2)
    }

    @Test func aLoudBeepDoesNotHideQuietSpeech() {
        // Звонок почти на полной громкости и очень тихая речь после него: речь остаётся фразой.
        var samples = Self.track([(1, false), (0.1, true), (1, false), (10, true), (1, false)])
        for i in Int(1.0 * Double(Self.rate))..<Int(1.1 * Double(Self.rate)) { samples[i] *= 3 }
        for i in Int(2.1 * Double(Self.rate))..<Int(12.1 * Double(Self.rate)) { samples[i] *= 0.01 }
        let spans = SpeechSpans.split(samples, sampleRate: Self.rate)
        #expect(spans.count == 2, "\(spans)")
        #expect(spans.last.map { $0.count > 9 * Self.rate } == true)
    }
}
