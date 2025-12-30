import SwiftUI

/// Overlay that displays click points on the image
struct PointsOverlay: View {
    let points: [SAMPoint]
    let displayedSize: CGSize

    var body: some View {
        ForEach(points) { point in
            PointMarker()
                .position(point.normalizedCoords.toViewCoords(displayedSize))
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Visual marker for a single point
struct PointMarker: View {
    var color: Color = .pink
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            // Outer white ring for visibility on any background
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: size + 4, height: size + 4)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

            // Inner colored fill
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)

        PointsOverlay(
            points: [
                SAMPoint(normalizedCoords: CGPoint(x: 0.25, y: 0.25)),
                SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5)),
                SAMPoint(normalizedCoords: CGPoint(x: 0.75, y: 0.75))
            ],
            displayedSize: CGSize(width: 400, height: 300)
        )
    }
    .frame(width: 400, height: 300)
}
