import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

// Note: ComponentFile is defined in MeshModels.swift

/// Coordinator for ComponentModelViewer - handles interaction and material management
final class ComponentViewerCoordinator: NSObject {
    private var componentNodes: [Int: SCNNode] = [:]

    // MARK: - Interaction Handling
    weak var scnView: SCNView?
    var onComponentClicked: ((Int) -> Void)?
    var onComponentRightClicked: ((Int) -> Void)?
    var onEmptySpaceClicked: (() -> Void)?
    var onComponentHovered: ((Int?) -> Void)?
    private var clickGestureRecognizer: NSClickGestureRecognizer?
    private var rightClickGestureRecognizer: NSClickGestureRecognizer?
    private var lastHoveredIndex: Int?

    // MARK: - Scroll State
    private var mouseMovedMonitor: Any?
    private var scrollStateObserver: Any?
    private var isScrolling = false
    private var scrollEndTimer: Timer?

    // MARK: - Setup

    func setupInteraction(for scnView: SCNView) {
        // Add left-click gesture recognizer (keep)
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        scnView.addGestureRecognizer(clickRecognizer)
        self.clickGestureRecognizer = clickRecognizer

        // Add right-click gesture recognizer (delete)
        let rightClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClickRecognizer.buttonMask = 0x2  // Right mouse button
        scnView.addGestureRecognizer(rightClickRecognizer)
        self.rightClickGestureRecognizer = rightClickRecognizer

        // Set up mouse moved monitor for hover detection
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }

