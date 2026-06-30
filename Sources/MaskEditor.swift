import SwiftUI
import AppKit

enum MaskTool: Hashable { case brush, lasso }

/// Identifiable inputs for presenting the touch-up editor.
struct MaskEditorInputs: Identifiable {
    let id = UUID()
    let original: CGImage
    let mask: CGImage
}

/// Editable mask canvas. The removed region is veiled in a mask color (clearly "this
/// gets cut"); the kept region shows the full image. Paints into a DeviceGray mask
/// with a keep/remove brush or lasso, and draws a brush-size cursor on hover.
final class MaskCanvas: NSView {
    private let original: CGImage
    private let maskCtx: CGContext
    private var maskImage: CGImage

    var tool: MaskTool = .brush
    var keepMode = false                 // false = remove, true = keep/restore
    var brushRadius: CGFloat = 22        // view points — constant on-screen size

    private let maskColor = NSColor.systemRed

    private var hover: NSPoint?
    private var lasso: [CGPoint] = []     // image coords
    private var lastPaint: CGPoint?       // previous brush point, to connect strokes
    private var tracking: NSTrackingArea?

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero       // image-center offset from base center, view px
    private var panAnchor: NSPoint?

    init?(original: CGImage, mask: CGImage) {
        let w = original.width, h = original.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let normalized = BackgroundRemover.normalizedGray(mask, width: w, height: h) else { return nil }
        ctx.draw(normalized, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        self.original = original
        self.maskCtx = ctx
        self.maskImage = img
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    func currentMask() -> CGImage { maskImage }

    private var imgSize: CGSize { CGSize(width: original.width, height: original.height) }

    /// Aspect-fit of the image into the view at zoom 1.
    private var baseRect: CGRect {
        let b = bounds
        guard imgSize.width > 0, imgSize.height > 0 else { return b }
        let s = min(b.width / imgSize.width, b.height / imgSize.height)
        let w = imgSize.width * s, h = imgSize.height * s
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    /// Where the image is actually drawn, after zoom + pan. All hit-testing uses this.
    private var displayedRect: CGRect {
        let base = baseRect
        let w = base.width * zoom, h = base.height * zoom
        let cx = base.midX + pan.x, cy = base.midY + pan.y
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func toImage(_ p: NSPoint) -> CGPoint {
        let r = displayedRect
        return CGPoint(x: (p.x - r.minX) / r.width * imgSize.width,
                       y: (p.y - r.minY) / r.height * imgSize.height)
    }
    private func toView(_ p: CGPoint) -> CGPoint {
        let r = displayedRect
        return CGPoint(x: r.minX + p.x / imgSize.width * r.width,
                       y: r.minY + p.y / imgSize.height * r.height)
    }

    // MARK: zoom & pan

    func fit() { zoom = 1; pan = .zero; needsDisplay = true }

    override func magnify(with event: NSEvent) {
        zoomAt(convert(event.locationInWindow, from: nil), factor: 1 + event.magnification)
    }
    override func scrollWheel(with event: NSEvent) {
        let factor = max(0.85, min(1.18, 1 + event.scrollingDeltaY * 0.01))
        zoomAt(convert(event.locationInWindow, from: nil), factor: factor)
    }

    /// Zoom while keeping the image point under the cursor pinned.
    private func zoomAt(_ cursor: NSPoint, factor: CGFloat) {
        let ip = toImage(cursor)
        zoom = min(max(zoom * factor, 1), 8)
        let base = baseRect
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        pan.x = cursor.x - base.midX + size.width / 2 - ip.x / imgSize.width * size.width
        pan.y = cursor.y - base.midY + size.height / 2 - ip.y / imgSize.height * size.height
        clampPan()
        needsDisplay = true
    }

    private func clampPan() {
        if zoom <= 1 { pan = .zero; return }
        let base = baseRect
        let extraX = base.width * (zoom - 1) / 2, extraY = base.height * (zoom - 1) / 2
        pan.x = min(max(pan.x, -extraX), extraX)
        pan.y = min(max(pan.y, -extraY), extraY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = displayedRect

        ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        ctx.fill(bounds)

        // Darken the whole image heavily, then redraw the KEPT region bright — so the
        // removed region reads as faded/dark and the kept region is fully untouched.
        ctx.draw(original, in: r)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor); ctx.fill(r)

        ctx.saveGState()
        ctx.clip(to: r, mask: maskImage)
        ctx.draw(original, in: r)
        ctx.restoreGState()

        // lasso in progress
        if lasso.count > 1 {
            ctx.saveGState()
            ctx.setStrokeColor((keepMode ? NSColor.systemGreen : maskColor).cgColor)
            ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [6, 4])
            let path = CGMutablePath(); path.addLines(between: lasso.map(toView)); ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }

        // brush cursor: white halo + colored ring; constant on-screen size
        if tool == .brush, let h = hover {
            let vr = max(brushRadius, 2)
            let rect = CGRect(x: h.x - vr, y: h.y - vr, width: vr * 2, height: vr * 2)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect)
            ctx.setStrokeColor((keepMode ? NSColor.systemGreen : maskColor).cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
            ctx.restoreGState()
        }
    }

    /// Image-space brush radius at the current zoom, so the on-screen brush stays a
    /// constant visual size and paints a finer image area as you zoom in.
    private var imageBrushRadius: CGFloat {
        brushRadius * imgSize.width / max(displayedRect.width, 1)
    }

    private func paintStroke(to p: CGPoint) {
        let ir = imageBrushRadius
        let gray: CGFloat = keepMode ? 1 : 0
        maskCtx.setFillColor(gray: gray, alpha: 1)
        if let last = lastPaint {                       // connect points so fast strokes don't gap
            maskCtx.setStrokeColor(gray: gray, alpha: 1)
            maskCtx.setLineCap(.round)
            maskCtx.setLineWidth(ir * 2)
            maskCtx.beginPath(); maskCtx.move(to: last); maskCtx.addLine(to: p); maskCtx.strokePath()
        }
        maskCtx.fillEllipse(in: CGRect(x: p.x - ir, y: p.y - ir, width: ir * 2, height: ir * 2))
        lastPaint = p
        maskImage = maskCtx.makeImage() ?? maskImage
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.option) { panAnchor = p; return }  // ⌥-drag = pan
        if tool == .brush { lastPaint = nil; paintStroke(to: toImage(p)) } else { lasso = [toImage(p)] }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let a = panAnchor {
            pan.x += p.x - a.x; pan.y += p.y - a.y; panAnchor = p
            clampPan(); needsDisplay = true; return
        }
        hover = p
        if tool == .brush { paintStroke(to: toImage(p)) } else { lasso.append(toImage(p)); needsDisplay = true }
    }
    override func mouseUp(with e: NSEvent) {
        lastPaint = nil
        if panAnchor != nil { panAnchor = nil; return }
        if tool == .lasso, lasso.count > 2 {
            maskCtx.setFillColor(gray: keepMode ? 1 : 0, alpha: 1)
            let path = CGMutablePath(); path.addLines(between: lasso); path.closeSubpath()
            maskCtx.addPath(path); maskCtx.fillPath()
            maskImage = maskCtx.makeImage() ?? maskImage
        }
        lasso = []; needsDisplay = true
    }
    override func mouseMoved(with e: NSEvent) { hover = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); tracking = t
    }
}

final class MaskCanvasHolder: ObservableObject { var canvas: MaskCanvas? }

struct HostedCanvas: NSViewRepresentable {
    let holder: MaskCanvasHolder
    let original: CGImage
    let initialMask: CGImage
    var tool: MaskTool
    var keepMode: Bool
    var brushRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if let canvas = MaskCanvas(original: original, mask: initialMask) {
            holder.canvas = canvas
            return canvas
        }
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let c = nsView as? MaskCanvas else { return }
        c.tool = tool; c.keepMode = keepMode; c.brushRadius = brushRadius
        c.needsDisplay = true
    }
}

/// In-place touch-up editor: an opaque focus backdrop with the image shown frameless
/// (just the rounded image, hugging its aspect ratio). The tools live in the window
/// toolbar; this view is only the canvas.
struct MaskEditorOverlay: View {
    let inputs: MaskEditorInputs
    let holder: MaskCanvasHolder
    let tool: MaskTool
    let keepMode: Bool
    let brushRadius: CGFloat

    private var aspect: CGFloat {
        CGFloat(inputs.original.width) / CGFloat(max(inputs.original.height, 1))
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()   // opaque — nothing behind leaks through

            HostedCanvas(holder: holder, original: inputs.original, initialMask: inputs.mask,
                         tool: tool, keepMode: keepMode, brushRadius: brushRadius)
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .padding(24)
        }
    }
}
