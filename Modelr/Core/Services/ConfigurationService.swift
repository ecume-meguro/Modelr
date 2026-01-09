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
            struct Hunyuan3D: Codable {
                let defaultSteps: Int
                let defaultResolution: Int
                let miniModelSizeGb: Double

                enum CodingKeys: String, CodingKey {
                    case defaultSteps = "default_steps"
                    case defaultResolution = "default_resolution"
                    case miniModelSizeGb = "mini_model_size_gb"
                }
            }
            let sam2: SAM2
            let hunyuan3d: Hunyuan3D
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
}
