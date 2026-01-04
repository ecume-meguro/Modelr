import SwiftUI

// MARK: - View Extension for Interactions
extension View {
    @ViewBuilder
    func addInteractions(viewModel: SimpleEditorViewModel, geo: GeometryProxy, displaySize: CGSize) -> some View {
        self
            .overlay(
                RightClickHandler { location in
                    if viewModel.currentStep == .segment {
                        let normalized = CGPoint(
                            x: location.x / displaySize.width,
                            y: location.y / displaySize.height
                        )
                        if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                            viewModel.addPoint(at: normalized)
                        }
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            )
            .onTapGesture { location in
                let imageX = (geo.size.width - displaySize.width) / 2
                let imageY = (geo.size.height - displaySize.height) / 2

                let normalized = CGPoint(
                    x: (location.x - imageX) / displaySize.width,
                    y: (location.y - imageY) / displaySize.height
                )
                guard normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 else { return }

                if viewModel.currentStep == .segment {
                    let activeIndex = viewModel.activeSegmentationIndex
                    if activeIndex < viewModel.segmentations.count && !viewModel.segmentations[activeIndex].allMasks.isEmpty {
                        if let clickedIndex = viewModel.findMaskAtPoint(normalized, displaySize: displaySize) {
                            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.selectMask(at: clickedIndex, for: activeIndex, addToSelection: shiftHeld)
                            }
                        }
                    }
                } else if viewModel.currentStep == .touchup {
                    viewModel.saveUndoState()
                    viewModel.paintOnMask(at: normalized)
                }
            }
            .onContinuousHover { phase in
                if viewModel.currentStep == .touchup {
                    switch phase {
                    case .active(let location):
                        let imageX = (geo.size.width - displaySize.width) / 2
                        let imageY = (geo.size.height - displaySize.height) / 2

                        let normalized = CGPoint(
                            x: (location.x - imageX) / displaySize.width,
                            y: (location.y - imageY) / displaySize.height
                        )
                        if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                            viewModel.brushPreviewPosition = normalized
                        } else {
                            viewModel.brushPreviewPosition = nil
                        }
                    case .ended:
                        viewModel.brushPreviewPosition = nil
                    }
                } else {
                    viewModel.brushPreviewPosition = nil
                }
            }
            .gesture(
                viewModel.currentStep == .touchup ?
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !viewModel.isStrokeInProgress {
                            viewModel.isStrokeInProgress = true
                            viewModel.saveUndoState()
                        }

                        let imageX = (geo.size.width - displaySize.width) / 2
                        let imageY = (geo.size.height - displaySize.height) / 2

                        let normalized = CGPoint(
                            x: (value.location.x - imageX) / displaySize.width,
                            y: (value.location.y - imageY) / displaySize.height
                        )
                        if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                            viewModel.brushPreviewPosition = normalized
                            viewModel.paintOnMask(at: normalized)
                        }
                    }
                    .onEnded { _ in
                        viewModel.isStrokeInProgress = false
                    }
                : nil
            )
    }
}

// MARK: - Right Click Handler
struct RightClickHandler: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    class RightClickView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        private var rightClickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
                rightClickMonitor = nil
            }

            if window != nil {
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                    guard let self = self,
                          let window = self.window,
                          event.window == window else {
                        return event
                    }

                    let locationInWindow = event.locationInWindow
                    let locationInView = self.convert(locationInWindow, from: nil)

                    if self.bounds.contains(locationInView) {
                        let flippedLocation = CGPoint(x: locationInView.x, y: self.bounds.height - locationInView.y)
                        self.onRightClick?(flippedLocation)
                        return nil
                    }
                    return event
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
                rightClickMonitor = nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
    }
}

// MARK: - Scroll Wheel Zoom
struct ScrollWheelZoomOverlay: NSViewRepresentable {
    @Binding var zoomScale: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {
        context.coordinator.zoomScale = $zoomScale
        context.coordinator.minZoom = minZoom
        context.coordinator.maxZoom = maxZoom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, minZoom: minZoom, maxZoom: maxZoom)
    }

    class Coordinator {
        var zoomScale: Binding<CGFloat>
        var minZoom: CGFloat
        var maxZoom: CGFloat

        init(zoomScale: Binding<CGFloat>, minZoom: CGFloat, maxZoom: CGFloat) {
            self.zoomScale = zoomScale
            self.minZoom = minZoom
            self.maxZoom = maxZoom
        }

        func handleScroll(deltaY: CGFloat) {
            let currentScale = zoomScale.wrappedValue
            let newScale = currentScale * (1.0 + deltaY * 0.05)
            zoomScale.wrappedValue = max(minZoom, min(maxZoom, newScale))
        }
    }

    class ScrollWheelCaptureView: NSView {
        weak var coordinator: Coordinator?
        private var scrollMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }

            if window != nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self = self,
                          let window = self.window,
                          event.window == window else {
                        return event
                    }

                    let locationInWindow = event.locationInWindow
                    let locationInView = self.convert(locationInWindow, from: nil)

                    if self.bounds.contains(locationInView) {
                        let delta = event.deltaY
                        if abs(delta) > 0.001 {
                            self.coordinator?.handleScroll(deltaY: delta)
                            return nil
                        }
                    }
                    return event
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
    }
}
