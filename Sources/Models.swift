import Foundation

/// The shape model to generate with. Each maps to a self-contained DiT weights dir
/// (config.yaml + model.fp16.safetensors bundling DINO + DiT + VAE).
enum ModelChoice: String, CaseIterable, Identifiable {
    case mini, miniTurbo, standard, standardTurbo   // 2mini, 2mini-turbo, 2.0, 2.0-turbo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mini:          return "Mini"
        case .miniTurbo:     return "Mini Turbo"
        case .standard:      return "Standard"
        case .standardTurbo: return "Standard Turbo"
        }
    }

    var detail: String {
        switch self {
        case .mini:          return "2mini · 0.6B · fast"
        case .miniTurbo:     return "2mini distilled · 8-step · fastest"
        case .standard:      return "2.0 · 1.1B · best detail"
        case .standardTurbo: return "2.0 distilled · 8-step · sweet spot"
        }
    }

    var weightsSubpath: String {
        switch self {
        case .mini:          return "weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini"
        case .miniTurbo:     return "weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini-turbo"
        case .standard:      return "weights/Hunyuan3D-2/hunyuan3d-dit-v2-0"
        case .standardTurbo: return "weights/Hunyuan3D-2/hunyuan3d-dit-v2-0-turbo"
        }
    }

    /// Distilled (turbo) checkpoints run a consistency schedule in far fewer steps.
    var steps: Int {
        switch self {
        case .miniTurbo, .standardTurbo: return 8
        case .mini, .standard:           return 30
        }
    }

    /// Faster → Smarter ordering for the effort slider.
    static let ordered: [ModelChoice] = [.miniTurbo, .mini, .standardTurbo, .standard]
}

/// Weight quantization of the DiT + DINO block linears (VAE always stays fp16).
enum Quantization: String, CaseIterable, Identifiable {
    case full, int8, int4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full"
        case .int8: return "8-bit"
        case .int4: return "4-bit"
        }
    }

    var detail: String {
        switch self {
        case .full: return "fp16 · best quality"
        case .int8: return "near-lossless"
        case .int4: return "smallest · faster"
        }
    }

    /// CLI value for --quantize (0 = off).
    var flag: Int {
        switch self {
        case .full: return 0
        case .int8: return 8
        case .int4: return 4
        }
    }

    /// Smaller/faster → best-quality ordering for the slider.
    static let ordered: [Quantization] = [.int4, .int8, .full]
}

/// Normal-mode quality ladder: one slider that bundles model + steps + octree.
/// Quantization is fixed at 8-bit in normal mode.
enum QualityPreset: String, CaseIterable, Identifiable {
    case fastest, fast, balanced, high, max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fastest:  return "Fastest"
        case .fast:     return "Fast"
        case .balanced: return "Balanced"
        case .high:     return "High"
        case .max:      return "Max"
        }
    }

    var model: ModelChoice {
        switch self {
        case .fastest:               return .miniTurbo
        case .fast:                  return .standardTurbo
        case .balanced, .high, .max: return .standard
        }
    }

    var steps: Int {
        switch self {
        case .fastest, .fast: return 8       // distilled (turbo)
        case .balanced:       return 30
        case .high:           return 40
        case .max:            return 50
        }
    }

    var octree: Int {
        switch self {
        case .fastest:  return 192
        case .fast:     return 256
        case .balanced: return 256
        case .high:     return 320
        case .max:      return 384
        }
    }

    var detail: String { "\(model.label) · \(steps) steps · grid \(octree)" }

    static let ordered: [QualityPreset] = [.fastest, .fast, .balanced, .high, .max]
    static let octreeStops = [128, 192, 256, 320, 384, 448, 512]
}

/// The fully-resolved parameters for one run (from normal preset or advanced fields).
struct RunSettings {
    let model: ModelChoice
    let quant: Quantization
    let steps: Int
    let guidance: Double
    let octree: Int
}

