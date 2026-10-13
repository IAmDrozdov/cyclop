import Foundation

/// Drops lines of the owner that only repeat what the other side said at the same moment.
/// Both passes fail toward keeping speech: when unsure, the line stays.
enum EchoFilter {
    /// After acoustic cleaning: a line goes only when every one of its words sits in a run of five
    /// words matched in time (IoU of at least 0.8, 400 ms apart at most) on the other side.
    static func dropResidualEchoes(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        struct Token {
            let text: String
            let line: Int
            let start: Int
            let end: Int
        }
        struct Window {
            let key: String
            let start: Int
            let end: Int
            let positions: Range<Int>
        }
        func windows(_ tokens: [Token]) -> [Window] {
            guard tokens.count >= 5 else { return [] }
            return (0...(tokens.count - 5)).compactMap { i in
                let span = tokens[i..<i + 5]
                guard zip(span, span.dropFirst()).allSatisfy({ $1.start - $0.end <= 400 }) else { return nil }
                return Window(
                    key: span.map(\.text).joined(separator: "\u{1f}"),
                    start: span.map(\.start).min()!, end: span.map(\.end).max()!, positions: i..<i + 5
                )
            }
        }
        var mine: [Token] = [], theirs: [Token] = []
        var counts: [Int: Int] = [:]
        for (index, line) in lines.enumerated() {
            let tokens = words(line.text).map { Token(text: $0, line: index, start: line.startMs, end: line.endMs) }
            counts[index] = tokens.count
            if line.speaker == .me { mine += tokens } else { theirs += tokens }
        }
        var remote: [String: [Window]] = [:]
        var longest = 0
        for window in windows(theirs) {
            remote[window.key, default: []].append(window)
            longest = max(longest, window.end - window.start)
        }
        for key in remote.keys { remote[key]!.sort { $0.start < $1.start } }

        var matched: Set<Int> = []
        for window in windows(mine) {
            guard let candidates = remote[window.key] else { continue }
            var lo = 0, hi = candidates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[mid].start < window.start - longest - 400 { lo = mid + 1 } else { hi = mid }
            }
            var index = lo
            while index < candidates.count, candidates[index].start <= window.end + 400 {
                let other = candidates[index]
                let overlap = min(window.end, other.end) - max(window.start, other.start)
                let union = max(window.end, other.end) - min(window.start, other.start)
                if union > 0, Double(overlap) / Double(union) >= 0.8 {
                    matched.formUnion(window.positions)
                    break
                }
                index += 1
            }
        }
        var matchedCounts: [Int: Int] = [:]
        for position in matched { matchedCounts[mine[position].line, default: 0] += 1 }
        let removable = Set(matchedCounts.compactMap { $0.value == counts[$0.key] && $0.value > 0 ? $0.key : nil })
        return lines.enumerated().compactMap { removable.contains($0.offset) ? nil : $0.element }
    }

    /// Without acoustic cleaning: a line goes when most of its words appear, in order, in what the other
    /// side said around it. Lines of one or two words need an exact match.
    static func dropEchoes(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        let overlapPadMs = 400
        let containmentThreshold = 0.7
        let theirs = lines.filter { $0.speaker == .other }
        guard !theirs.isEmpty else { return lines }

        func isEcho(_ line: TranscriptLine) -> Bool {
            let overlapping = theirs.filter {
                min(line.endMs, $0.endMs + overlapPadMs) > max(line.startMs, $0.startMs - overlapPadMs)
            }
            let mine = words(line.text)
            guard !overlapping.isEmpty, !mine.isEmpty else { return false }
            let others = overlapping.flatMap { words($0.text) }
            let contained = Double(subsequenceLength(of: mine, in: others)) / Double(mine.count)
            return mine.count <= 2 ? contained == 1.0 : contained >= containmentThreshold
        }
        return lines.filter { $0.speaker != .me || !isEcho($0) }
    }

    /// Lowercased words without punctuation; Cyrillic counts as letters.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " }
            .split(separator: " ")
            .map(String.init)
    }

    private static func subsequenceLength(of a: [String], in b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = prev
        for i in 1...a.count {
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], curr[j - 1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
