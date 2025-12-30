import SwiftUI
import AppKit

// MARK: - ZoomableImageView

/// A zoomable and pannable image view using native NSScrollView with AppKit gesture handling.
/// Fixes: centering on load, smooth panning, correct click coordinates.
struct ZoomableImageView<Content: View>: NSViewRepresentable {
    @Binding var magnification: CGFloat

    // Gesture callbacks (normalized 0-1 coordinates)
    var onTap: ((CGPoint) -> Void)?
    var onDragStart: ((CGPoint) -> Void)?
    var onDragChange: ((CGPoint, CGPoint) -> Void)?
    var onDragEnd: ((CGPoint, CGPoint) -> Void)?

    // Paint-specific callbacks
    var onPaintStart: ((CGPoint) -> Void)?
    var onPaintContinue: ((CGPoint) -> Void)?
    var onPaintEnd: (() -> Void)?

    // Lasso-specific callbacks (same signature as paint)
    var onLassoStart: ((CGPoint) -> Void)?
    var onLassoContinue: ((CGPoint) -> Void)?
    var onLassoEnd: (() -> Void)?

    // Tool mode determines gesture behavior
    var toolMode: SAMTool

    // Content configuration
    let contentSize: CGSize
    let contentID: String
    let content: () -> Content

    init(
        magnification: Binding<CGFloat>,
        onTap: ((CGPoint) -> Void)? = nil,
        onDragStart: ((CGPoint) -> Void)? = nil,
        onDragChange: ((CGPoint, CGPoint) -> Void)? = nil,
        onDragEnd: ((CGPoint, CGPoint) -> Void)? = nil,
        onPaintStart: ((CGPoint) -> Void)? = nil,
        onPaintContinue: ((CGPoint) -> Void)? = nil,
        onPaintEnd: (() -> Void)? = nil,
        onLassoStart: ((CGPoint) -> Void)? = nil,
        onLassoContinue: ((CGPoint) -> Void)? = nil,
        onLassoEnd: (() -> Void)? = nil,
        toolMode: SAMTool = .point,
        contentSize: CGSize,
        contentID: String = "",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._magnification = magnification
        self.onTap = onTap
        self.onDragStart = onDragStart
        self.onDragChange = onDragChange
        self.onDragEnd = onDragEnd
        self.onPaintStart = onPaintStart
        self.onPaintContinue = onPaintContinue
        self.onPaintEnd = onPaintEnd
        self.onLassoStart = onLassoStart
        self.onLassoContinue = onLassoContinue
        self.onLassoEnd = onLassoEnd
        self.toolMode = toolMode
        self.contentSize = contentSize
        self.contentID = contentID
        self.content = content
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 20.0
        scrollView.magnification = magnification

        // Use layer backing for performance
        scrollView.wantsLayer = true

        // Use centering clip view
        let clipView = CenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = NSColor.windowBackgroundColor
        scrollView.contentView = clipView

        // Create canvas view that handles mouse events
        let canvasView = context.coordinator.canvasView
        canvasView.frame = NSRect(origin: .zero, size: contentSize)
        canvasView.toolMode = toolMode
        canvasView.onTap = onTap
        canvasView.onDragStart = onDragStart
        canvasView.onDragChange = onDragChange
        canvasView.onDragEnd = onDragEnd
        canvasView.onPaintStart = onPaintStart
        canvasView.onPaintContinue = onPaintContinue
        canvasView.onPaintEnd = onPaintEnd
        canvasView.onLassoStart = onLassoStart
        canvasView.onLassoContinue = onLassoContinue
        canvasView.onLassoEnd = onLassoEnd

        // Create hosting view for SwiftUI content
        let hostingView = NSHostingView(rootView: content())
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        hostingView.autoresizingMask = [.width, .height]
        canvasView.addSubview(hostingView)
        context.coordinator.hostingView = hostingView

        // Set canvas as document view
        scrollView.documentView = canvasView

        // Setup notifications
        context.coordinator.setupNotifications(scrollView: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator

        // Update hosting view content
        coordinator.hostingView?.rootView = content()

        // Update canvas size if changed
        if coordinator.canvasView.frame.size != contentSize {
            coordinator.canvasView.frame.size = contentSize
            coordinator.hostingView?.frame.size = contentSize
        }

        // Update tool mode and callbacks
        coordinator.canvasView.toolMode = toolMode
        coordinator.canvasView.magnification = magnification
        coordinator.canvasView.onTap = onTap
        coordinator.canvasView.onDragStart = onDragStart
        coordinator.canvasView.onDragChange = onDragChange
        coordinator.canvasView.onDragEnd = onDragEnd
        coordinator.canvasView.onPaintStart = onPaintStart
        coordinator.canvasView.onPaintContinue = onPaintContinue
        coordinator.canvasView.onPaintEnd = onPaintEnd
        coordinator.canvasView.onLassoStart = onLassoStart
        coordinator.canvasView.onLassoContinue = onLassoContinue
        coordinator.canvasView.onLassoEnd = onLassoEnd

        // Update magnification if changed externally
        if abs(scrollView.magnification - magnification) > 0.01 {
            scrollView.magnification = magnification
        }

        // Re-layout if content ID changed (new image)
        if coordinator.lastContentID != contentID {
            coordinator.lastContentID = contentID
            // Reset magnification for new content
            scrollView.magnification = 1.0
            // Force layout update
            scrollView.tile()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, contentSize: contentSize)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var parent: ZoomableImageView
        var canvasView: ImageCanvasView
        var hostingView: NSHostingView<Content>?
        var lastContentID: String = ""

        init(parent: ZoomableImageView, contentSize: CGSize) {
            self.parent = parent
            self.canvasView = ImageCanvasView(frame: NSRect(origin: .zero, size: contentSize))
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func setupNotifications(scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(magnificationChanged(_:)),
                name: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveMagnificationChanged(_:)),
                name: NSScrollView.willStartLiveMagnifyNotification,
                object: scrollView
            )
        }

        @objc func magnificationChanged(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView else { return }
            DispatchQueue.main.async {
                self.parent.magnification = scrollView.magnification
            }
        }

        @objc func liveMagnificationChanged(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView else { return }
            DispatchQueue.main.async {
                self.parent.magnification = scrollView.magnification
            }
        }
    }
}

