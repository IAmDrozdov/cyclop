import Foundation
@preconcurrency import FluidAudio

/// Where the speech models live and whether they are already on disk.
enum SpeechModels {
    static var recognitionFolder: URL { AsrModels.defaultCacheDirectory(for: .v3) }

    static var isRecognitionReady: Bool { AsrModels.modelsExist(at: recognitionFolder) }

    static var separationFolder: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer) }

    /// Each required file is somewhere under the separator's folder; the layout inside is FluidAudio's own.
    static var isSeparationReady: Bool {
        guard let walker = FileManager.default.enumerator(atPath: separationFolder.path) else { return false }
        var found: Set<String> = []
        for case let path as String in walker { found.insert((path as NSString).lastPathComponent) }
        return ModelNames.OfflineDiarizer.requiredModels.isSubset(of: found)
    }

    static var isReady: Bool { isRecognitionReady && isSeparationReady }
}
