import CryptoKit
import Darwin
import Foundation

protocol EchoCancellationBackend: AnyObject {
    var sampleRate: Int { get }
    var hopSize: Int { get }
    func process(microphone: [Float], reference: [Float]) throws -> [Float]
}

enum EchoCancellationError: Error {
    case missingAsset(URL)
    case invalidModel(URL)
    case nativeLibrary(URL, String)
    case missingSymbol(String)
    case modelLoad
    case unsupportedFormat(sampleRate: Int, hopSize: Int)
    case invalidFrame
    case processing(Int32, String)
    case invalidOutput
    case alreadyFinished
}

/// The native echo canceller (LocalVQE) and its model, both inside the app bundle.
enum LocalVQEAssets {
    static let modelName = "localvqe-v1.4-aec-200K-f32.gguf"
    static let modelSHA256 = "b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"

    struct URLs {
        let library: URL
        let model: URL
    }

    static func resolve(bundle: URL = Bundle.main.bundleURL) throws -> URLs {
        let urls = URLs(
            library: bundle.appendingPathComponent("Contents/Frameworks/liblocalvqe.dylib"),
            model: bundle.appendingPathComponent("Contents/Resources/Models/\(modelName)")
        )
        for url in [urls.library, urls.model] where !FileManager.default.isReadableFile(atPath: url.path) {
            throw EchoCancellationError.missingAsset(url)
        }
        return urls
    }
}

/// Loaded with dlopen so the package builds and tests without linking a machine-specific binary.
private final class LocalVQEBackend: EchoCancellationBackend {
    private typealias New = @convention(c) (UnsafePointer<CChar>?) -> UInt
    private typealias Free = @convention(c) (UInt) -> Void
    private typealias Process = @convention(c) (
        UInt, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<Float>?
    ) -> Int32
    private typealias IntegerProperty = @convention(c) (UInt) -> Int32
    private typealias LastError = @convention(c) (UInt) -> UnsafePointer<CChar>?
    private typealias SetNoiseGate = @convention(c) (UInt, Int32, Float) -> Int32

    let sampleRate: Int
    let hopSize: Int

    private let library: UnsafeMutableRawPointer
    private let context: UInt
    private let freeContext: Free
    private let processFrame: Process
    private let lastError: LastError

    init(libraryURL: URL, modelURL: URL) throws {
        let model = try Data(contentsOf: modelURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
        guard digest == LocalVQEAssets.modelSHA256 else { throw EchoCancellationError.invalidModel(modelURL) }

        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw EchoCancellationError.nativeLibrary(libraryURL, dlerror().map { String(cString: $0) } ?? "unknown")
        }

        // Everything is resolved and checked into locals first; the properties are set last, so a throw
        // never reaches `deinit` and nothing is freed twice.
        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let value = dlsym(library, name) else { throw EchoCancellationError.missingSymbol(name) }
            return value
        }

        let newContext: New, free: Free, process: Process, error: LastError
        let rateOf: IntegerProperty, hopOf: IntegerProperty, setGate: SetNoiseGate
        do {
            newContext = unsafeBitCast(try symbol("localvqe_new"), to: New.self)
            free = unsafeBitCast(try symbol("localvqe_free"), to: Free.self)
            process = unsafeBitCast(try symbol("localvqe_process_frame_f32"), to: Process.self)
            error = unsafeBitCast(try symbol("localvqe_last_error"), to: LastError.self)
            rateOf = unsafeBitCast(try symbol("localvqe_sample_rate"), to: IntegerProperty.self)
            hopOf = unsafeBitCast(try symbol("localvqe_hop_length"), to: IntegerProperty.self)
            setGate = unsafeBitCast(try symbol("localvqe_set_noise_gate"), to: SetNoiseGate.self)
        } catch {
            dlclose(library)
            throw error
        }

        let context = modelURL.path.withCString { newContext($0) }
        guard context != 0 else {
            dlclose(library)
            throw EchoCancellationError.modelLoad
        }
        let rate = Int(rateOf(context)), hop = Int(hopOf(context))
        guard rate == 16_000, hop == 256 else {
            free(context)
            dlclose(library)
            throw EchoCancellationError.unsupportedFormat(sampleRate: rate, hopSize: hop)
        }
        let gate = setGate(context, 0, -45)
        guard gate == 0 else {
            free(context)
            dlclose(library)
            throw EchoCancellationError.processing(gate, "noise gate")
        }

