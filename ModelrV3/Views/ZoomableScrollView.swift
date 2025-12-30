import SwiftUI
import AppKit

/// A zoomable and pannable scroll view wrapper using native NSScrollView
struct ZoomableScrollView<Content: View>: NSViewRepresentable {
    @Binding var magnification: CGFloat
    private var content: Content

    init(
        magnification: Binding<CGFloat> = .constant(1.0),
        @ViewBuilder content: () -> Content
    ) {
        self._magnification = magnification
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 20.0
        scrollView.magnification = magnification

        // Use layer backing for better performance
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true

        // Background color
        scrollView.backgroundColor = NSColor.windowBackgroundColor
        scrollView.drawsBackground = true

        let hostedView = context.coordinator.hostingView
        hostedView.translatesAutoresizingMaskIntoConstraints = false

        // Set the hosted view as the document view
        scrollView.documentView = hostedView

        // Center the content initially
        scrollView.contentView.postsBoundsChangedNotifications = true

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.hostingView.rootView = content

        // Update magnification if changed externally
        if abs(nsView.magnification - magnification) > 0.01 {
            nsView.magnification = magnification
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostingView: NSHostingView(rootView: content), parent: self)
    }

    class Coordinator: NSObject {
        var hostingView: NSHostingView<Content>
        var parent: ZoomableScrollView

        init(hostingView: NSHostingView<Content>, parent: ZoomableScrollView) {
            self.hostingView = hostingView
            self.parent = parent
            super.init()

            // Listen for magnification changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidMagnify(_:)),
                name: NSScrollView.didEndLiveMagnifyNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func scrollViewDidMagnify(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView else { return }
            DispatchQueue.main.async {
                self.parent.magnification = scrollView.magnification
            }
        }
    }
}

/// View modifier to add zoom controls
struct ZoomControlsModifier: ViewModifier {
    @Binding var magnification: CGFloat
    let minMagnification: CGFloat = 0.5
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
        withAnimation(.spring(response: 0.3)) {
            magnification = min(magnification * 1.5, maxMagnification)
        }
    }

    private func zoomOut() {
        withAnimation(.spring(response: 0.3)) {
            magnification = max(magnification / 1.5, minMagnification)
        }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.3)) {
            magnification = 1.0
        }
    }
}

extension View {
    func zoomControls(magnification: Binding<CGFloat>) -> some View {
        modifier(ZoomControlsModifier(magnification: magnification))
    }
}

#Preview {
    ZoomableScrollView {
        Rectangle()
            .fill(Color.blue.opacity(0.3))
            .frame(width: 800, height: 600)
            .overlay {
                Text("Zoomable Content")
                    .font(.largeTitle)
            }
    }
    .frame(width: 400, height: 300)
}
