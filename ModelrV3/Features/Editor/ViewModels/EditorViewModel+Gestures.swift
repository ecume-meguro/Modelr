import SwiftUI

// MARK: - Gesture Handlers Extension

extension EditorViewModel {
    // MARK: - Tap Handlers
    
    func handleTap(at normalized: CGPoint, isNegative: Bool) {
        guard currentStep == .segment, !skipSegmentation else { return }
        guard inputImage != nil, inputImagePath != nil else { return }
        
        if selectedTool == .polygon {
            handlePolygonTap(at: normalized)
            return
        }
        
        guard selectedTool == .point else { return }
        
        if isTransparentAt(normalized: normalized) {
            env.status = "Cannot place point on transparent area"
            return
        }
        
        let point = SAMPoint(normalizedCoords: normalized, label: isNegative ? 0 : 1)
        
        withAnimation(.spring(response: 0.3)) {
            selectedPoints.append(point)
            undoStack.append(.addPoint(point))
            redoStack.removeAll()
        }
        
        selectedPointId = nil
        selectedBoxId = nil
        selectedLassoId = nil
    }
    
    func handleRightClick(at normalized: CGPoint) {
        let threshold: CGFloat = 0.05
        
        if let nearest = selectedPoints.first(where: { point in
            let dx = point.normalizedCoords.x - normalized.x
            let dy = point.normalizedCoords.y - normalized.y
            return sqrt(dx*dx + dy*dy) < threshold
        }) {
            withAnimation {
                selectedPoints.removeAll { $0.id == nearest.id }
                undoStack.append(.addPoint(nearest))
                redoStack.removeAll()
            }
            triggerReInference()
            return
        }
        
        if let box = boundingBoxes.first(where: { box in
            let rect = box.normalizedRect
            return rect.contains(normalized)
        }) {
            withAnimation {
                boundingBoxes.removeAll { $0.id == box.id }
                undoStack.append(.addBox(box))
                redoStack.removeAll()
            }
            triggerReInference()
            return
        }
    }
    
    // MARK: - Drag Handlers (Box)
    
    func handleDragStart(at point: CGPoint) {
        guard inputImage != nil else { return }
        
        if currentStep == .refine && selectedPreprocessTool == .crop {
            cropRect = SAMBox(startPoint: point, endPoint: point)
        } else if currentStep == .segment && selectedTool == .boundingBox {
            currentBox = SAMBox(startPoint: point, endPoint: point)
        }
    }
    
    func handleDragChange(start: CGPoint, current: CGPoint) {
        if currentStep == .refine && selectedPreprocessTool == .crop {
            cropRect?.endPoint = current
        } else if currentStep == .segment && selectedTool == .boundingBox {
            currentBox?.endPoint = current
        }
    }
    
    func handleDragEnd(start: CGPoint, end: CGPoint) {
        if currentStep == .refine && selectedPreprocessTool == .crop {
            return
        }
        
        guard currentStep == .segment, selectedTool == .boundingBox else { return }
        guard let box = currentBox else { return }
        
        guard box.isValid else {
            currentBox = nil
            return
        }
        
        withAnimation(.spring(response: 0.3)) {
            boundingBoxes.append(box)
            undoStack.append(.addBox(box))
            currentBox = nil
        }
    }
    
    // MARK: - Lasso Handlers
    
    func handleLassoStart(at point: CGPoint) {
        guard inputImage != nil else { return }
        
        if currentStep == .refine && selectedPreprocessTool == .polygonCrop {
            preprocessLasso = LassoSelection(startPoint: point)
        } else if currentStep == .segment && selectedTool == .lasso {
            currentLasso = LassoSelection(startPoint: point)
        }
    }
    
    func handleLassoContinue(at point: CGPoint) {
        if currentStep == .refine && selectedPreprocessTool == .polygonCrop {
            if var lasso = preprocessLasso {
                lasso.addPoint(point)
                preprocessLasso = lasso
            }
        } else if currentStep == .segment && selectedTool == .lasso {
            if var lasso = currentLasso {
                lasso.addPoint(point)
                currentLasso = lasso
            }
        }
    }
    
    func handleLassoEnd() {
        if currentStep == .refine && selectedPreprocessTool == .polygonCrop {
            return
        }
        
        guard currentStep == .segment, selectedTool == .lasso else { return }
        guard let lasso = currentLasso else { return }
        
        // LassoSelection doesn't need explicit close - check validity directly
        guard lasso.isValid else {
            currentLasso = nil
            return
        }
        
        withAnimation(.spring(response: 0.3)) {
            lassoSelections.append(lasso)
            undoStack.append(.addLasso(lasso))
            redoStack.removeAll()
            currentLasso = nil
        }
    }
    
