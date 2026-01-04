import Foundation

/// Represents a component file from mesh analysis
struct ComponentFile: Identifiable {
    let id = UUID()
    let index: Int
    let path: String
}

/// Represents a mesh component with geometry information
struct MeshComponent: Identifiable {
    let id = UUID()
    let index: Int
    let vertexCount: Int
    let faceCount: Int
    let boundsMin: [Double]
    let boundsMax: [Double]
    let center: [Double]
    let size: Double
    let isWatertight: Bool

    var sizeDescription: String {
        if size < 0.01 { return "Tiny" }
        if size < 0.1 { return "Small" }
        if size < 0.5 { return "Medium" }
        return "Large"
    }
}

/// Supported export formats for 3D meshes
enum ExportFormat: String, CaseIterable, Identifiable {
    case obj = "OBJ"
    case glb = "GLB"
    case stl = "STL"
    case ply = "PLY"

    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}