/// Normal-mode paint quality ladder (one slider): bundles render res, diffusion
/// steps, texture size, and super-resolution.
enum PaintQuality: String, CaseIterable, Identifiable {
    case fast, balanced, high, max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast:     return "Fast"
        case .balanced: return "Balanced"
        case .high:     return "High"
        case .max:      return "Max"
        }
    }
    var res: Int {
        switch self {
        case .fast: return 384
        default:    return 512
        }
    }
    var steps: Int {
        switch self {
        case .fast: return 8
        case .balanced: return 10
        case .high: return 15
        case .max: return 20
        }
    }
    var tex: Int {
        switch self {
        case .fast: return 1024
        case .balanced, .high: return 2048
        case .max: return 4096
        }
    }
    var superres: Bool {
        switch self {
        case .fast, .balanced: return false
        case .high, .max: return true
        }
    }
    /// Mesh-detail budget: the painted mesh is decimated to this many faces before
    /// UV-unwrap. The GPU rasterizer is cheap; xatlas (CPU) is the cost that scales.
    var faces: Int {
        switch self {
        case .fast:     return 40_000
        case .balanced: return 120_000
        case .high:     return 250_000
        case .max:      return 400_000
        }
    }
    var detail: String { "\(res)px · \(steps) steps · \(faces / 1000)k tris\(superres ? " · 4× SR" : "")" }

    static let ordered: [PaintQuality] = [.fast, .balanced, .high, .max]
    static let texStops = [1024, 2048, 4096]
    static let faceStops = [40_000, 80_000, 120_000, 200_000, 250_000, 400_000]
}

struct PaintSettings {
    let res: Int
    let steps: Int
    let tex: Int
    let superres: Bool
    let faces: Int
}

/// Whether a saved version is an untextured shape or a textured paint result.
enum GenerationKind: String, Codable { case shape, paint }

/// A single image → 3D shape project. Persisted as JSON; its files live in a
/// per-project folder under Application Support.
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var sourceImageName: String?   // the original imported image
    var inputImageName: String?    // processed image fed to the model (e.g. bg-removed)
    var outputMeshName: String?    // legacy single output (migrated into generations)
    var modelRaw: String?
    var quantRaw: String?
    var removeBackgroundRaw: Bool?
    var generationsRaw: [Generation]?
    var selectedGenerationID: UUID?
    var advancedModeRaw: Bool?
    var qualityRaw: String?
    var stepsRaw: Int?
    var guidanceRaw: Double?
    var octreeRaw: Int?
    var paintAdvancedRaw: Bool?
    var paintQualityRaw: String?
    var paintStepsRaw: Int?
    var paintResRaw: Int?
    var paintTexRaw: Int?
    var paintSuperresRaw: Bool?
    var paintFacesRaw: Int?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    var removeBackground: Bool {
        get { removeBackgroundRaw ?? false }
        set { removeBackgroundRaw = newValue }
    }

    /// All saved generations, oldest → newest.
    var generations: [Generation] {
        get { generationsRaw ?? [] }
        set { generationsRaw = newValue }
    }

    /// The generation currently shown in the viewer (selected, else the newest).
    var currentGeneration: Generation? {
        if let id = selectedGenerationID, let g = generations.first(where: { $0.id == id }) { return g }
        return generations.last
    }

    var model: ModelChoice {
        get { modelRaw.flatMap(ModelChoice.init(rawValue:)) ?? .mini }
        set { modelRaw = newValue.rawValue }
    }

    var quantization: Quantization {
        get { quantRaw.flatMap(Quantization.init(rawValue:)) ?? .full }
        set { quantRaw = newValue.rawValue }
    }

    var advancedMode: Bool {
        get { advancedModeRaw ?? false }
        set { advancedModeRaw = newValue }
    }
    var quality: QualityPreset {
        get { qualityRaw.flatMap(QualityPreset.init(rawValue:)) ?? .fast }
        set { qualityRaw = newValue.rawValue }
    }
    var steps: Int {
        get { stepsRaw ?? model.steps }
        set { stepsRaw = newValue }
    }
    var guidance: Double {
        get { guidanceRaw ?? 5.0 }
        set { guidanceRaw = newValue }
    }
    var octree: Int {
        get { octreeRaw ?? 256 }
        set { octreeRaw = newValue }
    }

    /// Effective run parameters from the current mode (normal preset or advanced fields).
    var resolvedSettings: RunSettings {
        if advancedMode {
            return RunSettings(model: model, quant: quantization, steps: steps,
                               guidance: guidance, octree: octree)
        }
        let p = quality
        return RunSettings(model: p.model, quant: .int8, steps: p.steps,
                           guidance: 5.0, octree: p.octree)
    }

    // MARK: paint config

    var paintAdvanced: Bool {
        get { paintAdvancedRaw ?? false }
        set { paintAdvancedRaw = newValue }
    }
    var paintQuality: PaintQuality {
        get { paintQualityRaw.flatMap(PaintQuality.init(rawValue:)) ?? .fast }
        set { paintQualityRaw = newValue.rawValue }
    }
    var paintSteps: Int {
        get { paintStepsRaw ?? 10 }
        set { paintStepsRaw = newValue }
    }
    var paintRes: Int {
        get { paintResRaw ?? 512 }
        set { paintResRaw = newValue }
    }
    var paintTex: Int {
        get { paintTexRaw ?? 2048 }
        set { paintTexRaw = newValue }
    }
    var paintSuperres: Bool {
        get { paintSuperresRaw ?? false }
        set { paintSuperresRaw = newValue }
    }
    var paintFaces: Int {
        get { paintFacesRaw ?? 120_000 }
        set { paintFacesRaw = newValue }
    }

    var resolvedPaintSettings: PaintSettings {
        if paintAdvanced {
            return PaintSettings(res: paintRes, steps: paintSteps, tex: paintTex,
                                 superres: paintSuperres, faces: paintFaces)
        }
        let q = paintQuality
        return PaintSettings(res: q.res, steps: q.steps, tex: q.tex, superres: q.superres, faces: q.faces)
    }
}

