import SwiftUI

/// Overlay that displays click points on the image with drag-to-move support
struct PointsOverlay: View {
    let points: [SAMPoint]
    let displayedSize: CGSize
    var selectedPointId: UUID? = nil
    var onPointTap: ((SAMPoint) -> Void)? = nil
    var onPointDrag: ((SAMPoint, CGPoint) -> Void)? = nil  // Live drag updates
    var onPointDragEnd: ((SAMPoint, CGPoint) -> Void)? = nil  // Final position

    // Track which point is being dragged and its current position
    @State private var draggingPointId: UUID? = nil
    @State private var dragOffset: CGPoint = .zero

    var body: some View {
        ForEach(points) { point in
            let isDragging = draggingPointId == point.id
            let displayPosition: CGPoint = {
                if isDragging {
                    // Show at drag position during drag
                    return dragOffset.toViewCoords(displayedSize)
                } else {
                    return point.normalizedCoords.toViewCoords(displayedSize)
                }
            }()

            PointMarker(
                isPositive: point.isPositive,
                isSelected: point.id == selectedPointId || isDragging
            )
            .position(displayPosition)
            .transition(.scale.combined(with: .opacity))
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        draggingPointId = point.id
                        // Convert to normalized coordinates
                        let normalized = CGPoint(
                            x: value.location.x / displayedSize.width,
                            y: value.location.y / displayedSize.height
                        ).clamped
                        dragOffset = normalized
                        onPointDrag?(point, normalized)
                    }
                    .onEnded { value in
                        let normalized = CGPoint(
                            x: value.location.x / displayedSize.width,
                            y: value.location.y / displayedSize.height
                        ).clamped
                        onPointDragEnd?(point, normalized)
                        draggingPointId = nil
                        dragOffset = .zero
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        if draggingPointId == nil {
                            onPointTap?(point)
                        }
                    }
            )
            .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: isDragging)
        }
    }
}

/// Visual marker for a single point
struct PointMarker: View {
    var isPositive: Bool = true
    var isSelected: Bool = false
    var size: CGFloat = 14

    private var color: Color {
        isPositive ? .green : .red
    }

    var body: some View {
        ZStack {
            // Selection ring
            if isSelected {
                Circle()
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: size + 10, height: size + 10)
            }

            // Outer white ring for visibility on any background
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: size + 4, height: size + 4)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

            // Inner colored fill
            Circle()
                .fill(color)
                .frame(width: size, height: size)

            // Negative point gets an X
            if !isPositive {
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }

            // Positive point gets a plus
            if isPositive {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)

        PointsOverlay(
            points: [
                SAMPoint(normalizedCoords: CGPoint(x: 0.25, y: 0.25), label: 1),
                SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1),
                SAMPoint(normalizedCoords: CGPoint(x: 0.75, y: 0.75), label: 0)  // Negative point
            ],
            displayedSize: CGSize(width: 400, height: 300)
        )
    }
    .frame(width: 400, height: 300)
}
