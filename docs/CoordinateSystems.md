# Coordinate Systems in ModelrV3

ModelrV3 uses multiple coordinate systems throughout the application to handle different contexts (user interaction, image processing, and model inference). Understanding these systems and their transformations is crucial for working with the codebase.

## Overview

ModelrV3 operates with three distinct coordinate systems:

1. **Normalized Coordinates** (0-1 range) - Device-independent, image-relative
2. **Pixel Coordinates** - Absolute pixel positions in the image
3. **View Coordinates** - Pixel positions in the SwiftUI view (may differ from image due to zooming)

```
User Interaction (View) → Normalized → Image Processing (Pixel) → Python Backend
        ↓                       ↓                        ↓                    ↓
   SwiftUI View         Model Storage          Image Dimensions      SAM2/Hunyuan
```

## Coordinate System Details

### 1. Normalized Coordinates (0-1)

**Purpose:** Device-independent storage and model communication

**Range:** `(0.0, 0.0)` to `(1.0, 1.0)` where:
- `(0.0, 0.0)` = top-left corner
- `(1.0, 1.0)` = bottom-right corner

**Used by:**
- `SAMPoint.normalizedCoords`
- `SAMBox.startPoint` and `endPoint`
- `LassoSelection.points`
- `PaintStroke.points`
- `SAMRequest.points` and `box` (after conversion)

**Advantages:**
- Resolution-independent
- Easy to convert to any image size
- Consistent across different zoom levels
- Compact storage (single-precision floats)

**Example:**
```swift
let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.75))
// Point at 50% width, 75% height of image
```

### 2. Pixel Coordinates

**Purpose:** Image file operations and pixel manipulation

**Range:** `(0, 0)` to `(width-1, height-1)` where width/height are image dimensions

**Used by:**
- Python backend (`sam_wrapper.py`)
- Image processing algorithms
- File I/O operations
- Mask generation

**Example:**
```swift
let imageSize = CGSize(width: 1920, height: 1080)
let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))
let pixelCoords = point.pixelCoords(for: imageSize)
// Result: (960, 540) - center of 1920x1080 image
```

### 3. View Coordinates

**Purpose:** SwiftUI rendering and user interaction

**Range:** Depends on view size (may change with zooming)

**Used by:**
- SwiftUI gesture handlers
- Drawing overlays
- User tap/drag events
- On-screen visualizations

**Example:**
```swift
let viewSize = CGSize(width: 800, height: 600)
let normalizedPoint = CGPoint(x: 0.5, y: 0.5)
let viewPoint = normalizedPoint.toViewCoords(viewSize)
// Result: (400, 300) - center of 800x600 view
```

## Conversion Functions

### Normalized → Pixel

```swift
func pixelCoords(for imageSize: CGSize) -> (x: Int, y: Int) {
    (
        x: Int(normalizedCoords.x * imageSize.width),
        y: Int(normalizedCoords.y * imageSize.height)
    )
}

// Usage
let imageSize = CGSize(width: 1000, height: 800)
let normalized = CGPoint(x: 0.75, y: 0.5)
let pixel = normalized.toViewCoords(imageSize)
// Result: (750, 400)
```

### Pixel → Normalized

```swift
func toNormalized(_ viewSize: CGSize) -> CGPoint {
    CGPoint(x: x / viewSize.width, y: y / viewSize.height)
}

// Usage
let viewSize = CGSize(width: 1000, height: 800)
let pixel = CGPoint(x: 750, y: 400)
let normalized = pixel.toNormalized(viewSize)
// Result: (0.75, 0.5)
```

### Normalized → View

```swift
func toViewCoords(_ viewSize: CGSize) -> CGPoint {
    CGPoint(x: x * viewSize.width, y: y * viewSize.height)
}

// Usage
let viewSize = CGSize(width: 400, height: 320)
let normalized = CGPoint(x: 0.75, y: 0.5)
let viewPoint = normalized.toViewCoords(viewSize)
// Result: (300, 160)
```

### View → Normalized

```swift
func toNormalized(_ viewSize: CGSize) -> CGPoint {
    CGPoint(x: x / viewSize.width, y: y / viewSize.height)
}

// Usage
let viewSize = CGSize(width: 400, height: 320)
let viewPoint = CGPoint(x: 300, y: 160)
let normalized = viewPoint.toNormalized(viewSize)
// Result: (0.75, 0.5)
```

## Data Flow Diagram

```
User Click (View Coords)
    │
    ▼
toNormalized() [SwiftUI gesture]
    │
    ▼
Normalized Coords (0-1) [Stored in Models]
    │
    ├─→ toViewCoords() [Drawing Overlays]
    │        ▼
    │    View Coords [On-screen]
    │
    └─→ pixelCoords() [Python Environment]
             ▼
         Pixel Coords [Python Backend]
             ▼
         SAM2/Hunyuan Processing
```

## When to Use Each System

### Use Normalized Coordinates When:
- Storing user annotations (points, boxes, lassos, strokes)
- Communicating with the Python backend (after conversion to pixels)
- Persisting data (resolution-independent)
- Comparing annotations across different image sizes

### Use Pixel Coordinates When:
- Working with the Python backend directly
- Processing images at the pixel level
- Implementing image manipulation algorithms
- Reading/writing image files