    // MARK: - Paint Handlers
    
    func handlePaintStart(at point: CGPoint) {
        guard currentStep == .segment, selectedTool == .paint else { return }
        guard inputImage != nil else { return }
        
        if isTransparentAt(normalized: point) {
            return
        }
        
        currentPaintStroke = PaintStroke(
            startPoint: point,
            brushSize: brushSize,
            isErasing: isErasing
        )
        
        updateLivePaintPreview(at: point)
    }
    
    func handlePaintContinue(at point: CGPoint) {
        guard currentStep == .segment, selectedTool == .paint else { return }
        guard var stroke = currentPaintStroke else { return }
        
        if isTransparentAt(normalized: point) {
            return
        }
        
        stroke.addPoint(point)
        currentPaintStroke = stroke
        
        updateLivePaintPreview(at: point)
    }
    
    func handlePaintEnd() {
        guard currentStep == .segment, selectedTool == .paint else { return }
        guard let stroke = currentPaintStroke else { return }
        
        // PaintStroke is valid if it has at least 2 points
        guard stroke.points.count >= 2 else {
            currentPaintStroke = nil
            clearLivePaintPreview()
            return
        }
        
        paintStrokes.append(stroke)
        undoStack.append(.addPaintStroke(stroke))
        redoStack.removeAll()
        currentPaintStroke = nil
        
        clearLivePaintPreview()
        applyPaintStrokesToMask()
    }
    
    private func updateLivePaintPreview(at point: CGPoint) {
        guard currentStep == .segment, selectedTool == .paint, var currentStroke = currentPaintStroke else {
            livePaintMask = nil
            return
        }
        
        currentStroke.addPoint(point)
        
        if let currentMask = maskImage {
            livePaintMask = applyStrokesToMask(currentMask, strokes: [currentStroke])
        }
    }
    
    private func clearLivePaintPreview() {
        livePaintMask = nil
    }
    
    private func applyPaintStrokesToMask() {
        guard let currentMask = maskImage, !paintStrokes.isEmpty else { return }
        maskImage = applyStrokesToMask(currentMask, strokes: paintStrokes)
        maskIsDirty = true
        flushMaskToDisk()
    }
    
    private func applyStrokesToMask(_ mask: NSImage, strokes: [PaintStroke]) -> NSImage {
        guard let tiffData = mask.tiffRepresentation else { return mask }
        guard let newBitmap = NSBitmapImageRep(data: tiffData) else { return mask }
        
        let imageSize = mask.size
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: newBitmap)
        let context = NSGraphicsContext.current?.cgContext
        
        for stroke in strokes {
            if stroke.isErasing {
                context?.setBlendMode(.clear)
            } else {
                context?.setBlendMode(.normal)
                context?.setFillColor(red: 50/255.0, green: 100/255.0, blue: 200/255.0, alpha: 1.0)
            }
            
            for point in stroke.points {
                let x = point.x * imageSize.width
                let y = point.y * imageSize.height
                let radius = stroke.brushSize * imageSize.width
                
                let rect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                
                context?.fillEllipse(in: rect)
            }
            
            if stroke.isErasing {
                context?.setBlendMode(.normal)
            }
        }
        
        NSGraphicsContext.restoreGraphicsState()
        
        let newImage = NSImage(size: imageSize)
        newImage.addRepresentation(newBitmap)
        
        return newImage
    }
    
    // MARK: - Polygon Handlers
    
    func handlePolygonTap(at point: CGPoint) {
        guard currentStep == .segment, selectedTool == .polygon else { return }
        
        if var polygon = currentPolygon {
            let threshold: CGFloat = 0.05
            if !polygon.vertices.isEmpty {
                let first = polygon.vertices[0]
                let dx = first.x - point.x
                let dy = first.y - point.y
                if sqrt(dx*dx + dy*dy) < threshold {
                    polygon.close()
                    polygonSelections.append(polygon)
                    undoStack.append(.addPolygon(polygon))
                    redoStack.removeAll()
                    currentPolygon = nil
                    return
                }
            }
            
            polygon.addVertex(point)
            currentPolygon = polygon
        } else {
            currentPolygon = PolygonSelection(vertices: [point])
        }
    }
    
    func cancelPolygon() {
        if currentPolygon != nil {
            currentPolygon = nil
        }
    }
}

// Additional UndoAction for polygon
extension UndoAction {
    static func addPolygon(_ polygon: PolygonSelection) -> UndoAction {
        // Convert polygon to lasso for undo stack
        var lasso = LassoSelection(startPoint: polygon.vertices.first ?? .zero)
        for vertex in polygon.vertices.dropFirst() {
            lasso.addPoint(vertex)
        }
        return .addLasso(lasso)
    }
}
