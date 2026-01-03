import SwiftUI

/// Overlay that displays bounding boxes on the image
struct BoundingBoxOverlay: View {
    let boxes: [SAMBox]
    let currentBox: SAMBox?
    let displayedSize: CGSize
    var imagePixelSize: CGSize = .zero  // For showing actual pixel dimensions
    var selectedBoxId: UUID? = nil
    var onBoxTap: ((SAMBox) -> Void)? = nil

    var body: some View {
        // Completed boxes
        ForEach(boxes) { box in
            ZStack {
                BoundingBoxShape(box: box, displayedSize: displayedSize)
                    .stroke(
                        box.id == selectedBoxId ? Color.yellow : Color.white,
                        style: StrokeStyle(lineWidth: box.id == selectedBoxId ? 3 : 2, dash: [6, 4])
                    )
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
            }
            .contentShape(BoundingBoxShape(box: box, displayedSize: displayedSize))
            .onTapGesture {
                onBoxTap?(box)
            }
        }

        // Current box being drawn with live dimensions
        if let current = currentBox {
            ZStack {
                BoundingBoxShape(box: current, displayedSize: displayedSize)
                    .stroke(
                        current.isValid ? Color.cyan : Color.orange,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .shadow(color: .cyan.opacity(0.5), radius: 3, x: 0, y: 0)

                // Dimension label
                BoxDimensionLabel(
                    box: current,
                    displayedSize: displayedSize,
                    imagePixelSize: imagePixelSize
                )
            }
        }
    }
}

/// Label showing box dimensions while drawing
struct BoxDimensionLabel: View {
    let box: SAMBox
    let displayedSize: CGSize
    let imagePixelSize: CGSize

    var body: some View {
        let rect = box.normalizedRect
        let pixelWidth = Int(rect.width * (imagePixelSize.width > 0 ? imagePixelSize.width : displayedSize.width))
        let pixelHeight = Int(rect.height * (imagePixelSize.height > 0 ? imagePixelSize.height : displayedSize.height))

        let centerX = (rect.minX + rect.maxX) / 2 * displayedSize.width
        let bottomY = rect.maxY * displayedSize.height + 20

        VStack(spacing: 2) {
            Text("\(pixelWidth) x \(pixelHeight)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            if !box.isValid {
                Text("Too small")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.7))
        .cornerRadius(4)
        .position(x: centerX, y: min(bottomY, displayedSize.height - 15))
    }
}

/// Shape that draws a bounding box rectangle
struct BoundingBoxShape: Shape {
    let box: SAMBox
    let displayedSize: CGSize

    func path(in rect: CGRect) -> Path {
        let start = box.startPoint.toViewCoords(displayedSize)
        let end = box.endPoint.toViewCoords(displayedSize)

        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: end.x, y: start.y))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: start.x, y: end.y))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)

        BoundingBoxOverlay(
            boxes: [
                SAMBox(
                    startPoint: CGPoint(x: 0.1, y: 0.1),
                    endPoint: CGPoint(x: 0.4, y: 0.4)
                )
            ],
            currentBox: SAMBox(
                startPoint: CGPoint(x: 0.5, y: 0.5),
                endPoint: CGPoint(x: 0.9, y: 0.8)
            ),
            displayedSize: CGSize(width: 400, height: 300)
        )
    }
    .frame(width: 400, height: 300)
}
