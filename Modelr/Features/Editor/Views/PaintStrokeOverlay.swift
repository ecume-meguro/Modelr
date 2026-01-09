import SwiftUI

/// Overlay that renders paint strokes for mask editing
struct PaintStrokeOverlay: View {
    let strokes: [PaintStroke]
    let currentStroke: PaintStroke?
    let displayedSize: CGSize

    var body: some View {
        Canvas { context, size in
            // Draw completed strokes
            for stroke in strokes {
                drawStroke(stroke, in: &context, size: size)
            }

            // Draw current stroke being drawn
            if let current = currentStroke {
                drawStroke(current, in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    // SAM2 mask color: RGB(50, 100, 200) - blue-ish purple
    private static let maskColor = Color(red: 50/255, green: 100/255, blue: 200/255)
    private static let eraseColor = Color.red

    private func drawStroke(_ stroke: PaintStroke, in context: inout GraphicsContext, size: CGSize) {
        guard stroke.points.count >= 1 else { return }

        // Calculate brush radius in pixels (matches ImageService.applyStroke)
        let brushRadius = stroke.brushSize * size.width

        if stroke.isErasing {
            // Draw erase strokes with hatched pattern (red with diagonal lines)
            drawEraseStroke(stroke, in: &context, size: size, brushRadius: brushRadius)
        } else {
            // Draw add strokes with SAM2 mask color
            drawAddStroke(stroke, in: &context, size: size, brushRadius: brushRadius)
        }
    }

    private func drawAddStroke(_ stroke: PaintStroke, in context: inout GraphicsContext, size: CGSize, brushRadius: CGFloat) {
        let color = Self.maskColor.opacity(0.6)

        if stroke.points.count == 1 {
            let point = stroke.points[0]
            let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
            let rect = CGRect(x: center.x - brushRadius, y: center.y - brushRadius, width: brushRadius * 2, height: brushRadius * 2)
            context.fill(Circle().path(in: rect), with: .color(color))
        } else {
            // Draw connecting line
            var path = Path()
            let firstPoint = stroke.points[0]
            path.move(to: CGPoint(x: firstPoint.x * size.width, y: firstPoint.y * size.height))
            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: brushRadius * 2, lineCap: .round, lineJoin: .round))

            // Fill circles at each point
            for point in stroke.points {
                let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                let rect = CGRect(x: center.x - brushRadius, y: center.y - brushRadius, width: brushRadius * 2, height: brushRadius * 2)
                context.fill(Circle().path(in: rect), with: .color(color))
            }
        }
    }

    private func drawEraseStroke(_ stroke: PaintStroke, in context: inout GraphicsContext, size: CGSize, brushRadius: CGFloat) {
        // Draw red outline with hatched interior to indicate erasure
        let outlineColor = Self.eraseColor.opacity(0.8)
        let fillColor = Self.eraseColor.opacity(0.3)

        if stroke.points.count == 1 {
            let point = stroke.points[0]
            let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
            let rect = CGRect(x: center.x - brushRadius, y: center.y - brushRadius, width: brushRadius * 2, height: brushRadius * 2)

            // Fill with semi-transparent red
            context.fill(Circle().path(in: rect), with: .color(fillColor))
            // Red outline
            context.stroke(Circle().path(in: rect), with: .color(outlineColor), lineWidth: 2)
            // X mark in center
            drawXMark(at: center, size: brushRadius * 0.6, in: &context, color: outlineColor)
        } else {
            // Draw connecting line with hatched appearance
            var path = Path()
            let firstPoint = stroke.points[0]
            path.move(to: CGPoint(x: firstPoint.x * size.width, y: firstPoint.y * size.height))
            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }

            // Fill with semi-transparent red
            context.stroke(path, with: .color(fillColor), style: StrokeStyle(lineWidth: brushRadius * 2, lineCap: .round, lineJoin: .round))
            // Red outline (two strokes for outline effect)
            context.stroke(path, with: .color(outlineColor), style: StrokeStyle(lineWidth: brushRadius * 2 + 2, lineCap: .round, lineJoin: .round, dash: [4, 4]))

            // Draw circles and X marks at key points
            for (index, point) in stroke.points.enumerated() where index % 5 == 0 {
                let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                drawXMark(at: center, size: brushRadius * 0.4, in: &context, color: outlineColor)
            }
        }
    }

    private func drawXMark(at center: CGPoint, size: CGFloat, in context: inout GraphicsContext, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: center.x - size, y: center.y - size))
        path.addLine(to: CGPoint(x: center.x + size, y: center.y + size))
        path.move(to: CGPoint(x: center.x + size, y: center.y - size))
        path.addLine(to: CGPoint(x: center.x - size, y: center.y + size))
        context.stroke(path, with: .color(color), lineWidth: 2)
    }
}

