# Architecture Documentation

ModelrV3 follows a clean architecture pattern with clear separation of concerns, organized in layers from UI to infrastructure. This document describes the overall architecture, component organization, and data flow.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Presentation Layer                           │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                     SwiftUI Views                             │  │
│  │  - MainEditorView                                           │  │
│  │  - SplashScreenView                                          │  │
│  │  - ContentView (Editor)                                       │  │
│  │  - ModelViewer                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Business Logic                             │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                      App Store (TCA)                         │  │
│  │  - AppState                                                 │  │
│  │  - AppAction                                                │  │
│  │  - AppReducer                                               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    ViewModels                               │  │
│  │  - ContentViewModel                                        │  │
│  │  - PythonEnvironment (ObservableObject)                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Service Layer                              │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                  Service Protocols                            │  │
│  │  - FileServiceProtocol                                      │  │
│  │  - ImageProcessingServiceProtocol                            │  │
│  │  - PythonServiceProtocol                                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │               Service Implementations                         │  │
│  │  - FileService                                             │  │
│  │  - ImageProcessingService                                   │  │
│  │  - PythonService (via PythonEnvironment)                    │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Infrastructure Layer                          │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    External Systems                          │  │
│  │  - SAM2 Python Worker (stdin/stdout)                        │  │
│  │  - Hunyuan3D CLI (one-shot)                                │  │
│  │  - File System                                              │  │
│  │  - macOS APIs (Metal, SceneKit)                             │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### Presentation Layer

**Location:** `ModelrV3/Features/`

**Responsibilities:**
- User interface rendering
- User input handling
- State display

**Key Components:**

| Component | Purpose | Key Features |
|-----------|---------|--------------|
| `SplashScreenView` | Setup wizard and self-test | Progress tracking, interactive testing |
| `MainEditorView` | Primary editing interface | Tool selection, tab navigation |
| `ContentView` | Image editor workspace | Zoomable image, overlay rendering |
| `GenerateTabView` | 3D generation controls | Parameter tuning, progress display |
| `PreprocessTabView` | Image preprocessing | Crop, lasso-delete tools |
| `SegmentTabView` | Segmentation controls | Tool selection, mask display |
| `ModelViewer` | 3D model viewer | SceneKit integration |
| `ZoomableScrollView` | Pan/zoom container | Coordinate transformation |

### State Management

**Pattern:** TCA (The Composable Architecture) - Simplified

**Location:** `ModelrV3/Core/Store/`

**Key Components:**

**AppState:**
```swift
struct AppState {
    var image: ImageState        // Image data and dimensions
    var selection: SelectionState // Points, boxes, lassos, strokes
    var tool: ToolState         // Current tool selection
    var generation: GenerationState // 3D generation status
    var ui: UIState             // UI preferences and visibility
}
```

**AppAction:**
```swift
enum AppAction {
    case image(ImageAction)
    case selection(SelectionAction)
    case tool(ToolAction)
    case generation(GenerationAction)
    case ui(UIAction)
}
```

**AppReducer:**
```swift
func appReducer(state: inout AppState, action: AppAction) -> Void {
    switch action {
    case .image(let action):
        imageReducer(&state.image, action)
    case .selection(let action):
        selectionReducer(&state.selection, action)
    // ...
    }
}
```

**Benefits:**
- Unidirectional data flow
- Predictable state changes
- Easy to test
- Debuggable (action logs)

### Service Layer

**Pattern:** Protocol-Oriented Dependency Injection

**Location:** `ModelrV3/Core/Services/`

**Protocols:**

```swift
protocol FileServiceProtocol {
    func saveImage(_ image: NSImage, to url: URL) throws
    func loadImage(from url: URL) throws -> NSImage
}

protocol ImageProcessingServiceProtocol {
    func cropImage(_ image: NSImage, to rect: CGRect) -> NSImage?
    func deleteInsideLasso(_ image: NSImage, lasso: LassoSelection) -> NSImage?
    func applyStrokesToMask(_ mask: NSImage, strokes: [PaintStroke]) -> NSImage
}

protocol PythonServiceProtocol {
    func setImage(path: String) async throws -> CGSize
    func predict(points: [SAMPoint], box: SAMBox?, imageSize: CGSize) async throws -> URL
    func generate3DModel(imagePath: String, maskPath: String, ...) async
}
```

**Dependency Injection:**

```swift
class ServiceContainer {
    static let shared = ServiceContainer()

    let fileService: FileServiceProtocol
    let imageProcessingService: ImageProcessingServiceProtocol
    let pythonService: PythonServiceProtocol

    init() {
        self.fileService = FileService()
        self.imageProcessingService = ImageProcessingService()
        self.pythonService = PythonEnvironment()
    }
}
```

