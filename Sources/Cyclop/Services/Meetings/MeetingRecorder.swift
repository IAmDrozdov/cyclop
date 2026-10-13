@preconcurrency import AVFoundation
import Foundation

enum MicrophoneAccess: Equatable {
    case granted, denied
}

/// When each track's first buffer arrived; nil for a track that never produced one.
struct TrackStarts: Equatable {
    var mic: Date?
    var system: Date?
    /// False when the system track never carried sound: a refused permission records silence without an error.
    var systemHeardSound = true

    /// Milliseconds from the earlier start; the earlier track gets 0.
    var offsets: MeetingMeta.Offsets {
        guard let origin = [mic, system].compactMap({ $0 }).min() else { return .init() }
        func ms(_ date: Date?) -> Int? { date.map { Int(($0.timeIntervalSince(origin) * 1000).rounded()) } }
        return .init(mic: ms(mic), system: ms(system))
    }
}

/// What the store needs from capture; a fake stands in for it in tests.
protocol MeetingCapturing: AnyObject {
    /// Peaks of each track, 0...1, read while the pane is on screen.
    var micLevel: Float { get }
    var systemLevel: Float { get }
    func requestMicrophone() async -> MicrophoneAccess
    /// Starts the system track first, then the microphone; a microphone that fails stops the system track.
    func start(micURL: URL, systemURL: URL) throws
    func stop() -> TrackStarts
}

/// Two tracks, the microphone and all system sound, each in its own file.
final class MeetingRecorder: MeetingCapturing {
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    var micLevel: Float { mic.gauge.current }
    var systemLevel: Float { system.gauge.current }

    func requestMicrophone() async -> MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        default: return .denied
        }
    }

    func start(micURL: URL, systemURL: URL) throws {
        try system.start(writingTo: systemURL)
        do {
            try mic.start(writingTo: micURL)
        } catch {
            system.stop()
            throw error
        }
    }

    func stop() -> TrackStarts {
        mic.stop()
        system.stop()
        return TrackStarts(
            mic: mic.firstBufferAt, system: system.firstBufferAt, systemHeardSound: system.gauge.heardSound
        )
    }
}
