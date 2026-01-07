import SwiftUI

/// Overlay for drawing and displaying polygons
struct PolygonOverlay: View {
    let polygons: [PolygonSelection]
    let currentPolygon: PolygonSelection?
    let displayedSize: CGSize
    var onVertexTap: ((PolygonSelection, Int) -> Void)? = nil

    var body: some View {
        ZStack {
            // Draw completed polygons
            ForEach(polygons) { polygon in
                PolygonShape(vertices: polygon.vertices, isClosed: polygon.isClosed)
                    .stroke(Color.cyan, lineWidth: 2)
                    .frame(width: displayedSize.width, height: displayedSize.height)

                // Filled version with low opacity
                if polygon.isClosed {
                    PolygonShape(vertices: polygon.vertices, isClosed: true)
                        .fill(Color.cyan.opacity(0.2))
                        .frame(width: displayedSize.width, height: displayedSize.height)
                }

                // Vertex handles for completed polygons
                ForEach(polygon.vertices.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 8, height: 8)
                        .position(polygon.vertices[i].toViewCoords(displayedSize))
                }
            }

            // Draw current polygon being created
            if let current = currentPolygon, !current.vertices.isEmpty {
                // Polygon outline
                PolygonShape(vertices: current.vertices, isClosed: false)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: displayedSize.width, height: displayedSize.height)

                // Vertex handles
                ForEach(current.vertices.indices, id: \.self) { i in
                    Circle()
                        .fill(i == 0 ? Color.green : Color.yellow)
                        .frame(width: i == 0 ? 14 : 10, height: i == 0 ? 14 : 10)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .position(current.vertices[i].toViewCoords(displayedSize))
                }

                // Show "click first vertex to close" hint
                if current.vertices.count >= 3 {
                    Text("Click first vertex to close")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .position(x: displayedSize.width / 2, y: 20)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Shape for drawing polygon paths
struct PolygonShape: Shape {
    let vertices: [CGPoint]
    let isClosed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !vertices.isEmpty else { return path }

        let scaledVertices = vertices.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) }

        if let first = scaledVertices.first {
            path.move(to: first)
            for vertex in scaledVertices.dropFirst() {
                path.addLine(to: vertex)
            }
            if isClosed {
                path.closeSubpath()
            }
        }

        return path
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)

        PolygonOverlay(
            polygons: [
                PolygonSelection(vertices: [
                    CGPoint(x: 0.1, y: 0.1),
                    CGPoint(x: 0.3, y: 0.1),
                    CGPoint(x: 0.2, y: 0.3)
                ], isClosed: true)
            ],
            currentPolygon: PolygonSelection(vertices: [
                CGPoint(x: 0.5, y: 0.5),
                CGPoint(x: 0.7, y: 0.5),
                CGPoint(x: 0.6, y: 0.7)
            ]),
            displayedSize: CGSize(width: 400, height: 300)
        )
    }
    .frame(width: 400, height: 300)
}
