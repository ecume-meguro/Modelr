import SceneKit

/// Material management for ComponentModelViewer - handles clay shader and artifact highlighting
enum ComponentMaterials {
    // MARK: - Material State
    enum MaterialState {
        case keep           // Kept items (clean clay)
        case keepHover      // Hovered kept items (clay with subtle glow)
        case delete         // Deleted items (clay with red rim light)
        case deleteHover    // Hovered deleted items (clay with brighter red rim)
    }

    // MARK: - Colors
    private static let clayColor = NSColor(red: 0.82, green: 0.80, blue: 0.76, alpha: 1.0)
    private static let clayHoverColor = NSColor(red: 0.88, green: 0.86, blue: 0.82, alpha: 1.0)
    private static let deleteRimColor = NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
    private static let deleteRimHoverColor = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
    private static let keepHoverGlow = NSColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0)

    private static let materialRoughness: CGFloat = 0.75
    private static let materialMetalness: CGFloat = 0.0

    // MARK: - Public API

    static func applyMaterial(
        to node: SCNNode,
        index: Int,
        keepIndices: Set<Int>,
        deleteIndices: Set<Int>,
        hoveredIndex: Int?,
        isolatedIndex: Int?,
        displayMode: MeshDisplayMode,
        hasArtifacts: Bool,
        customColor: NSColor?
    ) {
        let state = materialState(
            for: index,
            keepIndices: keepIndices,
            deleteIndices: deleteIndices,
            hoveredIndex: hoveredIndex,
            hasArtifacts: hasArtifacts
        )

        node.geometry?.materials.forEach { material in
            configure(material, state: state, displayMode: displayMode, customColor: customColor)
        }

        for child in node.childNodes {
            applyMaterial(
                to: child,
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                hoveredIndex: hoveredIndex,
                isolatedIndex: isolatedIndex,
                displayMode: displayMode,
                hasArtifacts: hasArtifacts,
                customColor: customColor
            )
        }
    }

    static func updateMaterial(
        for node: SCNNode,
        index: Int,
        keepIndices: Set<Int>,
        deleteIndices: Set<Int>,
        hoveredIndex: Int?,
        isolatedIndex: Int?,
        displayMode: MeshDisplayMode,
        hasArtifacts: Bool,
        customColor: NSColor?
    ) {
        let state = materialState(
            for: index,
            keepIndices: keepIndices,
            deleteIndices: deleteIndices,
            hoveredIndex: hoveredIndex,
            hasArtifacts: hasArtifacts
        )

        node.geometry?.materials.forEach { material in
            configure(material, state: state, displayMode: displayMode, customColor: customColor)
        }

        for child in node.childNodes {
            updateMaterial(
                for: child,
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                hoveredIndex: hoveredIndex,
                isolatedIndex: isolatedIndex,
                displayMode: displayMode,
                hasArtifacts: hasArtifacts,
                customColor: customColor
            )
        }
    }

    // MARK: - Private Helpers

    private static func materialState(
        for index: Int,
        keepIndices: Set<Int>,
        deleteIndices: Set<Int>,
        hoveredIndex: Int?,
        hasArtifacts: Bool
    ) -> MaterialState {
        let isHovered = hoveredIndex == index
        let isDeleted = hasArtifacts && deleteIndices.contains(index)

        if isDeleted {
            return isHovered ? .deleteHover : .delete
        } else {
            return isHovered ? .keepHover : .keep
        }
    }

    private static func configure(
        _ material: SCNMaterial,
        state: MaterialState,
        displayMode: MeshDisplayMode,
        customColor: NSColor?
    ) {
        material.isDoubleSided = true

        switch displayMode {
        case .solid:
            material.fillMode = .fill
            material.lightingModel = .physicallyBased
        case .wireframe:
            material.fillMode = .lines
            material.lightingModel = .constant
        }

        material.metalness.contents = materialMetalness
        material.roughness.contents = materialRoughness
        material.transparency = 1.0
        material.transparencyMode = .default
        material.blendMode = .replace
        material.writesToDepthBuffer = true

        switch state {
        case .keep:
            material.diffuse.contents = customColor ?? clayColor
            material.emission.contents = NSColor.black
            material.emission.intensity = 0.0
            material.fresnelExponent = 0.0

        case .keepHover:
            material.diffuse.contents = customColor ?? clayHoverColor
            material.emission.contents = keepHoverGlow
            material.emission.intensity = 0.2
            material.fresnelExponent = 2.0

        case .delete:
            material.diffuse.contents = customColor ?? clayColor
            material.emission.contents = deleteRimColor
            material.emission.intensity = 0.6
            material.fresnelExponent = 4.0
            material.transparency = 0.85

        case .deleteHover:
            material.diffuse.contents = customColor ?? clayHoverColor
            material.emission.contents = deleteRimHoverColor
            material.emission.intensity = 0.8
            material.fresnelExponent = 3.5
            material.transparency = 0.9
        }
    }
}
