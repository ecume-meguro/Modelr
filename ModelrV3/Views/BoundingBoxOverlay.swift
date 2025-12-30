import SwiftUI

/// Overlay that displays bounding boxes on the image
struct BoundingBoxOverlay: View {
    let boxes: [SAMBox]
    let currentBox: SAMBox?
    let displayedSize: CGSize

    var body: some View {
        // Completed boxes
        ForEach(boxes) { box in
            BoundingBoxShape(box: box, displayedSize: displayedSize)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }

        // Current box being drawn
        if let current = currentBox {
            BoundingBoxShape(box: current, displayedSize: displayedSize)
                .stroke(
                    Color.cyan,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .shadow(color: .cyan.opacity(0.5), radius: 3, x: 0, y: 0)
        }
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
