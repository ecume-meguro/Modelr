# API Documentation

This document describes the public API of ModelrV3 for developers who want to integrate or extend functionality.

## Table of Contents

- [Core Models](#core-models)
- [State Management](#state-management)
- [Python Integration](#python-integration)
- [Image Processing](#image-processing)
- [Coordinate Systems](#coordinate-systems)
- [Common Patterns](#common-patterns)

## Core Models

### SAMPoint

Represents a point annotation for segmentation.

```swift
struct SAMPoint: Hashable, Identifiable {
    let id: UUID
    let normalizedCoords: CGPoint  // 0-1 range, relative to image
    let dateAdded: Date

    /// Convert normalized coords to pixel coords for Python backend
    /// - Parameter imageSize: Size of the target image
    /// - Returns: Tuple of (x, y) pixel coordinates
    func pixelCoords(for imageSize: CGSize) -> (x: Int, y: Int)
}
```

**Example:**

```swift
// Create point at center of image
let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))

// Convert to pixel coordinates for 1920x1080 image
let pixels = point.pixelCoords(for: CGSize(width: 1920, height: 1080))
// Result: (960, 540)
```

### SAMBox

Represents a bounding box annotation.

```swift
struct SAMBox: Hashable, Identifiable {
    let id: UUID
    var startPoint: CGPoint  // Normalized 0-1
    var endPoint: CGPoint    // Normalized 0-1
    let dateAdded: Date

    /// Normalized rectangle (handles inverted drag directions)
    var normalizedRect: CGRect { get }

    /// Convert to pixel coords for Python backend [x1, y1, x2, y2]
    /// - Parameter imageSize: Size of the target image
    /// - Returns: Array of [x1, y1, x2, y2] pixel coordinates
    func pixelBox(for imageSize: CGSize) -> [Int]

    /// Check if box has meaningful size (> 1% of image in both dimensions)
    var isValid: Bool { get }
}
```

**Example:**

```swift
// Create box from top-left to bottom-right
let box = SAMBox(startPoint: CGPoint(x: 0.25, y: 0.25),
                 endPoint: CGPoint(x: 0.75, y: 0.75))

// Check if valid
if box.isValid {
    // Use box
}

// Convert to pixel coordinates
let pixelBox = box.pixelBox(for: CGSize(width: 1920, height: 1080))
// Result: [480, 270, 1440, 810]
```

### LassoSelection

Represents a freehand polygon selection.

```swift
struct LassoSelection: Identifiable {
    let id: UUID
    var points: [CGPoint]  // Normalized 0-1 coordinates
    let dateAdded: Date

    /// Initialize with starting point
    /// - Parameter startPoint: First point of the lasso
    init(startPoint: CGPoint)

    /// Add a point to the lasso (filters by minimum distance)
    mutating func addPoint(_ point: CGPoint)

    /// Get bounding box of the lasso selection (for SAM2)
    var boundingBox: SAMBox? { get }

    /// Check if lasso has enough points to be valid
    var isValid: Bool { get }
}
```

**Example:**

```swift
// Start lasso selection
var lasso = LassoSelection(startPoint: CGPoint(x: 0.3, y: 0.3))

// Add points
lasso.addPoint(CGPoint(x: 0.5, y: 0.2))
lasso.addPoint(CGPoint(x: 0.7, y: 0.4))
lasso.addPoint(CGPoint(x: 0.5, y: 0.6))

// Check if valid (needs at least 3 points)
if lasso.isValid {
    let bbox = lasso.boundingBox
    // Use bounding box...
}
```

### PaintStroke

Represents a brush stroke for manual mask editing.

```swift
struct PaintStroke: Identifiable {
    let id: UUID
    var points: [CGPoint]  // Normalized 0-1 coordinates
    let brushSize: CGFloat  // Normalized brush size (relative to image width)
    let isErasing: Bool     // true = erase, false = add to mask

    /// Initialize with starting point
    /// - Parameters:
    ///   - startPoint: First point of the stroke
    ///   - brushSize: Brush size as fraction of image width (0-1)
    ///   - isErasing: If true, removes from mask; if false, adds to mask
    init(startPoint: CGPoint, brushSize: CGFloat, isErasing: Bool = false)

    /// Add a point to the stroke (filters by minimum distance)
    mutating func addPoint(_ point: CGPoint)
}
```

**Example:**

```swift
// Create stroke with 5% brush size
var stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5),
                        brushSize: 0.05,
                        isErasing: false)

// Add points
stroke.addPoint(CGPoint(x: 0.55, y: 0.5))
stroke.addPoint(CGPoint(x: 0.6, y: 0.5))
```

## State Management

### AppStore

Central store for application state using TCA pattern.

```swift
@MainActor
class AppStore: ObservableObject {
    @Published private(set) var state: AppState

    /// Initialize store with optional custom reducer
    /// - Parameters:
    ///   - initialState: Initial state
    ///   - reducer: Custom reducer (defaults to appReducer)
    init(initialState: AppState = AppState(),
         reducer: @escaping (inout AppState, AppAction) -> Void = appReducer)

    /// Dispatch an action to update state
    /// - Parameter action: Action to dispatch
    func send(_ action: AppAction)

    /// Dispatch multiple actions sequentially
    /// - Parameter actions: Array of actions to dispatch
    func send(_ actions: [AppAction])
}
```

**Example:**

```swift
// Get shared store
let store = AppStore.shared

// Dispatch action
store.send(.image(.setImage(imageURL)))

// Check state
let currentImage = store.state.image.path
```

### Common Actions

```swift
// Image actions
store.send(.image(.setImage(url)))
store.send(.image(.setMask(url)))
store.send(.image(.clearMask))

// Selection actions
store.send(.selection(.addPoint(point)))
store.send(.selection(.addBox(box)))
store.send(.selection(.clearSelection))

// Tool actions
store.send(.tool(.selectTool(.point)))
store.send(.tool(.setBrushSize(0.05)))

// Generation actions
store.send(.generation(.startGeneration))
store.send(.generation(.setProgress("Loading model...")))
```

## Python Integration

### PythonEnvironment

Main interface for Python backend communication.

```swift
@MainActor
class PythonEnvironment: ObservableObject {
    // Published properties for SwiftUI binding
    @Published var isSetup = false
    @Published var status = "Ready"
    @Published var selectedModel = "base_plus"
    @Published var isProcessing = false
    @Published var hunyuanProgress = ""

    // Self-test properties
    @Published var selfTestImage: NSImage?
    @Published var selfTestMask: NSImage?
    @Published var selfTest3DModelURL: URL?
    @Published var canProceed = false

    /// Initialize Python environment
    init()

    /// Setup environment and download models
    func setup() async

    /// Set the current image for segmentation
    /// - Parameter path: Path to image file
    /// - Returns: Size of the loaded image
    /// - Throws: PythonError if image fails to load
    func setImage(path: String) async throws -> CGSize

    /// Run segmentation prediction
    /// - Parameters:
    ///   - points: Array of SAMPoint annotations
    ///   - box: Optional SAMBox annotation
    ///   - imageSize: Size of the image
    /// - Returns: URL to generated mask file
    /// - Throws: PythonError if prediction fails
    func predict(points: [SAMPoint],
               box: SAMBox?,
               imageSize: CGSize) async throws -> URL

    /// Reset the predictor state (clears current image)
    /// - Throws: PythonError if reset fails
    func resetPredictor() async throws

    /// Generate 3D model from masked image
    /// - Parameters:
    ///   - imagePath: Path to original image
    ///   - maskPath: Path to segmentation mask
    ///   - steps: Number of diffusion steps (default: 50)
    ///   - resolution: Mesh resolution (default: 512)
    ///   - progress: Progress callback
    ///   - completion: Completion handler with result
    func generate3DModel(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async
}
```

**Example Usage:**

```swift
let pythonEnv = PythonEnvironment()

// Setup (downloads models)
await pythonEnv.setup()

// Set image
let imageSize = try await pythonEnv.setImage(path: "/path/to/image.jpg")

// Predict with point
let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))
let maskURL = try await pythonEnv.predict(points: [point],
                                       box: nil,
                                       imageSize: imageSize)

// Load and display mask
let maskImage = NSImage(contentsOf: maskURL)

// Generate 3D model
await pythonEnv.generate3DModel(
    imagePath: "/path/to/image.jpg",
    maskPath: maskURL.path,
    steps: 50,
    resolution: 512,
    progress: { status in
        print("Progress: \(status)")
    },
    completion: { result in
        switch result {
        case .success(let modelURL):
            print("3D model saved to: \(modelURL)")
        case .failure(let error):
            print("Error: \(error)")
        }
    }
)
```

## Image Processing

### ImageProcessingService

Provides image manipulation operations.

```swift
class ImageProcessingService: ImageProcessingServiceProtocol {
    /// Crop image to specified rectangle
    /// - Parameters:
    ///   - image: Source image
    ///   - rect: Rectangle to crop (in image coordinates)
    /// - Returns: Cropped image or nil on failure
    func cropImage(_ image: NSImage, to rect: CGRect) -> NSImage?

    /// Delete pixels inside a lasso selection
    /// - Parameters:
    ///   - image: Source image
    ///   - lasso: LassoSelection defining region to delete
    /// - Returns: Modified image or nil on failure
    func deleteInsideLasso(_ image: NSImage, lasso: LassoSelection) -> NSImage?

    /// Apply paint strokes to a mask
    /// - Parameters:
    ///   - mask: Source mask image (RGBA)
    ///   - strokes: Array of PaintStroke to apply
    /// - Returns: Modified mask with strokes applied
    func applyStrokesToMask(_ mask: NSImage, strokes: [PaintStroke]) -> NSImage
}
```

**Example:**

```swift
let imageService = ImageProcessingService()

// Crop image
let cropRect = CGRect(x: 100, y: 100, width: 500, height: 500)
let cropped = imageService.cropImage(originalImage, to: cropRect)

// Delete with lasso
let lasso = LassoSelection(startPoint: CGPoint(x: 0.2, y: 0.2))
// ... add points ...
let withHole = imageService.deleteInsideLasso(originalImage, lasso: lasso)

// Apply strokes to mask
let stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5),
                        brushSize: 0.05,
                        isErasing: false)
let modifiedMask = imageService.applyStrokesToMask(mask, strokes: [stroke])
```

## Coordinate Systems

### Coordinate Conversions

```swift
extension CGPoint {
    /// Convert normalized (0-1) coords to view coords
    /// - Parameter viewSize: Size of the view
    /// - Returns: Point in view coordinates
    func toViewCoords(_ viewSize: CGSize) -> CGPoint

    /// Convert view coords to normalized (0-1) coords
    /// - Parameter viewSize: Size of the view
    /// - Returns: Point in normalized coordinates
    func toNormalized(_ viewSize: CGSize) -> CGPoint

    /// Clamp to 0-1 range
    var clamped: CGPoint { get }
}
```

**Example:**

```swift
let viewSize = CGSize(width: 800, height: 600)

// Convert view tap to normalized
let tapInView = CGPoint(x: 400, y: 300)
let normalized = tapInView.toNormalized(viewSize)
// Result: (0.5, 0.5)

// Convert back to view
let viewPoint = normalized.toViewCoords(viewSize)
// Result: (400, 300)

// Clamp out-of-bounds point
let outOfBounds = CGPoint(x: 1.5, y: -0.2)
let clamped = outOfBounds.clamped
// Result: (1.0, 0.0)
```

## Common Patterns

### Error Handling

All Python operations throw typed errors:

```swift
do {
    let maskURL = try await pythonEnv.predict(points: [point],
                                         box: nil,
                                         imageSize: imageSize)
    // Use mask...
} catch PythonError.workerNotRunning {
    print("Worker not running, starting...")
    try await pythonEnv.startPersistentWorker()
} catch PythonError.predictionFailed(let errorMsg) {
    print("Prediction failed: \(errorMsg)")
} catch PythonError.timeout {
    print("Request timed out")
} catch {
    print("Unexpected error: \(error)")
}
```

### Observing State

Use `@Published` properties for reactive UI:

```swift
struct MyView: View {
    @StateObject var pythonEnv = PythonEnvironment()

    var body: some View {
        VStack {
            if pythonEnv.isProcessing {
                ProgressView("Processing...")
                Text(pythonEnv.status)
            } else {
                Text("Ready")
                Button("Generate") {
                    // Start generation...
                }
            }
        }
    }
}
```

### Coordinate Conversion Pattern

Standard pattern for handling user interactions:

```swift
func handleTap(at location: CGPoint, in view: CGSize) {
    // Convert to normalized
    let normalized = location.toNormalized(view)

    // Clamp to valid range
    let clamped = normalized.clamped

    // Store as normalized point
    let point = SAMPoint(normalizedCoords: clamped)

    // Predict (conversion to pixels happens inside)
    Task {
        let maskURL = try await pythonEnv.predict(points: [point],
                                              box: nil,
                                              imageSize: imageSize)
        // Use mask...
    }
}
```

## Best Practices

1. **Store as Normalized:** Always store annotations in normalized coordinates
2. **Convert at Boundaries:** Convert to other coordinate systems only when needed
3. **Handle Errors:** Always catch and handle potential errors
4. **Observe State:** Use `@Published` properties for reactive updates
5. **Async Operations:** Use `await` for all Python operations
6. **Validate Input:** Check for valid coordinates, file existence, etc.

## Related Documentation

- `docs/CoordinateSystems.md` - Detailed coordinate system documentation
- `docs/PythonProtocol.md` - Python-Swift communication protocol
- `docs/Architecture.md` - Overall architecture details
