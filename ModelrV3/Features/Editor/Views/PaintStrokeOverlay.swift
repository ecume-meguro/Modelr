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

    private func drawStroke(_ stroke: PaintStroke, in context: inout GraphicsContext, size: CGSize) {
        guard stroke.points.count >= 1 else { return }

        // Calculate brush size in pixels
        let brushRadius = stroke.brushSize * size.width / 2

        // Set color based on add/erase mode - match SAM2 mask color
        let color: Color = stroke.isErasing
            ? Color.black.opacity(0.8)  // Erase = dark to show removal
            : Self.maskColor.opacity(0.6)  // Add = same as SAM2 mask

        if stroke.points.count == 1 {
            // Single point - draw a circle
            let point = stroke.points[0]
            let center = CGPoint(
                x: point.x * size.width,
                y: point.y * size.height
            )
            let rect = CGRect(
                x: center.x - brushRadius,
                y: center.y - brushRadius,
                width: brushRadius * 2,
                height: brushRadius * 2
            )
            context.fill(Circle().path(in: rect), with: .color(color))
        } else {
            // Multiple points - draw circles along the path
            for point in stroke.points {
                let center = CGPoint(
                    x: point.x * size.width,
                    y: point.y * size.height
                )
                let rect = CGRect(
                    x: center.x - brushRadius,
                    y: center.y - brushRadius,
                    width: brushRadius * 2,
                    height: brushRadius * 2
                )
                context.fill(Circle().path(in: rect), with: .color(color))
            }

            // Also draw connecting lines for smooth strokes
            var path = Path()
            let firstPoint = stroke.points[0]
            path.move(to: CGPoint(
                x: firstPoint.x * size.width,
                y: firstPoint.y * size.height
            ))

            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(
                    x: point.x * size.width,
                    y: point.y * size.height
                ))
            }

            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: brushRadius * 2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
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

/// Static brush cursor preview that shows in the center of the view
struct BrushCursorPreview: View {
    // SAM2 mask color
    private static let maskColor = Color(red: 50/255, green: 100/255, blue: 200/255)

    let brushSize: CGFloat  // Normalized 0-1
    let isErasing: Bool
    let displayedSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let pixelSize = brushSize * geo.size.width

            // Show brush preview in bottom-left corner
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        // Brush size indicator circle
                        Circle()
                            .stroke(isErasing ? Color.red : Color.white, lineWidth: 2)
                            .background(
                                Circle()
                                    .fill(isErasing ? Color.red.opacity(0.3) : Self.maskColor.opacity(0.4))
                            )
                            .frame(width: pixelSize, height: pixelSize)

                        // Label
                        Text(isErasing ? "Erase" : "Paint")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isErasing ? Color.red.opacity(0.8) : Self.maskColor.opacity(0.8))
                            .cornerRadius(4)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)

                    Spacer()
                }
            }
            .padding(8)
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