**Benefits:**
- Testable (mock implementations)
- Swappable implementations
- Clear contracts
- Decoupled components

### Python Integration Layer

**Location:** `ModelrV3/Core/Services/Implementations/PythonEnvironment.swift`

**Architecture:**

```
┌─────────────────────────────────────────────────────────────┐
│              PythonEnvironment (ObservableObject)            │
│                                                             │
│  @Published Properties:                                      │
│  - isSetup, status, canProceed                             │
│  - selfTestImage, selfTestMask, selfTest3DModelURL        │
│  - selectedModel, isProcessing, hunyuanProgress             │
│                                                             │
│  Public API:                                                │
│  - setup() async                                            │
│  - setImage(path:) async throws -> CGSize                    │
│  - predict(points:box:imageSize:) async throws -> URL        │
│  - generate3DModel(...) async                               │
│  - resetPredictor() async throws                             │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ JSON Protocol
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              Persistent Python Worker Process                 │
│                                                             │
│  Lifecycle:                                                 │
│  1. Start (uv run --server)                                │
│  2. Load SAM2 model (~3s)                                   │
│  3. Send "ready" signal                                     │
│  4. Loop:                                                   │
│     - Read JSON from stdin                                   │
│     - Execute command (set_image, predict, reset)            │
│     - Write JSON to stdout                                   │
│  5. Shutdown on SIGTERM                                     │
└─────────────────────────────────────────────────────────────┘
```

**Communication Pattern:**

```
Swift App                    Python Worker
   │                              │
   ├─ SAMRequest ────────────────>│
   │  (JSON over stdin)            │
   │                              │
   │                              ├─ Parse JSON
   │                              ├─ Validate
   │                              ├─ Execute command
   │                              ├─ Generate mask
   │                              └─ Build response
   │                              │
   │<── SAMResponse ──────────────┤
   │  (JSON over stdout)           │
```

## Data Flow

### Image Segmentation Flow

```
1. User loads image
   ├─> ImagePicker (SwiftUI)
   ├─> ImageAction.setImage
   └─> AppState.image.path updated

2. User selects tool (point, box, lasso, or paint)
   ├─> ToolAction.selectTool
   └─> AppState.tool.currentTool updated

3. User interacts with image
   ├─> ZoomableScrollView gesture handler
   ├─> Convert view coords → normalized coords
   ├─> SelectionAction.addPoint/addBox/addLasso/addStroke
   └─> AppState.selection updated

4. Trigger prediction
   ├─> PythonEnvironment.predict()
   │   ├─> Convert normalized → pixel coords
   │   ├─> Create SAMRequest
   │   ├─> Send via stdin to Python worker
   │   │
   │   └─ Python worker:
   │       ├─> Parse JSON request
   │       ├─> Run SAM2 inference
   │       ├─> Save mask to file
   │       └─> Send SAMResponse via stdout
   │
   └─> Receive SAMResponse
       ├─> Load mask image from path
       ├─> ImageAction.setMask
       └─> AppState.image.maskURL updated
```

### 3D Generation Flow

```
1. User clicks "Generate 3D Model"
   ├─> GenerationAction.startGeneration
   └─> AppState.generation.status = .generating

2. Validate prerequisites
   ├─> Check mask exists
   ├─> Check image exists
   └─> Check Hunyuan environment ready

3. Prepare data
   ├─> Get image path
   ├─> Get mask path
   └─> Generate unique output filename

4. Spawn Hunyuan3D process
   ├─> uv run hunyuan_wrapper.py
   ├─> Arguments: --image, --mask, --output, --steps, --resolution
   └─> Run in background (async)

5. Monitor progress
   ├─> Parse stdout from Hunyuan
   ├─> Extract stage, percentage, steps, speed
   ├─> Update AppState.generation.progress
   └─> UI shows progress bar

6. Process complete
   ├─> Check exit code (0 = success)
   ├─> Load 3D model file (.obj)
   ├─> GenerationAction.setModelURL
   └─> Show in ModelViewer

7. Error handling
   ├─> Check process.exitStatus
   ├─> Parse stderr for error messages
   ├─> GenerationAction.setError
   └─> Show error alert
```

### Self-Test Flow