/// Brush size indicator that follows the cursor
struct BrushSizeIndicator: View {
    // SAM2 mask color: RGB(50, 100, 200)
    private static let maskColor = Color(red: 50/255, green: 100/255, blue: 200/255)

    let brushSize: CGFloat  // Normalized 0-1
    let position: CGPoint?  // Normalized 0-1
    let displayedSize: CGSize

    var body: some View {
        GeometryReader { geo in
            if let pos = position {
                let pixelSize = brushSize * geo.size.width
                Circle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .background(Circle().fill(Self.maskColor.opacity(0.3)))
                    .frame(width: pixelSize, height: pixelSize)
                    .position(
                        x: pos.x * geo.size.width,
                        y: pos.y * geo.size.height
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Live brush cursor that follows the mouse position
struct BrushCursorPreview: View {
    // SAM2 mask color
    private static let maskColor = Color(red: 50/255, green: 100/255, blue: 200/255)

    let brushSize: CGFloat  // Normalized 0-1
    let isErasing: Bool
    let displayedSize: CGSize
    var cursorPosition: CGPoint? = nil  // Normalized 0-1 position

    var body: some View {
        GeometryReader { geo in
            let pixelSize = brushSize * geo.size.width

            ZStack {
                // Live cursor that follows mouse (when position available)
                if let pos = cursorPosition {
                    let cursorX = pos.x * geo.size.width
                    let cursorY = pos.y * geo.size.height

                    ZStack {
                        // Outer ring
                        Circle()
                            .stroke(isErasing ? Color.red : Color.white, lineWidth: 2)
                            .frame(width: pixelSize, height: pixelSize)

                        // Inner fill
                        Circle()
                            .fill(isErasing ? Color.red.opacity(0.2) : Self.maskColor.opacity(0.3))
                            .frame(width: pixelSize, height: pixelSize)

                        // X mark for erase mode
                        if isErasing {
                            Image(systemName: "xmark")
                                .font(.system(size: pixelSize * 0.3, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                    .position(x: cursorX, y: cursorY)
                }

                // Corner info panel
                VStack {
                    Spacer()
                    HStack {
                        HStack(spacing: 8) {
                            // Mode indicator
                            Circle()
                                .fill(isErasing ? Color.red : Self.maskColor)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    isErasing ?
                                    Image(systemName: "xmark")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundColor(.white) :
                                    Image(systemName: "plus")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundColor(.white)
                                )

                            Text(isErasing ? "Erase" : "Paint")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)

                            Text("(\(Int(brushSize * 100))%)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)

                        Spacer()
                    }
                }
                .padding(8)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    let sampleStrokes = [
        PaintStroke(startPoint: CGPoint(x: 0.2, y: 0.2), brushSize: 0.05, isErasing: false),
        PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5), brushSize: 0.08, isErasing: true)
    ]

    return PaintStrokeOverlay(
        strokes: sampleStrokes,
        currentStroke: nil,
        displayedSize: CGSize(width: 400, height: 300)
    )
    .frame(width: 400, height: 300)
    .background(Color.gray)
}
