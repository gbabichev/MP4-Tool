import Foundation

struct ProcessingPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var modeRawValue: String
    var crfValue: Double
    var resolutionRawValue: String
    var encoderPresetRawValue: String
    var encodeVideo: Bool
    var encodeAudio: Bool
    var createSubfolders: Bool
    var automaticRename: Bool
    var deleteOriginal: Bool
    var keepEnglishAudioOnly: Bool
    var keepEnglishSubtitlesOnly: Bool
    var postProcessScriptPath: String
    var postProcessScriptRunTimingRawValue: String
    var postProcessScriptPassFileNameAsFirstArgument: Bool

    var mode: ProcessingMode {
        ProcessingMode(rawValue: modeRawValue) ?? .encodeH265
    }

    var resolution: ResolutionOption {
        ResolutionOption(rawValue: resolutionRawValue) ?? .default
    }

    var encoderPreset: PresetOption {
        PresetOption(rawValue: encoderPresetRawValue) ?? .fast
    }

    var postProcessScriptRunTiming: PostProcessScriptRunTiming {
        PostProcessScriptRunTiming(rawValue: postProcessScriptRunTimingRawValue) ?? .afterEachItem
    }
}

extension ProcessingPreset {
    static let builtInPresets: [ProcessingPreset] = [
        ProcessingPreset(
            id: UUID(uuidString: "13EA4750-83F7-4B75-9252-8A21A730C926")!,
            name: "Default",
            modeRawValue: ProcessingMode.encodeH265.rawValue,
            crfValue: 23,
            resolutionRawValue: ResolutionOption.default.rawValue,
            encoderPresetRawValue: PresetOption.fast.rawValue,
            encodeVideo: true,
            encodeAudio: true,
            createSubfolders: false,
            automaticRename: true,
            deleteOriginal: false,
            keepEnglishAudioOnly: true,
            keepEnglishSubtitlesOnly: true,
            postProcessScriptPath: "",
            postProcessScriptRunTimingRawValue: PostProcessScriptRunTiming.afterEachItem.rawValue,
            postProcessScriptPassFileNameAsFirstArgument: false
        ),
        ProcessingPreset(
            id: UUID(uuidString: "C0841EEB-374A-454E-9B22-197336362639")!,
            name: "Animated",
            modeRawValue: ProcessingMode.encodeH265.rawValue,
            crfValue: 25,
            resolutionRawValue: ResolutionOption.default.rawValue,
            encoderPresetRawValue: PresetOption.ultrafast.rawValue,
            encodeVideo: true,
            encodeAudio: true,
            createSubfolders: false,
            automaticRename: true,
            deleteOriginal: false,
            keepEnglishAudioOnly: true,
            keepEnglishSubtitlesOnly: true,
            postProcessScriptPath: "",
            postProcessScriptRunTimingRawValue: PostProcessScriptRunTiming.afterEachItem.rawValue,
            postProcessScriptPassFileNameAsFirstArgument: false
        ),
        ProcessingPreset(
            id: UUID(uuidString: "887384C7-6F3A-456A-B21D-E8240EFE97F8")!,
            name: "Space Saver - 720p",
            modeRawValue: ProcessingMode.encodeH265.rawValue,
            crfValue: 24,
            resolutionRawValue: ResolutionOption.p720.rawValue,
            encoderPresetRawValue: PresetOption.ultrafast.rawValue,
            encodeVideo: true,
            encodeAudio: true,
            createSubfolders: false,
            automaticRename: true,
            deleteOriginal: false,
            keepEnglishAudioOnly: true,
            keepEnglishSubtitlesOnly: true,
            postProcessScriptPath: "",
            postProcessScriptRunTimingRawValue: PostProcessScriptRunTiming.afterEachItem.rawValue,
            postProcessScriptPassFileNameAsFirstArgument: false
        ),
        ProcessingPreset(
            id: UUID(uuidString: "648AF3DE-62F0-4ACF-90A4-840A421D9330")!,
            name: "Remux English Only",
            modeRawValue: ProcessingMode.remux.rawValue,
            crfValue: 23,
            resolutionRawValue: ResolutionOption.default.rawValue,
            encoderPresetRawValue: PresetOption.fast.rawValue,
            encodeVideo: true,
            encodeAudio: true,
            createSubfolders: false,
            automaticRename: true,
            deleteOriginal: false,
            keepEnglishAudioOnly: true,
            keepEnglishSubtitlesOnly: true,
            postProcessScriptPath: "",
            postProcessScriptRunTimingRawValue: PostProcessScriptRunTiming.afterEachItem.rawValue,
            postProcessScriptPassFileNameAsFirstArgument: false
        ),
        ProcessingPreset(
            id: UUID(uuidString: "8E7773E3-65C5-4E37-98BD-F97C0452FE6B")!,
            name: "Remux",
            modeRawValue: ProcessingMode.remux.rawValue,
            crfValue: 23,
            resolutionRawValue: ResolutionOption.default.rawValue,
            encoderPresetRawValue: PresetOption.fast.rawValue,
            encodeVideo: true,
            encodeAudio: true,
            createSubfolders: false,
            automaticRename: true,
            deleteOriginal: false,
            keepEnglishAudioOnly: false,
            keepEnglishSubtitlesOnly: false,
            postProcessScriptPath: "",
            postProcessScriptRunTimingRawValue: PostProcessScriptRunTiming.afterEachItem.rawValue,
            postProcessScriptPassFileNameAsFirstArgument: false
        )
    ]
}