### Use View Coordinates When:
- Handling user interactions (taps, drags)
- Drawing overlays in SwiftUI
- Implementing zoom and pan functionality
- Positioning UI elements relative to the view

## Common Pitfalls and Solutions

### Pitfall 1: Incorrect Coordinate Type

**Problem:** Passing pixel coordinates when normalized coordinates are expected.

**Example:**
```swift
// WRONG
let pixel = CGPoint(x: 960, y: 540)
let point = SAMPoint(normalizedCoords: pixel) // Should be normalized

// CORRECT
let normalized = pixel.toNormalized(imageSize)
let point = SAMPoint(normalizedCoords: normalized)
```

**Solution:** Always check the expected coordinate type in function signatures and convert accordingly.

### Pitfall 2: Mixing Image and View Sizes

**Problem:** Using view size for pixel coordinate conversion when you should use image size.

**Example:**
```swift
// WRONG - using view size for pixel conversion
let pixel = normalizedPoint.toViewCoords(viewSize)

// CORRECT - using image size for pixel conversion
let pixel = normalizedPoint.toViewCoords(imageSize)
```

**Solution:** Distinguish between `imageSize` (actual image dimensions) and `viewSize` (visible SwiftUI view dimensions, may be zoomed).

### Pitfall 3: Not Handling Edge Cases

**Problem:** Coordinates outside the 0-1 range causing unexpected behavior.

**Example:**
```swift
// Coordinates outside valid range
let point = CGPoint(x: 1.5, y: -0.2)
let pixel = point.toViewCoords(imageSize) // Returns (-40, -160) - unexpected!
```

**Solution:** Use the `clamped` property to ensure coordinates stay within bounds:

```swift
let point = CGPoint(x: 1.5, y: -0.2)
let clamped = point.clamped // (1.0, 0.0)
```

### Pitfall 4: Loss of Precision

**Problem:** Multiple conversions causing precision loss.

**Example:**
```swift
let original = CGPoint(x: 0.123456789, y: 0.987654321)
let pixel = original.toViewCoords(CGSize(width: 1000, height: 1000))
let back = pixel.toNormalized(CGSize(width: 1000, height: 1000))
// back might be slightly different from original
```

**Solution:** Minimize conversions and store in normalized form for persistence.

### Pitfall 5: Aspect Ratio Changes

**Problem:** Non-square images causing distortion when not accounting for aspect ratio.

**Example:**
```swift
let imageSize = CGSize(width: 1920, height: 1080) // 16:9
let viewSize = CGSize(width: 400, height: 400) // 1:1

// Point appears stretched if not accounting for aspect ratio
let point = CGPoint(x: 0.5, y: 0.5)
let viewPoint = point.toViewCoords(viewSize) // (200, 200)
// But should be centered on visible portion of image
```

**Solution:** Calculate the visible image area in the view and apply proper scaling based on aspect ratio.

## Test Coverage

Coordinate transformations have comprehensive test coverage in `ModelrV3Tests/CoordinateTests.swift`:

- Normalized to pixel conversions (basic, edge cases, large images)
- Pixel to normalized conversions (basic, edge cases, non-square)
- Round-trip conversions (ensure reversibility)
- Clamping behavior
- Precision tests (small/large coordinates)
- Aspect ratio handling

Run tests with:
```bash
make test
```

## Best Practices

1. **Store as Normalized:** Always store user annotations in normalized coordinates (0-1 range)

2. **Convert at Boundaries:** Convert to/from other coordinate systems only at the boundaries where needed (e.g., when sending to Python or drawing in SwiftUI)

3. **Document Expectations:** Clearly document which coordinate system each function expects in comments

4. **Validate Input:** Validate coordinate ranges before processing (use `clamped` property)

5. **Handle Edge Cases:** Account for images with different aspect ratios and sizes

6. **Test Conversions:** Write tests for any new coordinate conversion logic

7. **Be Consistent:** Use the same conversion patterns throughout the codebase

## Reference Implementation

### Complete Conversion Example

```swift
// User taps at view coordinates (300, 200)
// Image is 1920x1080, view is 600x400 (zoomed to fit)

let viewSize = CGSize(width: 600, height: 400)
let imageSize = CGSize(width: 1920, height: 1080)

// Step 1: Convert view tap to normalized
let tapInView = CGPoint(x: 300, y: 200)
let normalizedTap = tapInView.toNormalized(viewSize)
// Result: (0.5, 0.5)

// Step 2: Store as normalized
let point = SAMPoint(normalizedCoords: normalizedTap)

// Step 3: Convert to pixels for Python backend
let pixelCoords = point.pixelCoords(for: imageSize)
// Result: (960, 540)

// Step 4: Send to Python (via SAMRequest)
let request = SAMRequest(command: "predict", points: [[pixelCoords.x, pixelCoords.y]])

// Step 5: Draw overlay (convert back to view)
let overlayPoint = normalizedTap.toViewCoords(viewSize)
// Draw at (300, 200) in SwiftUI view
```

## Related Files

- `ModelrV3/Core/Models/Models.swift` - Coordinate system models and extensions
- `ModelrV3/Core/Services/Implementations/PythonEnvironment.swift` - Python communication
- `ModelrV3Tests/CoordinateTests.swift` - Coordinate transformation tests
- `Resources/sam_wrapper.py` - Python backend coordinate handling
