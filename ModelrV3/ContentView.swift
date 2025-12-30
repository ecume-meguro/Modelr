import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var env = PythonEnvironment()
    @State private var inputImage: NSImage?
    @State private var inputImagePath: String?
    @State private var maskImage: NSImage?
    @State private var isDragging = false
    
    var body: some View {
        VStack {
            if !env.isSetup {
                SplashScreenView(env: env)
            } else {
                editorView
            }
            
            if env.isSetup {
                statusFooter
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            Task {
                await env.setup()
            }
        }
    }
    
    var setupView: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text(env.status)
                .font(.headline)
        }
    }
    
    var editorView: some View {
        ZStack {
            if let inputImage = inputImage {
                GeometryReader { geo in
                    ZStack {
                        Image(nsImage: inputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onTapGesture { location in
                                handleTap(at: location, in: geo.size)
                            }
                        
                        if let maskImage = maskImage {
                            Image(nsImage: maskImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .allowsHitTesting(false)
                                .opacity(0.5)
                                .blendMode(.screen)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                dropZone
            }
        }
    }
    
    var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isDragging ? Color.blue : Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10]))
            .background(Color.gray.opacity(0.05))
            .overlay(
                VStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("Drop an image here")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            )
            .onDrop(of: [.image], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
                return true
            }
            .padding(40)
    }
    
    var statusFooter: some View {
        HStack {
            Text(env.status)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if inputImage != nil {
                Button("Clear") {
                    inputImage = nil
                    inputImagePath = nil
                    maskImage = nil
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url = url {
                DispatchQueue.main.async {
                    self.inputImage = NSImage(contentsOf: url)
                    self.inputImagePath = url.path
                    self.maskImage = nil
                }
            }
        }
    }
    
    func handleTap(at location: CGPoint, in size: CGSize) {
        guard let inputImage = inputImage, let path = inputImagePath else { return }
        
        // Translate tap location to image coordinates
        // This is a simplification; for a real app we'd need to account for fit mode scaling/letterboxing
        let imageSize = inputImage.size
        let viewRatio = size.width / size.height
        let imageRatio = imageSize.width / imageSize.height
        
        var displayedWidth: CGFloat
        var displayedHeight: CGFloat
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        
        if imageRatio > viewRatio {
            displayedWidth = size.width
            displayedHeight = size.width / imageRatio
            offsetY = (size.height - displayedHeight) / 2
        } else {
            displayedHeight = size.height
            displayedWidth = size.height * imageRatio
            offsetX = (size.width - displayedWidth) / 2
        }
        
        let relativeX = (location.x - offsetX) / displayedWidth
        let relativeY = (location.y - offsetY) / displayedHeight
        
        guard relativeX >= 0, relativeX <= 1, relativeY >= 0, relativeY <= 1 else { return }
        
        let targetX = Int(relativeX * imageSize.width)
        let targetY = Int(relativeY * imageSize.height)
        
        Task {
            if let maskURL = await env.runSAM2(imagePath: path, x: targetX, y: targetY) {
                if let newMask = NSImage(contentsOf: maskURL) {
                    self.maskImage = newMask
                }
            }
        }
    }
}