// MARK: - ImageCanvasView

/// Custom NSView that intercepts mouse events for point/box/paint/lasso tools.
/// Sits between NSScrollView and NSHostingView to handle gestures in AppKit.
class ImageCanvasView: NSView {
    var toolMode: SAMTool = .point
    var magnification: CGFloat = 1.0  // Track magnification from NSScrollView

    var onTap: ((CGPoint) -> Void)?
    var onDragStart: ((CGPoint) -> Void)?
    var onDragChange: ((CGPoint, CGPoint) -> Void)?
    var onDragEnd: ((CGPoint, CGPoint) -> Void)?

    // Paint-specific callbacks
    var onPaintStart: ((CGPoint) -> Void)?
    var onPaintContinue: ((CGPoint) -> Void)?
    var onPaintEnd: (() -> Void)?

    // Lasso-specific callbacks
    var onLassoStart: ((CGPoint) -> Void)?
    var onLassoContinue: ((CGPoint) -> Void)?
    var onLassoEnd: (() -> Void)?

    private var isDragging = false
    private var dragStartPoint: CGPoint?

    override var isFlipped: Bool { true }  // Match SwiftUI coordinate system (origin top-left)

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let normalized = normalizePoint(location)

        switch toolMode {
        case .point:
            // Single click for point placement
            onTap?(normalized)
        case .boundingBox:
            // Start drag for bounding box
            isDragging = true
            dragStartPoint = normalized
            onDragStart?(normalized)
        case .lasso:
            // Start lasso selection
            isDragging = true
            onLassoStart?(normalized)
        case .paint:
            // Start paint stroke
            isDragging = true
            onPaintStart?(normalized)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let normalized = normalizePoint(location)

        switch toolMode {
        case .point:
            break  // No drag for point mode
        case .boundingBox:
            guard isDragging, let start = dragStartPoint else { return }
            onDragChange?(start, normalized)
        case .lasso:
            guard isDragging else { return }
            onLassoContinue?(normalized)
        case .paint:
            guard isDragging else { return }
            onPaintContinue?(normalized)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let normalized = normalizePoint(location)

        switch toolMode {
        case .point:
            break
        case .boundingBox:
            if isDragging, let start = dragStartPoint {
                onDragEnd?(start, normalized)
            }
        case .lasso:
            if isDragging {
                onLassoEnd?()
            }
        case .paint:
            if isDragging {
                onPaintEnd?()
            }
        }

        isDragging = false
        dragStartPoint = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Add new tracking area for cursor changes
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        switch toolMode {
        case .point:
            NSCursor.pointingHand.set()
        case .boundingBox, .lasso:
            NSCursor.crosshair.set()
        case .paint:
            NSCursor.crosshair.set()
        }
    }

    private func normalizePoint(_ point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        return CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height
        )
    }
}

// MARK: - CenteringClipView

/// Custom NSClipView that centers content when smaller than the viewport.
/// Uses constrainBoundsRect for immediate centering without delays.
class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)

        guard let docView = documentView else { return rect }
        let docFrame = docView.frame

        // Center horizontally if content narrower than viewport
        if docFrame.width < bounds.width {
            rect.origin.x = (docFrame.width - bounds.width) / 2
        }

        // Center vertically if content shorter than viewport
        if docFrame.height < bounds.height {
            rect.origin.y = (docFrame.height - bounds.height) / 2
        }

        return rect
    }
}

// MARK: - Zoom Controls Modifier

struct ZoomControlsModifier: ViewModifier {
    @Binding var magnification: CGFloat
    let minMagnification: CGFloat = 0.1
    let maxMagnification: CGFloat = 20.0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Button(action: zoomOut) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .disabled(magnification <= minMagnification)

                    Text("\(Int(magnification * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(width: 45)

                    Button(action: zoomIn) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .disabled(magnification >= maxMagnification)

                    Button(action: resetZoom) {
                        Image(systemName: "1.magnifyingglass")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .disabled(abs(magnification - 1.0) < 0.01)
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .padding(12)
            }
    }

    private func zoomIn() {
        magnification = min(magnification * 1.5, maxMagnification)
    }

    private func zoomOut() {
        magnification = max(magnification / 1.5, minMagnification)
    }

    private func resetZoom() {
        magnification = 1.0
    }
}

extension View {
    func zoomControls(magnification: Binding<CGFloat>) -> some View {
        modifier(ZoomControlsModifier(magnification: magnification))
    }
}
