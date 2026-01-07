import SwiftUI

/// Overlay that renders lasso selections
struct LassoOverlay: View {
    let lassoSelections: [LassoSelection]
    let currentLasso: LassoSelection?
    let displayedSize: CGSize
    let isPreprocessMode: Bool  // Different color for preprocess vs segment

    // SAM2 mask color for segment mode
    private static let segmentColor = Color(red: 50/255, green: 100/255, blue: 200/255)
    // Blue for crop in preprocess mode
    private static let cropColor = Color.blue

    var body: some View {
        Canvas { context, size in
            // Draw completed lasso selections
            for lasso in lassoSelections {
                drawLasso(lasso, in: &context, size: size, isCurrent: false)
            }

            // Draw current lasso being drawn
            if let current = currentLasso {
                drawLasso(current, in: &context, size: size, isCurrent: true)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawLasso(_ lasso: LassoSelection, in context: inout GraphicsContext, size: CGSize, isCurrent: Bool) {
        guard lasso.points.count >= 2 else { return }

        let color = isPreprocessMode ? Self.cropColor : Self.segmentColor

        // Create path from points
        var path = Path()
        let firstPoint = lasso.points[0]
        path.move(to: CGPoint(
            x: firstPoint.x * size.width,
            y: firstPoint.y * size.height
        ))

        for point in lasso.points.dropFirst() {
            path.addLine(to: CGPoint(
                x: point.x * size.width,
                y: point.y * size.height
            ))
        }

        // Close the path if not currently drawing
        if !isCurrent && lasso.points.count >= 3 {
            path.closeSubpath()

            // Fill with semi-transparent color
            context.fill(path, with: .color(color.opacity(0.3)))
        }

        // Draw stroke
        context.stroke(
            path,
            with: .color(isCurrent ? color : color.opacity(0.8)),
            style: StrokeStyle(
                lineWidth: isCurrent ? 2 : 1.5,
                lineCap: .round,
                lineJoin: .round,
                dash: isCurrent ? [5, 5] : []
            )
        )

        // Draw points as small circles
        for point in lasso.points {
            let center = CGPoint(
                x: point.x * size.width,
                y: point.y * size.height
            )
            let dotSize: CGFloat = isCurrent ? 4 : 3
            let rect = CGRect(
                x: center.x - dotSize/2,
                y: center.y - dotSize/2,
                width: dotSize,
                height: dotSize
            )
            context.fill(Circle().path(in: rect), with: .color(color))
        }
    }
}

/// Overlay for crop rectangle preview
struct CropOverlay: View {
    let cropRect: SAMBox?
    let displayedSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let crop = cropRect else { return }

            let rect = crop.normalizedRect
            let pixelRect = CGRect(
                x: rect.minX * size.width,
                y: rect.minY * size.height,
                width: rect.width * size.width,
                height: rect.height * size.height
            )

            // Dim area outside crop
            var dimPath = Path(CGRect(origin: .zero, size: size))
            dimPath.addRect(pixelRect)
            context.fill(dimPath, with: .color(Color.black.opacity(0.5)), style: FillStyle(eoFill: true))

            // Draw crop border
            context.stroke(
                Path(pixelRect),
                with: .color(.white),
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )

            // Draw corner handles
            let handleSize: CGFloat = 12
            let corners = [
                CGPoint(x: pixelRect.minX, y: pixelRect.minY),
                CGPoint(x: pixelRect.maxX, y: pixelRect.minY),
                CGPoint(x: pixelRect.minX, y: pixelRect.maxY),
                CGPoint(x: pixelRect.maxX, y: pixelRect.maxY)
            ]

            for corner in corners {
                let handleRect = CGRect(
                    x: corner.x - handleSize/2,
                    y: corner.y - handleSize/2,
                    width: handleSize,
                    height: handleSize
                )
                context.fill(Path(handleRect), with: .color(.white))
                context.stroke(Path(handleRect), with: .color(.black), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    let sampleLasso = LassoSelection(startPoint: CGPoint(x: 0.2, y: 0.2))

    return LassoOverlay(
        lassoSelections: [],
        currentLasso: sampleLasso,
        displayedSize: CGSize(width: 400, height: 300),
        isPreprocessMode: false
    )
    .frame(width: 400, height: 300)
    .background(Color.gray)
}