```
1. Setup phase
   ├─> Download SAM2 checkpoint
   ├─> Start persistent worker
   ├─> Download Hunyuan3D model
   └─> Warmup Hunyuan pipeline

2. Image set
   ├─> Load self_test.jpg
   ├─> PythonEnvironment.setImage()
   └─> Ready for interaction

3. User clicks on test image
   ├─> Capture click location (normalized)
   ├─> PythonEnvironment.runSelfTestWithClick()
   │
   │   ├─> SAM2.predict(click_point)
   │   │   └─> Generate mask
   │   │
   │   ├─> Compare with reference mask
   │   │   ├─> Load correct_self_test_mask.png
   │   │   ├─> Compute Jaccard similarity
   │   │   └─> Check >= 90% threshold
   │   │
   │   └─> If similarity >= 90%:
   │       ├─> Run Hunyuan3D generation
   │       │   └─> Generate self_test_model.obj
   │       └─> Set canProceed = true
   │
   └─> If similarity < 90%:
       └─> Ask user to retry

4. Display results
   ├─> Show generated mask overlay
   ├─> Show 3D model preview
   └─> Enable "Open Editor" button
```

## Design Patterns Used

### 1. Repository Pattern

**Purpose:** Abstract data access

**Example:**
```swift
protocol FileServiceProtocol {
    func saveImage(_ image: NSImage, to url: URL) throws
    func loadImage(from url: URL) throws -> NSImage
}

class FileService: FileServiceProtocol {
    func saveImage(_ image: NSImage, to url: URL) throws {
        // Implementation...
    }
}
```

### 2. Factory Pattern

**Purpose:** Create objects with proper initialization

**Example:**
```swift
struct SAMPoint {
    let normalizedCoords: CGPoint
    let id = UUID()
    let dateAdded = Date()

    private init(normalizedCoords: CGPoint) {
        self.normalizedCoords = normalizedCoords
    }

    static func fromView(point: CGPoint, viewSize: CGSize) -> SAMPoint {
        let normalized = point.toNormalized(viewSize)
        return SAMPoint(normalizedCoords: normalized)
    }
}
```

### 3. Strategy Pattern

**Purpose:** Swap algorithms based on selection

**Example:**
```swift
enum SAMTool: String {
    case point, boundingBox, lasso, paint

    func handler() -> ToolHandlerProtocol {
        switch self {
        case .point: return PointToolHandler()
        case .boundingBox: return BoxToolHandler()
        case .lasso: return LassoToolHandler()
        case .paint: return PaintToolHandler()
        }
    }
}
```

### 4. Observer Pattern

**Purpose:** React to state changes

**Example:**
```swift
@MainActor
class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Ready"
    @Published var hunyuanProgress = ""
    // Views automatically update when these change
}
```

### 5. Command Pattern

**Purpose:** Encapsulate actions

**Example:**
```swift
enum AppAction {
    case image(ImageAction)
    case selection(SelectionAction)
    case tool(ToolAction)
}

enum ImageAction {
    case setImage(URL)
    case setMask(URL)
    case clearMask
}
```

## Directory Structure

