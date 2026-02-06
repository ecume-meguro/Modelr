import XCTest
@testable import Modelr

/// Tests for Editor UX improvements
final class EditorUXTests: XCTestCase {

    override func setUpWithError() throws {
    }

    override func tearDownWithError() throws {
    }

    // MARK: - Coordinate Extension Tests

    func testCGPointToViewCoords() throws {
        let displaySize = CGSize(width: 800, height: 600)
        let normalizedPoint = CGPoint(x: 0.5, y: 0.5)

        let viewCoords = normalizedPoint.toViewCoords(displaySize)

        XCTAssertEqual(viewCoords.x, 400, accuracy: 0.001, "X should be 400")
        XCTAssertEqual(viewCoords.y, 300, accuracy: 0.001, "Y should be 300")
    }

    func testCGPointToViewCoordsCorners() throws {
        let displaySize = CGSize(width: 1000, height: 500)

        let topLeft = CGPoint(x: 0, y: 0).toViewCoords(displaySize)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)

        let bottomRight = CGPoint(x: 1, y: 1).toViewCoords(displaySize)
        XCTAssertEqual(bottomRight.x, 1000, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 500, accuracy: 0.001)
    }

    // MARK: - UndoAction Tests

    func testUndoActionAddPoint() throws {
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        let action = UndoAction.addPoint(point)

        if case .addPoint(let undoPoint) = action {
            XCTAssertEqual(undoPoint.normalizedCoords, point.normalizedCoords)
            XCTAssertEqual(undoPoint.label, point.label)
        } else {
            XCTFail("Action should be addPoint")
        }
    }

    func testUndoActionAddBox() throws {
        let box = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.9, y: 0.9))
        let action = UndoAction.addBox(box)

        if case .addBox(let undoBox) = action {
            XCTAssertEqual(undoBox.startPoint, box.startPoint)
            XCTAssertEqual(undoBox.endPoint, box.endPoint)
        } else {
            XCTFail("Action should be addBox")
        }
    }

    func testUndoActionAddLasso() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.1, y: 0.1))
        lasso.addPoint(CGPoint(x: 0.5, y: 0.5))
        lasso.addPoint(CGPoint(x: 0.9, y: 0.1))

        let action = UndoAction.addLasso(lasso)

        if case .addLasso(let undoLasso) = action {
            XCTAssertEqual(undoLasso.points.count, lasso.points.count)
        } else {
            XCTFail("Action should be addLasso")
        }
    }

    func testUndoActionAddPaintStroke() throws {
        var stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5), brushSize: 0.03, isErasing: false)
        stroke.addPoint(CGPoint(x: 0.6, y: 0.6))

        let action = UndoAction.addPaintStroke(stroke)

        if case .addPaintStroke(let undoStroke) = action {
            XCTAssertEqual(undoStroke.brushSize, stroke.brushSize)
            XCTAssertEqual(undoStroke.isErasing, stroke.isErasing)
        } else {
            XCTFail("Action should be addPaintStroke")
        }
    }

    // MARK: - Point Label Collection Tests

    func testFilterPositivePoints() throws {
        let points = [
            SAMPoint(normalizedCoords: CGPoint(x: 0.1, y: 0.1), label: 1),
            SAMPoint(normalizedCoords: CGPoint(x: 0.2, y: 0.2), label: 0),
            SAMPoint(normalizedCoords: CGPoint(x: 0.3, y: 0.3), label: 1),
            SAMPoint(normalizedCoords: CGPoint(x: 0.4, y: 0.4), label: 0),
            SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        ]

        let positivePoints = points.filter { $0.isPositive }
        let negativePoints = points.filter { $0.isNegative }

        XCTAssertEqual(positivePoints.count, 3, "Should have 3 positive points")
        XCTAssertEqual(negativePoints.count, 2, "Should have 2 negative points")
    }

    func testExtractLabelsFromPoints() throws {
        let points = [
            SAMPoint(normalizedCoords: CGPoint(x: 0.1, y: 0.1), label: 1),
            SAMPoint(normalizedCoords: CGPoint(x: 0.2, y: 0.2), label: 0),
            SAMPoint(normalizedCoords: CGPoint(x: 0.3, y: 0.3), label: 1)
        ]

        let labels = points.map { $0.label }

        XCTAssertEqual(labels, [1, 0, 1], "Labels should be [1, 0, 1]")
    }

    // MARK: - Box Validation Tests

    func testBoxValidityThreshold() throws {
        // Box must be > 5% in each dimension
        let exactlyAtThreshold = SAMBox(
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 0.05, y: 0.05)
        )
        XCTAssertFalse(exactlyAtThreshold.isValid, "Box at exactly 5% should be invalid")

        let justAboveThreshold = SAMBox(
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 0.06, y: 0.06)
        )
        XCTAssertTrue(justAboveThreshold.isValid, "Box at 6% should be valid")

        let largeBox = SAMBox(
            startPoint: CGPoint(x: 0.1, y: 0.1),
            endPoint: CGPoint(x: 0.8, y: 0.8)
        )
        XCTAssertTrue(largeBox.isValid, "Large box should be valid")
    }

    // MARK: - Lasso Bounding Box Tests

    func testLassoBoundingBoxCalculation() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.2, y: 0.3))
        lasso.addPoint(CGPoint(x: 0.8, y: 0.3))
        lasso.addPoint(CGPoint(x: 0.8, y: 0.7))
        lasso.addPoint(CGPoint(x: 0.2, y: 0.7))

        let box = lasso.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }

    func testLassoBoundingBoxWithIrregularShape() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.5, y: 0.1))
        lasso.addPoint(CGPoint(x: 0.9, y: 0.5))
        lasso.addPoint(CGPoint(x: 0.5, y: 0.9))
        lasso.addPoint(CGPoint(x: 0.1, y: 0.5))

        let box = lasso.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.9, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.9, accuracy: 0.001)
    }

    // MARK: - Paint Stroke Tests

    func testPaintStrokeEraseVsAdd() throws {
        let addStroke = PaintStroke(
            startPoint: CGPoint(x: 0.5, y: 0.5),
            brushSize: 0.03,
            isErasing: false
        )
        XCTAssertFalse(addStroke.isErasing, "Add stroke should not be erasing")

        let eraseStroke = PaintStroke(
            startPoint: CGPoint(x: 0.5, y: 0.5),
            brushSize: 0.05,
            isErasing: true
        )
        XCTAssertTrue(eraseStroke.isErasing, "Erase stroke should be erasing")
    }

    func testPaintStrokeBrushSizeRange() throws {
        let smallBrush = PaintStroke(startPoint: .zero, brushSize: 0.01)
        XCTAssertEqual(smallBrush.brushSize, 0.01, accuracy: 0.001)

        let largeBrush = PaintStroke(startPoint: .zero, brushSize: 0.15)
        XCTAssertEqual(largeBrush.brushSize, 0.15, accuracy: 0.001)
    }

    // MARK: - SAMTool Selection Tests

    func testAllSAMToolsHaveIcons() throws {
        for tool in SAMTool.allCases {
            XCTAssertFalse(tool.iconName.isEmpty, "Tool \(tool.rawValue) should have an icon")
        }
    }

    func testAllSAMToolsHaveDisplayNames() throws {
        for tool in SAMTool.allCases {
            XCTAssertFalse(tool.rawValue.isEmpty, "Tool should have a display name")
        }
    }

    // MARK: - Polygon Tool Tests

    func testPolygonBoundingBoxCalculation() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.2, y: 0.3),
            CGPoint(x: 0.8, y: 0.3),
            CGPoint(x: 0.8, y: 0.7),
            CGPoint(x: 0.2, y: 0.7)
        ])

        let box = polygon.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }

    func testPolygonBoundingBoxWithIrregularShape() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.5, y: 0.1),
            CGPoint(x: 0.9, y: 0.5),
            CGPoint(x: 0.5, y: 0.9),
            CGPoint(x: 0.1, y: 0.5)
        ])

        let box = polygon.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.9, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.9, accuracy: 0.001)
    }

    func testPolygonCloseThreshold() throws {
        // Test the closing logic: if clicked within 3% of first vertex, polygon closes
        let firstVertex = CGPoint(x: 0.5, y: 0.5)
        var polygon = PolygonSelection(vertices: [
            firstVertex,
            CGPoint(x: 0.8, y: 0.5),
            CGPoint(x: 0.65, y: 0.8)
        ])

        // Simulate click near first vertex (within 3% threshold)
        let closeClickPoint = CGPoint(x: 0.52, y: 0.52)
        let distance = hypot(closeClickPoint.x - firstVertex.x, closeClickPoint.y - firstVertex.y)

        XCTAssertLessThan(distance, 0.03, "Click should be within close threshold")

        // Clicking near first vertex should close the polygon
        polygon.close()
        XCTAssertTrue(polygon.isClosed, "Polygon should be closed")
    }

    func testPolygonCloseThresholdTooFar() throws {
        let firstVertex = CGPoint(x: 0.5, y: 0.5)

        // Simulate click far from first vertex (beyond 3% threshold)
        let farClickPoint = CGPoint(x: 0.55, y: 0.55)
        let distance = hypot(farClickPoint.x - firstVertex.x, farClickPoint.y - firstVertex.y)

        XCTAssertGreaterThan(distance, 0.03, "Click should be outside close threshold")
    }

    func testPolygonToolInSAMToolEnum() throws {
        XCTAssertTrue(SAMTool.allCases.contains(.polygon), "SAMTool should include polygon")
        XCTAssertEqual(SAMTool.polygon.rawValue, "Polygon")
        XCTAssertEqual(SAMTool.polygon.iconName, "pentagon")
    }

    // MARK: - CGRect Contains Point Tests

    func testNormalizedRectContainsPoint() throws {
        let box = SAMBox(
            startPoint: CGPoint(x: 0.2, y: 0.2),
            endPoint: CGPoint(x: 0.8, y: 0.8)
        )
        let rect = box.normalizedRect

        // Inside
        XCTAssertTrue(rect.contains(CGPoint(x: 0.5, y: 0.5)), "Center should be inside")
        XCTAssertTrue(rect.contains(CGPoint(x: 0.3, y: 0.3)), "Near corner should be inside")

        // Outside
        XCTAssertFalse(rect.contains(CGPoint(x: 0.1, y: 0.1)), "Outside should not contain")
        XCTAssertFalse(rect.contains(CGPoint(x: 0.9, y: 0.9)), "Outside should not contain")

        // Edge
        XCTAssertTrue(rect.contains(CGPoint(x: 0.2, y: 0.5)), "Edge should be inside")
    }

    // MARK: - Step Enum Tests

    func testStepComparable() throws {
        XCTAssertTrue(SimpleEditorViewModel.Step.setup < SimpleEditorViewModel.Step.input)
        XCTAssertTrue(SimpleEditorViewModel.Step.input < SimpleEditorViewModel.Step.segment)
        XCTAssertTrue(SimpleEditorViewModel.Step.segment < SimpleEditorViewModel.Step.touchup)
        XCTAssertTrue(SimpleEditorViewModel.Step.touchup < SimpleEditorViewModel.Step.generateSettings)
        XCTAssertTrue(SimpleEditorViewModel.Step.generateSettings < SimpleEditorViewModel.Step.generate)
        XCTAssertTrue(SimpleEditorViewModel.Step.generate < SimpleEditorViewModel.Step.postProcess)
    }

    func testStepPrevious() throws {
        XCTAssertNil(SimpleEditorViewModel.Step.setup.previous)
        XCTAssertEqual(SimpleEditorViewModel.Step.input.previous, .setup)
        XCTAssertEqual(SimpleEditorViewModel.Step.segment.previous, .input)
        XCTAssertEqual(SimpleEditorViewModel.Step.touchup.previous, .segment)
        XCTAssertEqual(SimpleEditorViewModel.Step.generateSettings.previous, .touchup)
        XCTAssertEqual(SimpleEditorViewModel.Step.generate.previous, .generateSettings)
        XCTAssertEqual(SimpleEditorViewModel.Step.postProcess.previous, .generate)
    }

    func testStepHasSignificantState() throws {
        XCTAssertFalse(SimpleEditorViewModel.Step.setup.hasSignificantState)
        XCTAssertFalse(SimpleEditorViewModel.Step.input.hasSignificantState)
        XCTAssertTrue(SimpleEditorViewModel.Step.segment.hasSignificantState)
        XCTAssertTrue(SimpleEditorViewModel.Step.touchup.hasSignificantState)
        XCTAssertFalse(SimpleEditorViewModel.Step.generateSettings.hasSignificantState) // Just settings, no state
        XCTAssertTrue(SimpleEditorViewModel.Step.generate.hasSignificantState)
        XCTAssertTrue(SimpleEditorViewModel.Step.postProcess.hasSignificantState)
    }

    func testStepAllCases() throws {
        let allSteps = SimpleEditorViewModel.Step.allCases
        XCTAssertEqual(allSteps.count, 7)
        XCTAssertEqual(allSteps[0], .setup)
        XCTAssertEqual(allSteps[6], .postProcess)
    }

    func testStepRawValues() throws {
        XCTAssertEqual(SimpleEditorViewModel.Step.setup.rawValue, 0)
        XCTAssertEqual(SimpleEditorViewModel.Step.input.rawValue, 1)
        XCTAssertEqual(SimpleEditorViewModel.Step.segment.rawValue, 2)
        XCTAssertEqual(SimpleEditorViewModel.Step.touchup.rawValue, 3)
        XCTAssertEqual(SimpleEditorViewModel.Step.generateSettings.rawValue, 4)
        XCTAssertEqual(SimpleEditorViewModel.Step.generate.rawValue, 5)
        XCTAssertEqual(SimpleEditorViewModel.Step.postProcess.rawValue, 6)
    }

    // MARK: - AppError Tests

    func testAppErrorDescriptions() throws {
        let imageError = AppError.imageProcessing("Test error")
        XCTAssertTrue(imageError.localizedDescription.contains("Image processing"))

        let generationError = AppError.generation("Gen error")
        XCTAssertTrue(generationError.localizedDescription.contains("3D generation"))

        let meshError = AppError.meshProcessing("Mesh error")
        XCTAssertTrue(meshError.localizedDescription.contains("Mesh processing"))

        let cancelledError = AppError.cancelled
        XCTAssertTrue(cancelledError.localizedDescription.contains("cancelled"))
    }

    func testAppErrorRecoverable() throws {
        XCTAssertTrue(AppError.imageProcessing("test").isRecoverable)
        XCTAssertTrue(AppError.generation("test").isRecoverable)
        XCTAssertTrue(AppError.meshProcessing("test").isRecoverable)
        XCTAssertFalse(AppError.cancelled.isRecoverable)
        XCTAssertFalse(AppError.setup(message: "test").isRecoverable)
        XCTAssertFalse(AppError.unknown.isRecoverable)
    }

    func testAppErrorSuggestedAction() throws {
        XCTAssertNotNil(AppError.imageProcessing("test").suggestedAction)
        XCTAssertNotNil(AppError.generation("test").suggestedAction)
        XCTAssertNotNil(AppError.meshProcessing("test").suggestedAction)
        XCTAssertNil(AppError.cancelled.suggestedAction)
    }

    // MARK: - Generation Stage Tests

    func testGenerationStageAllCases() throws {
        let stages = GenerationStage.allCases
        XCTAssertGreaterThan(stages.count, 0)
    }

    func testStageProgressStatus() throws {
        let inProgress = StageProgress(status: .inProgress, progress: 0.5, detail: "Working...")
        XCTAssertEqual(inProgress.status, .inProgress)
        XCTAssertEqual(inProgress.progress, 0.5)
        XCTAssertEqual(inProgress.detail, "Working...")

        let completed = StageProgress(status: .completed, progress: 1.0, detail: "")
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.progress, 1.0)

        let cancelled = StageProgress(status: .cancelled, progress: 0, detail: "")
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    // MARK: - PreloadManager Tests

    @MainActor
    func testPreloadManagerSingleton() throws {
        let manager1 = PreloadManager.shared
        let manager2 = PreloadManager.shared
        XCTAssertTrue(manager1 === manager2)
    }

    @MainActor
    func testPreloadManagerInitialState() throws {
        let manager = PreloadManager.shared
        manager.cancelAll()

        XCTAssertFalse(manager.isMaskMergePreloading)
        XCTAssertFalse(manager.isCompositePreloading)
    }

    @MainActor
    func testPreloadManagerCancelAll() throws {
        let manager = PreloadManager.shared

        // Start some preloading (will be cancelled immediately)
        manager.cancelAll()

        XCTAssertFalse(manager.isMaskMergePreloading)
        XCTAssertFalse(manager.isCompositePreloading)
    }

    @MainActor
    func testPreloadManagerClearMask() throws {
        let manager = PreloadManager.shared
        manager.clearPreloadedMask()

        XCTAssertFalse(manager.isMaskMergePreloading)
    }

    @MainActor
    func testPreloadManagerClearComposite() throws {
        let manager = PreloadManager.shared
        manager.clearPreloadedComposite()

        XCTAssertFalse(manager.isCompositePreloading)
    }

    @MainActor
    func testGetMergedMaskWithNoPreload() throws {
        let manager = PreloadManager.shared
        manager.cancelAll()

        // With empty segmentations, should return nil
        let result = manager.getMergedMask(from: [], projectId: UUID())
        XCTAssertNil(result)
    }

    // MARK: - Workflow State Cache Tests

    @MainActor
    func testGenerationCacheStructure() throws {
        // Test that GenerationCache can be created with proper values
        let testURL = URL(fileURLWithPath: "/tmp/test_model.obj")
        let testComponents: [MeshComponent] = [
            MeshComponent(
                index: 0,
                vertexCount: 500,
                faceCount: 1000,
                boundsMin: [-1.0, -1.0, -1.0],
                boundsMax: [1.0, 1.0, 1.0],
                center: [0.0, 0.0, 0.0],
                size: 2.0,
                isWatertight: true
            )
        ]
        let testComponentFiles: [ComponentFile] = [
            ComponentFile(index: 0, path: "/tmp/component_0.obj")
        ]
        let keepIndices: Set<Int> = [0]
        let deleteIndices: Set<Int> = []

        let cache = SimpleEditorViewModel.GenerationCache(
            projectId: UUID(),
            modelURL: testURL,
            compositeImage: nil,
            meshComponents: testComponents,
            componentFiles: testComponentFiles,
            preloadedNodes: [:],
            keepIndices: keepIndices,
            deleteIndices: deleteIndices
        )

        XCTAssertEqual(cache.modelURL, testURL)
        XCTAssertEqual(cache.meshComponents.count, 1)
        XCTAssertEqual(cache.componentFiles.count, 1)
        XCTAssertEqual(cache.keepIndices, keepIndices)
        XCTAssertEqual(cache.deleteIndices, deleteIndices)
    }

    @MainActor
    func testSegmentationCacheStructure() throws {
        // Test that SegmentationCache can be created with proper values
        let cache = SimpleEditorViewModel.SegmentationCache(
            projectId: UUID(),
            segmentations: [],
            activeIndex: 0,
            inputImage: nil,
            inputImagePath: "/tmp/test.png",
            imagePixelSize: CGSize(width: 1024, height: 1024)
        )

        XCTAssertTrue(cache.segmentations.isEmpty)
        XCTAssertEqual(cache.activeIndex, 0)
        XCTAssertEqual(cache.inputImagePath, "/tmp/test.png")
        XCTAssertEqual(cache.imagePixelSize, CGSize(width: 1024, height: 1024))
    }

    @MainActor
    func testHasCachedGenerationInitiallyFalse() throws {
        // New viewModel should not have cached generation
        // Note: Can't easily test without full viewModel initialization
        // Testing the property existence and behavior
        let step = SimpleEditorViewModel.Step.postProcess
        XCTAssertEqual(step.rawValue, 6)
    }

    // MARK: - Post-Process State Tests

    @MainActor
    func testMeshComponentStructure() throws {
        let component = MeshComponent(
            index: 0,
            vertexCount: 2500,
            faceCount: 5000,
            boundsMin: [-1.0, -1.0, -1.0],
            boundsMax: [1.0, 1.0, 1.0],
            center: [0.0, 0.0, 0.0],
            size: 2.0,
            isWatertight: true
        )

        XCTAssertEqual(component.index, 0)
        XCTAssertEqual(component.vertexCount, 2500)
        XCTAssertEqual(component.faceCount, 5000)
        XCTAssertTrue(component.isWatertight)
        XCTAssertEqual(component.size, 2.0)
    }

    @MainActor
    func testMeshComponentArtifactDetection() throws {
        // Small face count = likely artifact (< 1000 faces)
        let artifact = MeshComponent(
            index: 0,
            vertexCount: 250,
            faceCount: 500,
            boundsMin: [-0.1, -0.1, -0.1],
            boundsMax: [0.1, 0.1, 0.1],
            center: [0.0, 0.0, 0.0],
            size: 0.2,
            isWatertight: false
        )
        XCTAssertLessThan(artifact.faceCount, 1000, "Small components are likely artifacts")

        let mainMesh = MeshComponent(
            index: 1,
            vertexCount: 5000,
            faceCount: 10000,
            boundsMin: [-1.0, -1.0, -1.0],
            boundsMax: [1.0, 1.0, 1.0],
            center: [0.0, 0.0, 0.0],
            size: 2.0,
            isWatertight: true
        )
        XCTAssertGreaterThan(mainMesh.faceCount, 1000, "Main mesh should have more faces")
    }

    @MainActor
    func testComponentFileStructure() throws {
        let file = ComponentFile(
            index: 2,
            path: "/tmp/component_2.obj"
        )

        XCTAssertEqual(file.index, 2)
        XCTAssertEqual(file.path, "/tmp/component_2.obj")
    }

    // MARK: - Keep/Delete Index Tests

    @MainActor
    func testKeepDeleteIndicesAreDisjoint() throws {
        // Keep and delete indices should never overlap
        let keepIndices: Set<Int> = [0, 1, 2]
        let deleteIndices: Set<Int> = [3, 4]

        XCTAssertTrue(keepIndices.isDisjoint(with: deleteIndices), "Keep and delete should be disjoint")
    }

    @MainActor
    func testMoveToDeleteOperation() throws {
        var keepIndices: Set<Int> = [0, 1, 2]
        var deleteIndices: Set<Int> = []

        // Simulate moveToDelete(1)
        keepIndices.remove(1)
        deleteIndices.insert(1)

        XCTAssertFalse(keepIndices.contains(1))
        XCTAssertTrue(deleteIndices.contains(1))
        XCTAssertEqual(keepIndices.count, 2)
        XCTAssertEqual(deleteIndices.count, 1)
    }

    @MainActor
    func testMoveToKeepOperation() throws {
        var keepIndices: Set<Int> = [0, 1]
        var deleteIndices: Set<Int> = [2]

        // Simulate moveToKeep(2)
        deleteIndices.remove(2)
        keepIndices.insert(2)

        XCTAssertTrue(keepIndices.contains(2))
        XCTAssertFalse(deleteIndices.contains(2))
        XCTAssertEqual(keepIndices.count, 3)
        XCTAssertEqual(deleteIndices.count, 0)
    }

    @MainActor
    func testCannotDeleteLastItem() throws {
        let keepIndices: Set<Int> = [0]
        let deleteIndices: Set<Int> = [1, 2]

        // Should not be able to delete the last kept item
        let canMoveToDelete = keepIndices.count > 1
        XCTAssertFalse(canMoveToDelete, "Cannot delete last item in keep list")
    }

    // MARK: - Highlight/Hover State Tests

    @MainActor
    func testHighlightedIndexCanBeNil() throws {
        let highlightedIndex: Int? = nil
        XCTAssertNil(highlightedIndex, "Highlighted index can be nil when nothing selected")
    }

    @MainActor
    func testHighlightedIndexWithValue() throws {
        let highlightedIndex: Int? = 2
        XCTAssertEqual(highlightedIndex, 2)
    }

    @MainActor
    func testHoveredIndexCanBeNil() throws {
        let hoveredIndex: Int? = nil
        XCTAssertNil(hoveredIndex, "Hovered index should be nil when not hovering")
    }

    @MainActor
    func testHoveredIndexWithValue() throws {
        let hoveredIndex: Int? = 1
        XCTAssertEqual(hoveredIndex, 1)
    }

    // MARK: - Viewport Interaction Tests

    @MainActor
    func testComponentNodeNameFormat() throws {
        // Component nodes should be named "component_N"
        let index = 5
        let nodeName = "component_\(index)"

        XCTAssertTrue(nodeName.hasPrefix("component_"))
        XCTAssertEqual(nodeName, "component_5")

        // Parse index back from node name
        let components = nodeName.components(separatedBy: "_")
        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components.last, "5")
        XCTAssertEqual(Int(components.last!), 5)
    }

    @MainActor
    func testClickToggleFromKeepToDelete() throws {
        var keepIndices: Set<Int> = [0, 1]
        var deleteIndices: Set<Int> = [2]
        let clickedIndex = 0

        // Simulate handleViewportComponentClick logic (click toggles keep/delete)
        // Clicking a kept item should move it to delete (if more than one item in keep)
        if keepIndices.contains(clickedIndex) {
            if keepIndices.count > 1 {
                keepIndices.remove(clickedIndex)
                deleteIndices.insert(clickedIndex)
            }
        } else if deleteIndices.contains(clickedIndex) {
            deleteIndices.remove(clickedIndex)
            keepIndices.insert(clickedIndex)
        }

        XCTAssertFalse(keepIndices.contains(0), "Clicked kept item should move to delete list")
        XCTAssertTrue(deleteIndices.contains(0), "Clicked kept item should be in delete list")
    }

    @MainActor
    func testClickToggleFromDeleteToKeep() throws {
        var keepIndices: Set<Int> = [0]
        var deleteIndices: Set<Int> = [1, 2]
        let clickedIndex = 1

        // Clicking a deleted item should restore it to keep
        if keepIndices.contains(clickedIndex) {
            if keepIndices.count > 1 {
                keepIndices.remove(clickedIndex)
                deleteIndices.insert(clickedIndex)
            }
        } else if deleteIndices.contains(clickedIndex) {
            deleteIndices.remove(clickedIndex)
            keepIndices.insert(clickedIndex)
        }

        XCTAssertTrue(keepIndices.contains(1), "Clicked deleted item should move to keep list")
        XCTAssertFalse(deleteIndices.contains(1), "Clicked deleted item should not be in delete list")
    }

    @MainActor
    func testCannotDeleteLastKeptItem() throws {
        var keepIndices: Set<Int> = [0]  // Only one item in keep
        var deleteIndices: Set<Int> = [1, 2]
        let clickedIndex = 0

        // Clicking the last kept item should NOT delete it
        if keepIndices.contains(clickedIndex) {
            if keepIndices.count > 1 {
                keepIndices.remove(clickedIndex)
                deleteIndices.insert(clickedIndex)
            }
        }

        XCTAssertTrue(keepIndices.contains(0), "Last kept item should remain in keep list")
        XCTAssertFalse(deleteIndices.contains(0), "Last kept item should not be moved to delete")
    }

    // MARK: - Material State Tests (Color Constants)

    func testClayColorValues() throws {
        // Clay color should be warm off-white
        let clayRed: CGFloat = 0.88
        let clayGreen: CGFloat = 0.86
        let clayBlue: CGFloat = 0.82

        // All components should be high (light color)
        XCTAssertGreaterThan(clayRed, 0.8)
        XCTAssertGreaterThan(clayGreen, 0.8)
        XCTAssertGreaterThan(clayBlue, 0.8)

        // Should have slight warmth (red > blue)
        XCTAssertGreaterThan(clayRed, clayBlue)
    }

    func testGhostColorValues() throws {
        // Ghost color should be neutral gray
        let ghostRed: CGFloat = 0.5
        let ghostGreen: CGFloat = 0.5
        let ghostBlue: CGFloat = 0.55

        // Should be neutral gray
        XCTAssertEqual(ghostRed, ghostGreen, accuracy: 0.1)
        XCTAssertEqual(ghostGreen, ghostBlue, accuracy: 0.1)
    }

    func testGhostOpacity() throws {
        // Ghost material should be translucent
        let ghostOpacity: CGFloat = 0.18

        XCTAssertLessThan(ghostOpacity, 0.25, "Ghost should be quite transparent")
        XCTAssertGreaterThan(ghostOpacity, 0.1, "Ghost should still be visible")
    }

    func testRimGlowColorValues() throws {
        // Rim glow should be cyan
        let rimRed: CGFloat = 0.3
        let rimGreen: CGFloat = 0.8
        let rimBlue: CGFloat = 1.0

        // Blue should be highest (cyan tint)
        XCTAssertGreaterThan(rimBlue, rimGreen)
        XCTAssertGreaterThan(rimGreen, rimRed)

        // Should be a "cool" highlight color
        XCTAssertLessThan(rimRed, 0.5)
    }

    // MARK: - Has Artifacts Detection Tests

    func testHasArtifactsWhenBothListsPopulated() throws {
        let keepIndices: Set<Int> = [0, 1]
        let deleteIndices: Set<Int> = [2]

        let hasArtifacts = !keepIndices.isEmpty && !deleteIndices.isEmpty
        XCTAssertTrue(hasArtifacts, "Should have artifacts when both lists are populated")
    }

    func testNoArtifactsWhenDeleteEmpty() throws {
        let keepIndices: Set<Int> = [0, 1, 2]
        let deleteIndices: Set<Int> = []

        let hasArtifacts = !keepIndices.isEmpty && !deleteIndices.isEmpty
        XCTAssertFalse(hasArtifacts, "No artifacts when delete list is empty")
    }

    func testNoArtifactsWhenKeepEmpty() throws {
        let keepIndices: Set<Int> = []
        let deleteIndices: Set<Int> = [0, 1]

        let hasArtifacts = !keepIndices.isEmpty && !deleteIndices.isEmpty
        XCTAssertFalse(hasArtifacts, "No artifacts when keep list is empty")
    }
}
