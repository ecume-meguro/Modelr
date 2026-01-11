import Foundation

// MARK: - Generic Python Communication

struct PythonRequest: Codable {
    let command: String
    let params: [String: AnyCodable]
    let messageId: String

    init(command: String, params: [String: AnyCodable] = [:]) {
        self.command = command
        self.params = params
        self.messageId = UUID().uuidString
    }
}

/// A type-safe wrapper for heterogeneous dictionary values in JSON
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Bool.self) { value = x }
        else if let x = try? container.decode(Int.self) { value = x }
        else if let x = try? container.decode(Double.self) { value = x }
        else if let x = try? container.decode(String.self) { value = x }
        else if let x = try? container.decode([String: AnyCodable].self) { value = x.mapValues { $0.value } }
        else if let x = try? container.decode([AnyCodable].self) { value = x.map { $0.value } }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let x = value as? Bool { try container.encode(x) }
        else if let x = value as? Int { try container.encode(x) }
        else if let x = value as? Double { try container.encode(x) }
        else if let x = value as? String { try container.encode(x) }
        else if let x = value as? [String: Any] { try container.encode(x.mapValues { AnyCodable($0) }) }
        else if let x = value as? [Any] { try container.encode(x.map { AnyCodable($0) }) }
    }
}

// MARK: - SAM Python Communication Protocol

struct SAMRequest: Codable {
    static let version = "1.0"
    static let maxPoints = 100

    let messageId: String
    let version: String
    let command: String  // "set_image", "predict", "reset"
    let imagePath: String?
    let points: [[Int]]?  // [[x, y], [x, y], ...]
    let labels: [Int]?    // [1, 1, 0, ...] - 1=foreground, 0=background
    let box: [Int]?       // [x1, y1, x2, y2]
    let text: String?     // Text prompt for SAM3 (e.g., "dog", "person")
    let model: String?

    init(command: String, imagePath: String? = nil, points: [[Int]]? = nil, labels: [Int]? = nil, box: [Int]? = nil, text: String? = nil, model: String? = nil) {
        self.messageId = UUID().uuidString
        self.version = Self.version
        self.command = command
        self.imagePath = imagePath
        self.points = points
        self.labels = labels
        self.box = box
        self.text = text
        self.model = model
    }

    func validate() throws {
        let validCommands = ["set_image", "predict", "reset"]
        guard validCommands.contains(command) else {
            throw AppError.validation(field: "command", message: "Invalid command: \(command)")
        }

        switch command {
        case "set_image":
            guard imagePath != nil && !imagePath!.isEmpty else {
                throw AppError.validation(field: "imagePath", message: "Required")
            }

        case "predict":
            guard points != nil || box != nil || text != nil else {
                throw AppError.validation(field: "prompts", message: "points, box, or text required")
            }

            if let points = points {
                guard points.count <= Self.maxPoints else {
                    throw AppError.validation(field: "points", message: "Too many points")
                }
            }

        default:
            break
        }
    }
}

struct SAMResponse: Codable {
    let messageId: String?
    let version: String?
    let success: Bool
    let masks: [String]?      // Multiple mask paths
    let scores: [Double]?     // Confidence scores for each mask
    let selectedIndex: Int?   // Currently selected mask index
    let maskPath: String?     // Legacy single mask path
    let imagePath: String?    // Path to processed image (e.g. background removed)
    let error: String?
    let inferenceTimeMs: Int?
    let ready: Bool?
    let score: Double?        // Legacy field, use scores instead
    let confidenceMapPath: String?  // Per-pixel confidence heatmap
    let width: Int?           // Image width from set_image
    let height: Int?          // Image height from set_image

    var primaryMaskPath: String? {
        return masks?.first ?? maskPath
    }

    var primaryScore: Double? {
        return scores?.first ?? score
    }
}

// MARK: - Hunyuan Python Communication Protocol