        // Track scroll wheel events directly to skip expensive hit testing during scroll
        scrollStateObserver = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if event.deltaY != 0 || event.deltaX != 0 {
                self?.handleScrollEvent()
            }
            return event
        }
    }

    private func handleScrollEvent() {
        if !isScrolling {
            isScrolling = true
            // Clear hover during scroll
            if lastHoveredIndex != nil {
                lastHoveredIndex = nil
                onComponentHovered?(nil)
            }
        }
        // Reset end timer
        scrollEndTimer?.invalidate()
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.isScrolling = false
        }
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let scnView = scnView else { return }
        let location = gesture.location(in: scnView)

        if let componentIndex = hitTestForComponentIndex(at: location, in: scnView) {
            onComponentClicked?(componentIndex)
        } else {
            onEmptySpaceClicked?()
        }
    }

    @objc private func handleRightClick(_ gesture: NSClickGestureRecognizer) {
        guard let scnView = scnView else { return }
        let location = gesture.location(in: scnView)

        if let componentIndex = hitTestForComponentIndex(at: location, in: scnView) {
            onComponentRightClicked?(componentIndex)
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard !isScrolling else { return }

        guard let scnView = scnView,
              let window = scnView.window,
              event.window == window else {
            return
        }

        let locationInWindow = event.locationInWindow
        let location = scnView.convert(locationInWindow, from: nil)

        guard scnView.bounds.contains(location) else {
            if lastHoveredIndex != nil {
                lastHoveredIndex = nil
                onComponentHovered?(nil)
            }
            return
        }

        let componentIndex = hitTestForComponentIndex(at: location, in: scnView)
        if componentIndex != lastHoveredIndex {
            lastHoveredIndex = componentIndex
            onComponentHovered?(componentIndex)
        }
    }

    private func hitTestForComponentIndex(at location: CGPoint, in scnView: SCNView) -> Int? {
        let hitResults = scnView.hitTest(location, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true
        ])

        for hit in hitResults {
            var node: SCNNode? = hit.node
            while let currentNode = node {
                if let nodeName = currentNode.name,
                   nodeName.hasPrefix("component_"),
                   let indexStr = nodeName.components(separatedBy: "_").last,
                   let index = Int(indexStr) {
                    return index
                }
                node = currentNode.parent
            }
        }
        return nil
    }

    deinit {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = scrollStateObserver {
            NSEvent.removeMonitor(observer)
        }
        scrollEndTimer?.invalidate()
    }

    // MARK: - Component Loading

    func loadComponents(
        _ files: [ComponentFile],
        keepIndices: Set<Int>,
        deleteIndices: Set<Int>,
        hoveredIndex: Int?,
        isolatedIndex: Int?,
        displayMode: MeshDisplayMode,
        preloadedNodes: [Int: SCNNode],
        hasArtifacts: Bool,
        customColor: NSColor?,
        into scene: SCNScene,
        view: SCNView
    ) {
        // Remove existing components
        scene.rootNode.childNode(withName: "componentsContainer", recursively: true)?.removeFromParentNode()
        componentNodes.removeAll()

        let containerNode = SCNNode()
        containerNode.name = "componentsContainer"

        let hasPreloadedNodes = !preloadedNodes.isEmpty

        if hasPreloadedNodes {
            // Use pre-loaded nodes for instant rendering
            for file in files {
                guard let preloadedNode = preloadedNodes[file.index] else { continue }

                let componentNode = preloadedNode.clone()
                componentNode.name = "component_\(file.index)"

                if hoveredIndex == file.index {
                    ComponentMaterials.applyMaterial(
                        to: componentNode,
                        index: file.index,
                        keepIndices: keepIndices,
                        deleteIndices: deleteIndices,
                        hoveredIndex: hoveredIndex,
                        isolatedIndex: isolatedIndex,
                        displayMode: displayMode,
                        hasArtifacts: hasArtifacts,
                        customColor: customColor
                    )
                }

                if let isolated = isolatedIndex {
                    componentNode.isHidden = file.index != isolated
                }

                containerNode.addChildNode(componentNode)
                componentNodes[file.index] = componentNode
            }

            scene.rootNode.addChildNode(containerNode)
            centerAndScaleContainer(containerNode)
        } else {
            // Fall back to loading from disk (background thread)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                var allNodes: [(Int, SCNNode)] = []

                for file in files {
                    let url = URL(fileURLWithPath: file.path)
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }

                    let asset = MDLAsset(url: url)
                    asset.loadTextures()

                    guard asset.count > 0 else { continue }

                    let loadedScene = SCNScene(mdlAsset: asset)

                    let componentNode = SCNNode()
                    componentNode.name = "component_\(file.index)"

                    for child in loadedScene.rootNode.childNodes {
                        let cloned = child.clone()
                        ComponentMaterials.applyMaterial(
                            to: cloned,
                            index: file.index,
                            keepIndices: keepIndices,
                            deleteIndices: deleteIndices,
                            hoveredIndex: hoveredIndex,
                            isolatedIndex: isolatedIndex,
                            displayMode: displayMode,
                            hasArtifacts: hasArtifacts,
                            customColor: customColor
                        )
                        componentNode.addChildNode(cloned)
                    }

                    if let isolated = isolatedIndex {
                        componentNode.isHidden = file.index != isolated
                    }

                    allNodes.append((file.index, componentNode))
                }

                DispatchQueue.main.async {
                    for (index, node) in allNodes {
                        containerNode.addChildNode(node)
                        self.componentNodes[index] = node
                    }

                    scene.rootNode.addChildNode(containerNode)
                    self.centerAndScaleContainer(containerNode)
                }
            }
        }
    }

    private func centerAndScaleContainer(_ containerNode: SCNNode) {
        let (min, max) = containerNode.boundingBox
        let size = SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z)
        let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))

        if maxDim > 0 {
            let scale = 1.5 / maxDim
            containerNode.scale = SCNVector3(scale, scale, scale)

            let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
            containerNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
            containerNode.position = SCNVector3(0, 0, 0)
        }
    }

    // MARK: - Appearance Updates

    func updateAppearance(
        keepIndices: Set<Int>,
        deleteIndices: Set<Int>,
        hoveredIndex: Int?,
        isolatedIndex: Int?,
        displayMode: MeshDisplayMode,
        hasArtifacts: Bool,
        customColor: NSColor?,
        in scene: SCNScene
    ) {
        for (index, node) in componentNodes {
            if let isolated = isolatedIndex {
                node.isHidden = index != isolated
            } else {
                node.isHidden = false
            }

            ComponentMaterials.updateMaterial(
                for: node,
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
}
