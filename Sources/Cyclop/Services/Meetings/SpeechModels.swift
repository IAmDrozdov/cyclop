import Foundation
@preconcurrency import FluidAudio

/// Where the speech models live and whether they are already on disk.
enum SpeechModels {
    static var recognitionFolder: URL { AsrModels.defaultCacheDirectory(for: .v3) }

    static var isRecognitionReady: Bool { AsrModels.modelsExist(at: recognitionFolder) }

    /// Sortformer's balanced set: on call-quality audio of two to six real voices it told voices apart
    /// far better than the offline clustering, which merged them (docs/architecture.md, Meetings).
    static let separationConfig = SortformerConfig.balancedV2_1

    static var separationFolder: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .sortformer) }

    static var isSeparationReady: Bool {
        guard let bundle = ModelNames.Sortformer.bundle(for: separationConfig) else { return false }
        let model = separationFolder.appendingPathComponent(bundle, isDirectory: true)
        return FileManager.default.fileExists(atPath: model.appendingPathComponent("coremldata.bin").path)
    }

    static var isReady: Bool { isRecognitionReady && isSeparationReady }
}