struct HunyuanRequest: Codable {
    let messageId: String
    let command: String  // "generate", "ping", "exit"
    let imagePath: String?
    let maskPath: String?
    let outputPath: String?
    let steps: Int?
    let resolution: Int?
    let guidanceScale: Double?
    let boxV: Double?
    let mcLevel: Double?

    init(
        command: String,
        imagePath: String? = nil,
        maskPath: String? = nil,
        outputPath: String? = nil,
        steps: Int? = nil,
        resolution: Int? = nil,
        guidanceScale: Double? = nil,
        boxV: Double? = nil,
        mcLevel: Double? = nil
    ) {
        self.messageId = UUID().uuidString
        self.command = command
        self.imagePath = imagePath
        self.maskPath = maskPath
        self.outputPath = outputPath
        self.steps = steps
        self.resolution = resolution
        self.guidanceScale = guidanceScale
        self.boxV = boxV
        self.mcLevel = mcLevel
    }
}

struct HunyuanResponse: Codable {
    let success: Bool
    let messageId: String?
    let type: String?         // "progress", "complete", "error"
    let stage: String?        // "loading", "diffusion", "exporting"
    let progress: Double?     // 0.0 - 1.0
    let detail: String?       // Progress detail message
    let outputPath: String?   // Path to generated model
    let error: String?
    let ready: Bool?          // true when server is initialized
    let device: String?       // e.g. "mps", "cuda", "cpu"
    let server: String?       // e.g. "hunyuan"
    let variant: String?      // e.g. "mini", "std"
    let status: String?       // e.g. "pong", "exiting"
}

// MARK: - VLM Python Communication Protocol

struct VLMRequest: Codable {
    let messageId: String
    let command: String  // "set_image", "describe", "name", "ping", "exit"
    let imagePath: String?
    let prompt: String?
    let maxTokens: Int?
    let temperature: Double?

    init(command: String, imagePath: String? = nil, prompt: String? = nil, maxTokens: Int? = nil, temperature: Double? = nil) {
        self.messageId = UUID().uuidString
        self.command = command
        self.imagePath = imagePath
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

struct VLMResponse: Codable {
    let success: Bool
    let description: String?      // The detected object description
    let rawOutput: String?        // Raw VLM output before cleaning
    let error: String?
    let inferenceTimeMs: Int?
    let ready: Bool?              // true when server is initialized
    let device: String?           // e.g. "mlx"
    let server: String?           // e.g. "vlm_wrapper"
    let status: String?           // e.g. "pong", "exiting"
    let width: Int?               // Image width from set_image
    let height: Int?              // Image height from set_image
}

// MARK: - Text-to-Image Python Communication Protocol

struct T2IRequest: Codable {
    let messageId: String
    let command: String  // "generate", "ping", "cancel", "exit"
    let prompt: String?
    let negativePrompt: String?
    let width: Int?
    let height: Int?
    let steps: Int?
    let guidanceScale: Float?
    let seed: Int?
    let outputPath: String?

    init(
        command: String,
        prompt: String? = nil,
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        guidanceScale: Float? = nil,
        seed: Int? = nil,
        outputPath: String? = nil
    ) {
        self.messageId = UUID().uuidString
        self.command = command
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.outputPath = outputPath
    }
}

struct T2IResponse: Codable {
    let success: Bool
    let type: String?         // "progress", "complete", "error", "cancelled"
    let messageId: String?
    let imagePath: String?    // Path to generated image
    let error: String?
    let progress: Float?      // 0.0 - 1.0
    let stage: String?        // "encoding", "diffusion", "saving"
    let detail: String?       // Progress detail message
    let seed: Int?            // Seed used for generation
    let ready: Bool?          // true when server is initialized
    let device: String?       // e.g. "mps", "cuda", "cpu"
    let server: String?       // e.g. "t2i"
    let model: String?        // e.g. "stable-diffusion-v1-5"
    let status: String?       // e.g. "pong", "exiting"
}