/// One saved model output, with the settings + input that produced it. Immutable.
struct Generation: Identifiable, Codable, Hashable {
    let id: UUID
    var createdAt: Date
    var modelRaw: String
    var quantRaw: String
    var steps: Int
    var removeBackground: Bool
    var meshFileName: String        // gen_<id>.mesh
    var inputFileName: String       // snapshot of the input that was fed to the model
    var durationSeconds: Double?
    var guidanceRaw: Double? = nil
    var octreeRaw: Int? = nil
    var sourceFileName: String? = nil   // original image snapshot (for re-editing)
    var maskFileName: String? = nil     // mask snapshot (nil if no background removal)
    var paintedMeshFileName: String? = nil    // (legacy) textured .tmesh
    var paintedTextureFileName: String? = nil // for a paint version: the baked texture
    var kindRaw: String? = nil          // shape (default) or paint
    var sourceShapeID: UUID? = nil      // for a paint version: the shape it textured
    var paintResRaw: Int? = nil
    var paintStepsRaw: Int? = nil
    var paintTexRaw: Int? = nil
    var paintFacesRaw: Int? = nil
    var paintSuperresRaw: Bool? = nil

    var kind: GenerationKind { GenerationKind(rawValue: kindRaw ?? "shape") ?? .shape }
    var isPainted: Bool { kind == .paint }

    var model: ModelChoice { ModelChoice(rawValue: modelRaw) ?? .mini }
    var quantization: Quantization { Quantization(rawValue: quantRaw) ?? .full }
    var guidance: Double { guidanceRaw ?? 5.0 }
    var octree: Int { octreeRaw ?? 256 }
}

/// Transient (not persisted) generation state for a project.
/// `stage` is the clean label (main view); `detail` is e.g. "12/30" (sidebar);
/// `fraction` (nil = indeterminate) drives the progress bar.
enum GenerationStatus: Equatable {
    case idle
    case running(stage: String, detail: String?, fraction: Double?)
    case done
    case failed(String)
}