```
ModelrV3/
├── ModelrV3/
│   ├── App/
│   │   └── ModelrV3App.swift              # App entry point
│   │
│   ├── Core/
│   │   ├── Constants/
│   │   │   └── AppConstants.swift         # Global constants
│   │   │
│   │   ├── Errors/
│   │   │   └── AppError.swift            # Error types
│   │   │
│   │   ├── Logging/
│   │   │   └── SecureLogger.swift        # Secure logging
│   │   │
│   │   ├── Models/
│   │   │   ├── CommonModels.swift        # Shared models
│   │   │   └── Models.swift              # SAM models
│   │   │
│   │   ├── Security/
│   │   │   ├── PathValidator.swift        # Path validation
│   │   │   └── SecureFileManager.swift    # Secure file ops
│   │   │
│   │   ├── Services/
│   │   │   ├── DependencyInjection/
│   │   │   │   └── ServiceContainer.swift # DI container
│   │   │   │
│   │   │   ├── Implementations/
│   │   │   │   ├── FileService.swift
│   │   │   │   ├── ImageProcessingService.swift
│   │   │   │   └── PythonEnvironment.swift
│   │   │   │
│   │   │   ├── Protocols/
│   │   │   │   ├── FileServiceProtocol.swift
│   │   │   │   ├── ImageProcessingServiceProtocol.swift
│   │   │   │   └── PythonServiceProtocol.swift
│   │   │   │
│   │   │   └── SafeFileService.swift
│   │   │
│   │   ├── Store/
│   │   │   ├── AppAction.swift            # Actions
│   │   │   ├── AppReducer.swift           # Reducer
│   │   │   ├── AppState.swift             # State
│   │   │   └── AppStore.swift            # Store
│   │   │
│   │   └── Utilities/
│   │       ├── PathManager.swift
│   │       ├── ProgressParser.swift        # Progress parsing
│   │       └── TimeFormatter.swift       # Time formatting
│   │
│   ├── Features/
│   │   ├── Editor/
│   │   │   ├── ViewModels/
│   │   │   │   └── ContentViewModel.swift
│   │   │   │
│   │   │   └── Views/
│   │   │       ├── TabViews/
│   │   │       │   ├── GenerateTabView.swift
│   │   │       │   ├── PreprocessTabView.swift
│   │   │       │   └── SegmentTabView.swift
│   │   │       │
│   │   │       ├── BoundingBoxOverlay.swift
│   │   │       ├── ContentView.swift
│   │   │       ├── ImageAreaView.swift
│   │   │       ├── LassoOverlay.swift
│   │   │       ├── MainEditorView.swift
│   │   │       ├── PaintStrokeOverlay.swift
│   │   │       ├── PointsOverlay.swift
│   │   │       ├── SidebarView.swift
│   │   │       └── ZoomableScrollView.swift
│   │   │
│   │   ├── Model3D/
│   │   │   └── Views/
│   │   │       └── ModelViewer.swift
│   │   │
│   │   └── Setup/
│   │       └── Views/
│   │           └── SplashScreenView.swift
│   │
│   └── Views/ (legacy, migrating to Features/)
│       ├── ContentView.swift
│       ├── PythonEnvironment.swift
│       ├── SplashScreenView.swift
│       └── ...
│
├── Resources/
│   ├── sam_wrapper.py                  # SAM2 Python wrapper
│   ├── hunyuan_wrapper.py             # Hunyuan3D wrapper
│   ├── pyproject.toml                # SAM2 dependencies
│   ├── pyproject_hunyuan.toml        # Hunyuan dependencies
│   ├── config.py                     # Configuration
│   ├── device_utils.py               # Device utilities
│   ├── logging_config.py             # Logging setup
│   ├── self_test.jpg                 # Self-test image
│   └── correct_self_test_mask.png     # Reference mask
│
├── ModelrV3Tests/
│   ├── Helpers/
│   │   ├── MockFileSystem.swift
│   │   ├── MockPythonService.swift
│   │   ├── TestDataGenerator.swift
│   │   └── TestHelpers.swift
│   │
│   └── [Test Files]
│
├── docs/
│   ├── CoordinateSystems.md
│   ├── PythonProtocol.md
│   ├── Architecture.md
│   ├── SelfTest.md
│   ├── ColorScheme.md
│   └── API.md
│
├── CONTRIBUTING.md
├── Makefile
├── project.yml
└── README.md
```

## Security Architecture

### Path Validation

**Location:** `ModelrV3/Core/Security/PathValidator.swift`

**Protection:**
- Path traversal prevention
- File extension validation
- Sandbox compliance

### File Access

**Location:** `ModelrV3/Core/Security/SecureFileManager.swift`

**Protection:**
- Scoped file access
- Secure temporary file handling
- Automatic cleanup

### Python Isolation

**Approach:**
- Python runs in separate process
- Communication via stdin/stdout only
- No direct memory sharing
- Environment variable scoping

## Performance Considerations

### Lazy Loading

**Pattern:**
- Python models loaded on-demand
- UI components created lazily
- Resources loaded incrementally

### Caching

**Strategy:**
- Python worker cached (persistent mode)
- Model checkpoints cached locally
- Generated models cached

### Async/Await

**Usage:**
- All Python operations async
- Non-blocking UI
- Proper error handling

## Testing Strategy

### Unit Tests

**Coverage:**
- Coordinate transformations
- State reducers
- Service implementations
- Utility functions

### Integration Tests

**Coverage:**
- Python-Swift communication
- End-to-end workflows
- Self-test validation

### Test Helpers

**Location:** `ModelrV3Tests/Helpers/`

**Components:**
- `MockFileSystem` - File system mocking
- `MockPythonService` - Python service mocking
- `TestDataGenerator` - Test data creation

## Best Practices

1. **Protocol-Oriented Design:** Define interfaces before implementations
2. **Dependency Injection:** Inject dependencies, don't instantiate directly
3. **Error Handling:** Use typed errors, handle at appropriate layers
4. **State Management:** Single source of truth, unidirectional flow
5. **Testing:** Write tests alongside code
6. **Documentation:** Document protocols, APIs, and complex algorithms
7. **Security:** Validate all inputs, sanitize paths
8. **Performance:** Profile before optimizing, use async operations

## Related Files

- `ModelrV3/Core/Store/AppStore.swift` - State management
- `ModelrV3/Core/Services/Implementations/PythonEnvironment.swift` - Python integration
- `docs/CoordinateSystems.md` - Coordinate system details
- `docs/PythonProtocol.md` - Communication protocol