        self.library = library
        self.context = context
        self.freeContext = free
        self.processFrame = process
        self.lastError = error
        self.sampleRate = rate
        self.hopSize = hop
    }

    deinit {
        freeContext(context)
        dlclose(library)
    }

    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        guard microphone.count == hopSize, reference.count == hopSize else { throw EchoCancellationError.invalidFrame }
        var output = [Float](repeating: 0, count: hopSize)
        let result = microphone.withUnsafeBufferPointer { mic in
            reference.withUnsafeBufferPointer { far in
                output.withUnsafeMutableBufferPointer { cleaned in
                    processFrame(context, mic.baseAddress, far.baseAddress, Int32(hopSize), cleaned.baseAddress)
                }
            }
        }
        guard result == 0 else {
            throw EchoCancellationError.processing(result, lastError(context).map(String.init(cString:)) ?? "unknown")
        }
        guard output.allSatisfy(\.isFinite) else { throw EchoCancellationError.invalidOutput }
        return output
    }
}

/// Streams 256-sample hops through the model. Its output lags the input by one hop, so one input hop
/// stays pending, the startup output is dropped, and `finish()` flushes the last one.
final class EchoCanceller {
    static let sampleRate = 16_000
    static let frameSize = 256
    /// After playback was heard, the model keeps control for this long past the last reference sample.
    static let referenceHangoverSamples = sampleRate
    /// A reference sample below this (-80 dBFS) is silence: codec or resampler residue, never playback.
    static let silenceFloor: Float = 1e-4

    private enum Preservation {
        case none
        case all
        case mixed([Bool])
    }

    private struct Pending {
        let microphone: [Float]
        let preservation: Preservation
    }

    private let backend: EchoCancellationBackend
    private var pending: Pending?
    private var hasSeenActiveReference = false
    private var silentReferenceSamples = 0
    private var finished = false

    convenience init(bundle: URL = Bundle.main.bundleURL) throws {
        let assets = try LocalVQEAssets.resolve(bundle: bundle)
        try self.init(backend: LocalVQEBackend(libraryURL: assets.library, modelURL: assets.model))
    }

    init(backend: EchoCancellationBackend) throws {
        guard backend.sampleRate == Self.sampleRate, backend.hopSize == Self.frameSize else {
            throw EchoCancellationError.unsupportedFormat(sampleRate: backend.sampleRate, hopSize: backend.hopSize)
        }
        self.backend = backend
    }

    /// The previous input hop, now aligned with the model's output; nil for the first call.
    func process(microphone: [Float], reference: [Float]) throws -> [Float]? {
        guard !finished else { throw EchoCancellationError.alreadyFinished }
        guard microphone.count == Self.frameSize, reference.count == Self.frameSize else {
            throw EchoCancellationError.invalidFrame
        }
        let preservation = preservation(for: reference)
        let previous = pending
        pending = Pending(microphone: microphone, preservation: preservation)
        // Until playback starts the model is not fed: its delay estimator locks within 3.5 s, onto silence otherwise.
        guard hasSeenActiveReference else { return previous?.microphone }
        let candidate = try backend.process(microphone: microphone, reference: reference)
        guard let previous else { return nil }
        return select(candidate: candidate, pending: previous)
    }

    /// Feeds playback to the model and drops the output, so its delay estimate and filter have settled
    /// before the first real hop. Only before `process`.
    func warmUp(microphone: [Float], reference: [Float]) throws {
        guard pending == nil, !finished else { throw EchoCancellationError.alreadyFinished }
        guard microphone.count == Self.frameSize, reference.count == Self.frameSize else {
            throw EchoCancellationError.invalidFrame
        }
        _ = try backend.process(microphone: microphone, reference: reference)
    }

    func finish() throws -> [Float]? {
        guard !finished else { return nil }
        finished = true
        guard let pending else { return nil }
        self.pending = nil
        guard hasSeenActiveReference else { return pending.microphone }
        let zeros = [Float](repeating: 0, count: Self.frameSize)
        let candidate = try backend.process(microphone: zeros, reference: zeros)
        return select(candidate: candidate, pending: pending)
    }

    /// Before any playback the microphone passes untouched; the model takes over once playback has begun.
    private func preservation(for reference: [Float]) -> Preservation {
        var first: Bool?
        var mixed: [Bool]?
        for index in reference.indices {
            let preserve: Bool
            if abs(reference[index]) >= Self.silenceFloor {
                hasSeenActiveReference = true
                silentReferenceSamples = 0
                preserve = false
            } else if !hasSeenActiveReference {
                preserve = true
            } else {
                silentReferenceSamples = min(silentReferenceSamples + 1, Self.referenceHangoverSamples + 1)
                preserve = silentReferenceSamples > Self.referenceHangoverSamples
            }
            if let first, preserve != first, mixed == nil {
                mixed = [Bool](repeating: first, count: Self.frameSize)
            } else if first == nil {
                first = preserve
            }
            mixed?[index] = preserve
        }
        if let mixed { return .mixed(mixed) }
        return first == true ? .all : .none
    }

    private func select(candidate: [Float], pending: Pending) -> [Float] {
        switch pending.preservation {
        case .none: return candidate
        case .all: return pending.microphone
        case .mixed(let preserve):
            var output = candidate
            for index in output.indices where preserve[index] { output[index] = pending.microphone[index] }
            return output
        }
    }
}
