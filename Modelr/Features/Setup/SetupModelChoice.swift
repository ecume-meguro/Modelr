import Foundation

/// Model choice for initial setup - only mini model supported
enum SetupModelChoice: String, CaseIterable {
    case fast = "fast"  // mini (Hunyuan3D-2 Mini) - only supported option

    var displayName: String { "Hunyuan3D Mini" }
    var userBenefitLabel: String { "3D Generation" }
    var ctaLabel: String { "Install" }
    var modelVariant: String { "mini" }
    var modelName: String { "Hunyuan3D-2 Mini" }
    var description: String { "Fast, efficient 3D generation" }
    var architecture: String { "DiT v2 Mini" }
    var estimatedGenerationTime: String { "~30s" }
    var vramRequirement: String { "8GB+" }
    var memoryRequirementGB: Int { 8 }

    var downloadSize: String {
        let sizeGb = ConfigurationService.shared.hunyuanMiniModelSizeGb
        return "~\(String(format: "%.1f", sizeGb)) GB"
    }

    var formattedSize: String { downloadSize }

    /// Total download size in bytes for space calculations (SAM + VLM + Hunyuan)
    var sizeBytes: Int64 {
        let config = ConfigurationService.shared
        let samBytes = Int64(config.samModelSizeGb * 1_000_000_000)
        let vlmBytes = Int64(config.vlmModelSizeGb * 1_000_000_000)
        let hunyuanBytes = Int64(config.hunyuanMiniModelSizeGb * 1_000_000_000)
        return samBytes + vlmBytes + hunyuanBytes
    }

    var huggingFaceURL: URL? {
        URL(string: "https://huggingface.co/tencent/Hunyuan3D-2mini/tree/main/hunyuan3d-dit-v2-mini")
    }
}
