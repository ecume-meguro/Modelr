import Foundation
import CoreGraphics
import SwiftUI
import Combine

// MARK: - Scroll State Tracking

/// Tracks scroll state to prevent hover events during scrolling
@MainActor
final class ScrollStateTracker: ObservableObject {
    static let shared = ScrollStateTracker()

    @Published private(set) var isScrolling: Bool = false
    private var scrollEndTimer: Timer?
    private var scrollWheelMonitor: Any?

    private init() {
        setupScrollWheelMonitor()
    }

    private func setupScrollWheelMonitor() {
        // Monitor scroll wheel events directly - this catches scroll immediately
        // before NSScrollView notifications which have latency
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Any scroll wheel activity means we're scrolling
            if event.deltaY != 0 || event.deltaX != 0 {
                Task { @MainActor in
                    self?.handleScrollWheel()
                }
            }
            return event
        }
    }

    private func handleScrollWheel() {
        // Immediately mark as scrolling
        if !isScrolling {
            isScrolling = true
        }

        // Reset the end timer on each scroll event
        scrollEndTimer?.invalidate()
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isScrolling = false
            }
        }
    }

    deinit {
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
        }
        scrollEndTimer?.invalidate()
    }
}

// MARK: - Conditional Hover Modifier

extension View {
    /// onHover that ignores events during scrolling
    func onHoverIfNotScrolling(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollAwareHoverModifier(action: action))
    }
}

private struct ScrollAwareHoverModifier: ViewModifier {
    let action: (Bool) -> Void
    @State private var isHovered = false
    @State private var lastReportedHover = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovered = hovering
                // Only report hover changes if not scrolling
                let scrolling = ScrollStateTracker.shared.isScrolling
                if !scrolling && hovering != lastReportedHover {
                    lastReportedHover = hovering
                    action(hovering)
                } else if scrolling && lastReportedHover {
                    // Clear hover immediately when scrolling starts
                    lastReportedHover = false
                    action(false)
                }
            }
            .onReceive(ScrollStateTracker.shared.$isScrolling) { isScrolling in
                if isScrolling && lastReportedHover {
                    // Clear hover when scrolling starts
                    lastReportedHover = false
                    action(false)
                } else if !isScrolling && isHovered && !lastReportedHover {
                    // Restore hover when scrolling stops (if still hovered)
                    lastReportedHover = true
                    action(true)
                }
            }
    }
}

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Coordinate Extensions

extension CGPoint {
    /// Convert normalized (0-1) coords to view coords
    func toViewCoords(_ viewSize: CGSize) -> CGPoint {
        CGPoint(x: x * viewSize.width, y: y * viewSize.height)
    }

    /// Convert view coords to normalized (0-1) coords
    func toNormalized(_ viewSize: CGSize) -> CGPoint {
        CGPoint(x: x / viewSize.width, y: y / viewSize.height)
    }

    /// Clamp to 0-1 range
    var clamped: CGPoint {
        CGPoint(
            x: max(0, min(1, x)),
            y: max(0, min(1, y))
        )
    }
}
