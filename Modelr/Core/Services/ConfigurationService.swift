import os.log
import Foundation
import SwiftUI

/// Service to provide configuration values from project_config.json
/// Ensures synchronization between Swift and Python environments
class ConfigurationService: ObservableObject {
    static let shared = ConfigurationService()

    struct ProjectConfig: Codable {
        struct Models: Codable {
            struct SAM2: Codable {
                let defaultType: String
                let maskColor: [Int]
                let modelSizeGb: Double?

                enum CodingKeys: String, CodingKey {
                    case defaultType = "default_type"
                    case maskColor = "mask_color"
                    case modelSizeGb = "model_size_gb"
                }
            }
            struct VLM: Codable {
                let modelSizeGb: Double

                enum CodingKeys: String, CodingKey {
                    case modelSizeGb = "model_size_gb"
                }
            }
            struct Hunyuan3D: Codable {
                let defaultSteps: Int
                let defaultResolution: Int
                let miniModelSizeGb: Double
                let stdModelSizeGb: Double?

                enum CodingKeys: String, CodingKey {
                    case defaultSteps = "default_steps"
                    case defaultResolution = "default_resolution"
                    case miniModelSizeGb = "mini_model_size_gb"
                    case stdModelSizeGb = "std_model_size_gb"
                }
            }
            let sam2: SAM2
            let vlm: VLM?
            let hunyuan3d: Hunyuan3D
        }

        struct Setup: Codable {
            let uvPackagesSizeGb: Double
            let assumedDownloadSpeedMbps: Double

            enum CodingKeys: String, CodingKey {
                case uvPackagesSizeGb = "uv_packages_size_gb"
                case assumedDownloadSpeedMbps = "assumed_download_speed_mbps"
            }
        }

        struct Limits: Codable {
            let maxImageSize: Int
            let maxImageFileSizeMb: Int
            let maxModelFileSizeGb: Int

            enum CodingKeys: String, CodingKey {
                case maxImageSize = "max_image_size"
                case maxImageFileSizeMb = "max_image_file_size_mb"
                case maxModelFileSizeGb = "max_model_file_size_gb"
            }
        }

        let models: Models
        let setup: Setup?
        let limits: Limits
    }

    @Published var config: ProjectConfig?

    private init() {
        loadConfig()
    }

    func loadConfig() {
        // Try to find project_config.json in Bundle or Resources
        let configPath = Bundle.main.path(forResource: "project_config", ofType: "json") ??
                        "Resources/project_config.json"

        let url = URL(fileURLWithPath: configPath)
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            self.config = try decoder.decode(ProjectConfig.self, from: data)
            print("[Config] Loaded configuration from \(configPath)")
        } catch {
            print("[Config] Failed to load project_config.json: \(error)")
        }
    }

    // MARK: - Accessors

    var defaultSteps: Int {
        config?.models.hunyuan3d.defaultSteps ?? 50
    }

    var defaultResolution: Int {
        config?.models.hunyuan3d.defaultResolution ?? 384
    }

    var maxImageDimension: Int {
        // Cap at 4096 to prevent extreme memory usage
        // 4K images are sufficient for most use cases and keep memory reasonable
        // (4096x4096x4 = 64MB per RGBA context vs 1GB for 16K)
        min(config?.limits.maxImageSize ?? 4096, 4096)
    }

    var sam2MaskColor: Color {
        if let rgba = config?.models.sam2.maskColor, rgba.count >= 3 {
            return Color(red: Double(rgba[0])/255.0,
                         green: Double(rgba[1])/255.0,
                         blue: Double(rgba[2])/255.0,
                         opacity: rgba.count > 3 ? Double(rgba[3])/255.0 : 1.0)
        }
        return AppConstants.sam2MaskColor
    }

    var samModelSizeGb: Double {
        config?.models.sam2.modelSizeGb ?? 3.4
    }

    var hunyuanMiniModelSizeGb: Double {
        config?.models.hunyuan3d.miniModelSizeGb ?? 3.84
    }

    var hunyuanStdModelSizeGb: Double {
        config?.models.hunyuan3d.stdModelSizeGb ?? 8.5
    }

    var vlmModelSizeGb: Double {
        config?.models.vlm?.modelSizeGb ?? 1.5
    }

    var uvPackagesSizeGb: Double {
        config?.setup?.uvPackagesSizeGb ?? 0.7
    }

    var assumedDownloadSpeedMbps: Double {
        config?.setup?.assumedDownloadSpeedMbps ?? 20.0
    }

    /// Assumed download speed in bytes per second
    var assumedDownloadSpeedBps: Double {
        assumedDownloadSpeedMbps * 1_000_000
    }
}
