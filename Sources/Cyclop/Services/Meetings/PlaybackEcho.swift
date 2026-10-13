@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// Drops owner lines that overlap the other side and are playback, judged on the cleaned microphone's audio:
/// either almost nothing is left there (the recogniser read words into the canceller's residue), or what is
/// left is still mostly the system track (the canceller let playback through). The owner's own voice survives
/// cancellation and is not in the system track, so it stays: when unsure, the line stays.
enum PlaybackEcho {
    static let sampleRate = 16_000
    /// Share of a line's microphone energy the system track must explain for the line to go.
    static let threshold = 0.75
    /// Below this level (dBFS) the line is residue: the canceller's gate already silences hops under -45 dBFS.
    static let residueLevel = -50.0
    static let frame = 2_048
    static let hop = 512
    /// Delays searched, in hops: 0...512 ms.
    static let maxDelayHops = 16
    /// Fewer frames than this and coherence is too noisy to judge; the line stays.
    static let minimumFrames = 8

    /// Lines of the owner that overlap the other side and are mostly playback go; both files are 16 kHz mono
    /// on the meeting's timeline (`OfflineEchoAudio`). A file that cannot be read keeps every line.
    static func dropPlayback(_ lines: [TranscriptLine], microphone: URL, system: URL) -> [TranscriptLine] {
        let theirs = lines.filter { $0.speaker == .other }
        guard !theirs.isEmpty,
            let mic = try? AVAudioFile(forReading: microphone, commonFormat: .pcmFormatFloat32, interleaved: false),
            let far = try? AVAudioFile(forReading: system, commonFormat: .pcmFormatFloat32, interleaved: false),
            mic.processingFormat.sampleRate == Double(sampleRate), far.processingFormat.sampleRate == Double(sampleRate)
        else { return lines }
        let pad = 400
        return lines.filter { line in
            guard line.speaker == .me,
                theirs.contains(where: { min(line.endMs, $0.endMs + pad) > max(line.startMs, $0.startMs - pad) })
            else { return true }
            let start = line.startMs * sampleRate / 1000, end = line.endMs * sampleRate / 1000
            let lead = maxDelayHops * hop
            guard let near = try? samples(of: mic, from: start, count: end - start),
                let reference = try? samples(of: far, from: start - lead, count: end - start + lead)
            else { return true }
            return level(near) >= residueLevel && explainedShare(microphone: near, system: reference) < threshold
        }
    }

    /// Share (0...1) of `microphone`'s energy explained by `system`, which starts `maxDelayHops` hops earlier.
    static func explainedShare(microphone: [Float], system: [Float]) -> Double {
        let frames = (microphone.count - frame) / hop + 1
        guard frames >= minimumFrames, system.count >= microphone.count + maxDelayHops * hop else { return 0 }
        let spectra = Spectra(size: frame)
        let near = (0..<frames).map { spectra.of(microphone, at: $0 * hop) }
        let far = (0..<(frames + maxDelayHops)).map { spectra.of(system, at: $0 * hop) }
        let bins = frame / 2
        var best = 0.0
        for delay in 0...maxDelayHops {
            var sxx = [Double](repeating: 0, count: bins), syy = sxx, re = sxx, im = sxx
            for j in 0..<frames {
                let y = near[j], x = far[j + maxDelayHops - delay]
                for k in 1..<bins {
                    let xr = Double(x.re[k]), xi = Double(x.im[k]), yr = Double(y.re[k]), yi = Double(y.im[k])
                    sxx[k] += xr * xr + xi * xi
                    syy[k] += yr * yr + yi * yi
                    re[k] += yr * xr + yi * xi
                    im[k] += yi * xr - yr * xi
                }
            }
            var explained = 0.0, total = 0.0
            for k in 1..<bins where sxx[k] > 0 {
                explained += (re[k] * re[k] + im[k] * im[k]) / sxx[k]
                total += syy[k]
            }
            if total > 0 { best = max(best, explained / total) }
        }
        return min(best, 1)
    }

    /// RMS level in dBFS.
    static func level(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -200 }
        var power: Float = 0
        vDSP_measqv(samples, 1, &power, vDSP_Length(samples.count))
        return 10 * log10(max(Double(power), 1e-20))
    }

    /// Reads `count` samples from `start`; before the file's start and past its end is silence.
    private static func samples(of file: AVAudioFile, from start: Int, count: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: max(0, count))
        let first = max(0, start), last = min(Int(file.length), start + count)
        guard last > first else { return out }
        file.framePosition = AVAudioFramePosition(first)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(last - first))
        else { return out }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { out[first - start + i] = data[i] }
        return out
    }

    /// Hann-windowed real FFT of one frame.
    private final class Spectra {
        struct Frame {
            var re: [Float]
            var im: [Float]
        }

        private let size: Int
        private let log2n: vDSP_Length
        private let setup: FFTSetup
        private let window: [Float]

        init(size: Int) {
            self.size = size
            log2n = vDSP_Length(log2(Double(size)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            var window = [Float](repeating: 0, count: size)
            vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
            self.window = window
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func of(_ signal: [Float], at offset: Int) -> Frame {
            var frame = [Float](repeating: 0, count: size)
            let available = max(0, min(size, signal.count - offset))
            if available > 0 {
                signal.withUnsafeBufferPointer { s in
                    vDSP_vmul(s.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(available))
                }
            }
            var result = Frame(re: [Float](repeating: 0, count: size / 2), im: [Float](repeating: 0, count: size / 2))
            result.re.withUnsafeMutableBufferPointer { re in
                result.im.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return result
        }
    }
}
