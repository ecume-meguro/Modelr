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
            // Setup will be triggered manually from the splash screen
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
                    let imageSize = inputImage.size
                    let containerSize = geo.size

                    // Calculate displayed image dimensions (matching .aspectRatio .fit behavior)
                    let imageRatio = imageSize.width / imageSize.height
                    let containerRatio = containerSize.width / containerSize.height
                    let displayedSize: CGSize = imageRatio > containerRatio
                        ? CGSize(width: containerSize.width, height: containerSize.width / imageRatio)
                        : CGSize(width: containerSize.height * imageRatio, height: containerSize.height)

                    ZStack {
                        Image(nsImage: inputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)

                        if let maskImage = maskImage {
                            // Explicitly size mask to match displayed image dimensions
                            // This ensures alignment regardless of DPI metadata differences
                            Image(nsImage: maskImage)
                                .resizable()
                                .frame(width: displayedSize.width, height: displayedSize.height)
                                .allowsHitTesting(false)
                                .opacity(0.6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleTap(at: location, in: geo.size)
                    }
                }
            } else {
                dropZone
            }
        }
    }
    
    var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isDragging ? Color(red: 0.1, green: 0.3, blue: 0.7) : Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10]))
            .background(Color.gray.opacity(0.05))
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("Drop an image here")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            )
            .onDrop(of: [.image, .fileURL, .url], isTargeted: $isDragging) { providers in
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
        print("Dropped items: \(providers.count)")
        guard let provider = providers.first else { return }
        print("Registered types: \(provider.registeredTypeIdentifiers)")
        
        // 1. First, try to get a file URL if it's explicitly conforming to one.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    self.loadImage(from: url)
                } else if let url = item as? URL {
                    self.loadImage(from: url)
                }
            }
            return
        }
        
        // 2. Iterate through all types and see if any conform to 'image'.
        // This is much more robust than checking for a single identifier.
        for type in provider.registeredTypeIdentifiers {
            if let utType = UTType(type), utType.conforms(to: .image) {
                print("Found compatible image type: \(type)")
                
                // Try loading as a loadable object (like NSImage)
                if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, error in
                        if let image = image as? NSImage {
                            self.saveAndLoad(image: image)
                        }
                    }
                    return
                }
                
                // Fallback: try loading the item directly as a URL/Data
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                    if let url = item as? URL {
                        self.loadImage(from: url)
                    } else if let data = item as? Data, let image = NSImage(data: data) {
                        self.saveAndLoad(image: image)
                    }
                }
                return
            }
        }

        // 3. Last ditch fallback for generic URL (e.g. from browser)
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    self.loadImage(from: url)
                }
            }
        } else {
            print("No compatible types found for dropping")
            DispatchQueue.main.async {
                self.env.status = "Error: Unsupported drop type"
            }
        }
    }
    
    private func saveAndLoad(image: NSImage) {
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("temp_drop.png")
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: tempFile)
                print("Saved dropped image to temp file: \(tempFile.path)")
                self.loadImage(from: tempFile)
            }
        } catch {
            print("Failed to save dropped image: \(error.localizedDescription)")
        }
    }
    
    private func loadImage(from url: URL) {
        print("Attempting to load image from: \(url.path)")
        DispatchQueue.main.async {
            guard let image = NSImage(contentsOf: url) else {
                print("Failed to create NSImage from: \(url.path)")
                self.env.status = "Error: Could not load image"
                return
            }

            self.inputImage = image
            self.maskImage = nil
            self.env.status = "Loaded image: \(url.lastPathComponent)"
            print("Successfully loaded image from source")
            
            // Python compatibility check
            // PIL supports these natively. PDFs are not images in PIL.
            let safeExtensions = ["png", "jpg", "jpeg", "bmp", "webp", "tiff"]
            let ext = url.pathExtension.lowercased()
            
            if safeExtensions.contains(ext) {
                print("Format '\(ext)' is safe for backend.")
                self.inputImagePath = url.path
            } else {
                print("Source format '\(ext)' requires conversion for backend...")
                self.saveImageForBackend(image: image)
            }
        }
    }
    
    private func saveImageForBackend(image: NSImage) {
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("backend_working_copy.png")
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: tempFile)
                print("Saved backend working copy: \(tempFile.path)")
                self.inputImagePath = tempFile.path
            }
        } catch {
            print("Failed to save converting image: \(error.localizedDescription)")
            self.env.status = "Error: conversion failed"
        }
    }
    
    func handleTap(at location: CGPoint, in size: CGSize) {
        guard let inputImage = inputImage, let path = inputImagePath else { return }

        // Get pixel dimensions (not point dimensions) for accurate coordinate mapping
        // We must account for EXIF orientation as the Python backend uses exif_transpose
        let pixelSize = getOrientedPixelSize(inputImage)
        let pixelWidth = pixelSize.width
        let pixelHeight = pixelSize.height

        // Use point dimensions for aspect ratio calculation (matches SwiftUI's .fit behavior)
        let imageSize = inputImage.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return }
        
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

        guard relativeX >= 0, relativeX <= 1, relativeY >= 0, relativeY <= 1 else {
            print("Click outside image bounds: relative=(\(relativeX), \(relativeY))")
            return
        }

        // Map to pixel coordinates for Python backend
        let targetX = Int(relativeX * pixelWidth)
        let targetY = Int(relativeY * pixelHeight)

        // Debug logging
        print("=== Coordinate Debug ===")
        print("Container size: \(size)")
        print("Image size (points): \(imageSize)")
        print("Oriented Pixel dimensions: \(pixelWidth)x\(pixelHeight)")
        print("Displayed size: \(displayedWidth)x\(displayedHeight)")
        print("Click location (in container): \(location)")
        print("Relative position: (\(relativeX), \(relativeY))")
        print("Target pixel coords: (\(targetX), \(targetY))")
        print("========================")
        
        Task {
            if let maskURL = await env.runSAM2(imagePath: path, x: targetX, y: targetY) {
                if let newMask = NSImage(contentsOf: maskURL) {
                    self.maskImage = newMask
                }
            }
        }
    }

    private func getOrientedPixelSize(_ image: NSImage) -> CGSize {
        guard let rep = image.representations.first else {
            return image.size
        }
        
        let pW = CGFloat(rep.pixelsWide)
        let pH = CGFloat(rep.pixelsHigh)
        
        // If pixels are not defined, fallback to size
        guard pW > 0, pH > 0 else { return image.size }
        
        let sW = image.size.width
        let sH = image.size.height
        
        // Check if the orientation has swapped aspect ratios
        let pointsRatio = sW / sH
        let pixelsRatio = pW / pH
        let invertedPixelsRatio = pH / pW
        
        if abs(pointsRatio - invertedPixelsRatio) < abs(pointsRatio - pixelsRatio) {
            // Orientation likely swapped width and height (e.g. 90 or 270 deg rotation)
            return CGSize(width: pH, height: pW)
        } else {
            return CGSize(width: pW, height: pH)
        }
    }
}
