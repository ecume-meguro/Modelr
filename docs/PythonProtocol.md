# Python-Swift Protocol Documentation

ModelrV3 communicates with Python backends (SAM2 for segmentation and Hunyuan3D for 3D generation) using a JSON-based protocol over stdin/stdout. This document describes the complete request/response schema, command types, and communication patterns.

## Overview

The protocol uses line-delimited JSON messages:

```
Swift App                    Python Backend
   │                              │
   ├───── JSON Request ───────────>│
   │                              │
   │<──── JSON Response ───────────┤
   │                              │
   │           ...                │
```

### Communication Modes

1. **Server Mode (Persistent):** Recommended for SAM2. Model stays loaded between requests (~50ms vs ~3s per request)
2. **CLI Mode (One-shot):** Used for Hunyuan3D generation. Spawns new process for each request

## Request Schema

### SAMRequest Structure

```swift
struct SAMRequest: Codable {
    let messageId: String      // Unique identifier for tracking
    let version: String        // Protocol version (currently "1.0")
    let command: String        // Command type
    let imagePath: String?     // Path to image file (for set_image)
    let points: [[Int]]?      // Array of [x, y] pixel coordinates
    let box: [Int]?           // [x1, y1, x2, y2] pixel coordinates
    let model: String?        // Model type ("tiny", "small", "base_plus", "large")
}
```

### Request Validation

Requests are validated before sending:

```swift
try request.validate()
```

**Validation Rules:**
- Command must be one of: `"set_image"`, `"predict"`, `"reset"`, `"health"`
- `"set_image"` requires `imagePath` (non-empty)
- `"predict"` requires either `points` or `box` (or both)
- Maximum 100 points per request
- All coordinates must be non-negative
- Box coordinates: `x2 > x1` and `y2 > y1`

## Response Schema

### SAMResponse Structure

```swift
struct SAMResponse: Codable {
    let messageId: String?     // Echoes request messageId
    let version: String?       // Protocol version
    let success: Bool          // True if command succeeded
    let maskPath: String?      // Path to generated mask (for predict)
    let error: String?         // Error message (if success=false)
    let inferenceTimeMs: Int?  // Inference time in milliseconds
    let ready: Bool?           // True for initial ready signal (server mode)
    let score: Double?         // Mask confidence score (0-1)
}
```

### Response Validation

```swift
try response.validate()
```

**Validation Rules:**
- Version must match request version (if present)
- On failure, `error` field must be present and non-empty

## Command Types

### 1. set_image

**Purpose:** Load and encode an image into the SAM2 predictor

**Request:**
```json
{
  "messageId": "uuid-1234",
  "version": "1.0",
  "command": "set_image",
  "imagePath": "/path/to/image.jpg"
}
```

**Success Response:**
```json
{
  "messageId": "uuid-1234",
  "version": "1.0",
  "success": true,
  "imagePath": "/path/to/image.jpg",
  "width": 1920,
  "height": 1080
}
```

**Error Response:**
```json
{
  "messageId": "uuid-1234",
  "version": "1.0",
  "success": false,
  "error": "Image not found: /path/to/image.jpg"
}
```

**Notes:**
- Image is loaded once, then used for multiple `predict` calls
- Supports EXIF orientation correction
- Converts to RGB format internally
- Validates image dimensions (32px to 16384px)

### 2. predict

**Purpose:** Generate a segmentation mask using points and/or bounding box

**Request (Points only):**
```json
{
  "messageId": "uuid-5678",
  "version": "1.0",
  "command": "predict",
  "points": [[960, 540], [1000, 600]]
}
```

**Request (Box only):**
```json
{
  "messageId": "uuid-5678",
  "version": "1.0",
  "command": "predict",
  "box": [400, 300, 800, 600]
}
```

**Request (Points + Box):**
```json
{
  "messageId": "uuid-5678",
  "version": "1.0",
  "command": "predict",
  "points": [[960, 540]],
  "box": [400, 300, 800, 600]
}
```

**Success Response:**
```json
{
  "messageId": "uuid-5678",
  "version": "1.0",
  "success": true,
  "maskPath": "/path/to/mask.png",
  "score": 0.9876,
  "inferenceTimeMs": 47
}
```

**Error Response:**
```json
{
  "messageId": "uuid-5678",
  "version": "1.0",
  "success": false,
  "error": "No image set. Call set_image first."
}
```

**Notes:**
- All coordinates are in **pixel space**, not normalized
- Multiple masks are generated internally; only the highest-scoring mask is returned
- Mask is saved as RGBA PNG with RGB(50, 100, 200) color and alpha channel
- Debug image with overlaid points/box is also saved

### 3. reset

**Purpose:** Clear current image and reset predictor state

**Request:**
```json
{
  "messageId": "uuid-9012",
  "version": "1.0",
  "command": "reset"
}
```

**Response:**
```json
{
  "messageId": "uuid-9012",
  "version": "1.0",
  "success": true
}
```

**Notes:**
- Clears internal image encoding
- Resets predictor state
- Useful when loading a new image without restarting the worker

### 4. health

**Purpose:** Check system health and GPU availability

**Request:**
```json
{
  "messageId": "uuid-3456",
  "version": "1.0",
  "command": "health"
}
```

**Response:**
```json
{
  "messageId": "uuid-3456",
  "version": "1.0",
  "success": true,
  "status": "healthy",
  "device": "mps",
  "gpu_available": true,
  "memory_used": "2.3 GB",
  "memory_total": "16.0 GB"
}
```

## Communication Patterns

### Server Mode (Persistent Worker)

**Use Case:** SAM2 segmentation requiring fast iterative refinement

**Lifecycle:**
```
1. Start Python worker with --server flag
2. Send "ready" signal
3. Wait for "set_image" command
4. Loop:
   - Receive request
   - Process (predict, reset, etc.)
   - Send response
   - Repeat
5. Handle SIGTERM for graceful shutdown
```

**Advantages:**
- Model loaded once (~3s startup)
- Inference ~50ms per request
- Lower CPU/memory usage overall

**Implementation (Swift):**
```swift
// Start worker
try await startPersistentWorker()

// Set image
_ = try await setImage(path: imagePath)

// Multiple predictions (fast!)
let mask1 = try await predict(points: [point1], box: nil, imageSize: imageSize)
let mask2 = try await predict(points: [point2], box: nil, imageSize: imageSize)
```

**Implementation (Python):**
```python
# sam_wrapper.py
def server_mode(model_type, script_dir, output_dir):
    predictor, device = load_predictor(model_type, script_dir)

    # Send ready signal
    print(json.dumps({"success": True, "ready": True}), flush=True)

    for line in sys.stdin:
        request = json.loads(line.strip())
        command = request.get("command", "")

        if command == "predict":
            masks, scores, _ = predictor.predict(...)
            # Send response
            print(json.dumps(response), flush=True)
```

### CLI Mode (One-shot)

**Use Case:** Hunyuan3D generation (long-running, infrequent)

**Lifecycle:**
```
1. Spawn process with arguments
2. Load model and generate output
3. Write result to stdout/filesystem
4. Exit with status code
```

**Advantages:**
- Simple to implement
- No persistent state
- Clean process per request

**Disadvantages:**
- Model loaded each time (~10-30s)
- Higher memory overhead
- Slower for repeated operations

**Implementation (Swift):**
```swift
// Execute CLI command
let success = await execute(
    executable: uvPath,
    arguments: ["run", hunyuanScript, "--test", maskPath, imagePath],
    environment: envVars,
    workingDirectory: hunyuanDir
)
```

**Implementation (Python):**
```python
# hunyuan_wrapper.py
def main():
    args = parser.parse_args()

    if args.test:
        mask_path, image_path = args.test
        run_self_test(mask_path, image_path, args.output_dir)

    elif args.image:
        image = Image.open(args.image).convert("RGBA")
        mesh = pipeline(image=image, octree_resolution=args.resolution)
        mesh.export(args.output)
```

## Error Handling

### Swift Error Types

```swift
enum PythonError: Error, LocalizedError {
    case uvNotFound              // uv binary not found
    case workerNotRunning        // Python worker not running
    case workerNotReady          // Worker failed to start
    case encodingError           // Failed to encode request
    case invalidResponse(String)  // Invalid JSON/response
    case predictionFailed(String)// Prediction failed
    case timeout                // Request timed out
}
```

### Python Error Types

```python
class ModelLoadError(Exception): pass
class ImageValidationError(Exception): pass
class GPUNotAvailableError(Exception): pass
class NetworkError(Exception): pass
class OutOfMemoryError(Exception): pass
```

### Error Response Format

**Python Exception:**
```python
try:
    validate_image_path(image_path)
    # ...
except Exception as e:
    response = {"success": False, "error": str(e)}
    print(json.dumps(response), flush=True)
```

**Swift Handling:**
```swift
let response = try await sendRequest(request)
guard response.success else {
    throw PythonError.predictionFailed(response.error ?? "Unknown error")
}
```

## Security Considerations

### Path Validation

**Problem:** Malicious paths could access arbitrary files

**Solution:**
```python
def validate_image_path(image_path: str) -> None:
    path = Path(image_path)

    # Check file exists
    if not path.exists():
        raise ImageValidationError(f"Image not found: {image_path}")

    # Check it's a file (not directory)
    if not path.is_file():
        raise ImageValidationError(f"Path is not a file: {image_path}")

    # Check file extension
    valid_extensions = {".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".webp"}
    if path.suffix.lower() not in valid_extensions:
        raise ImageValidationError(f"Invalid image format: {path.suffix}")
```

### Coordinate Validation

**Problem:** Out-of-bounds coordinates could cause buffer overflows

**Solution:**
```python
def validate_coordinates(points, box, image_width, image_height):
    if points:
        for x, y in points:
            if not (0 <= x <= image_width) or not (0 <= y <= image_height):
                raise ImageValidationError(f"Coordinate out of bounds: ({x}, {y})")

    if box:
        x1, y1, x2, y2 = box
        if x1 < 0 or y1 < 0 or x2 > image_width or y2 > image_height:
            raise ImageValidationError(f"Box coordinates out of bounds: {box}")
```

### Input Size Limits

**Problem:** Excessive input could cause DoS

**Solution:**
```python
MAX_POINTS = 100
MAX_DOWNLOAD_SIZE = 2 * 1024 * 1024 * 1024  # 2GB
MAX_IMAGE_DIM = 16384

if len(points) > MAX_POINTS:
    raise ImageValidationError(f"Too many points: {len(points)}")
```

### SSL/TLS for Downloads

**Problem:** Man-in-the-middle attacks on model downloads

**Solution:**
```python
def create_secure_ssl_context():
    context = ssl.create_default_context()
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context

# Use in download
with urlopen(request, context=context, timeout=30) as response:
    # ...
```

## Examples

### Complete Workflow Example

```swift
// 1. Start persistent worker
try await startPersistentWorker()

// 2. Load image
let imageSize = try await setImage(path: "/path/to/image.jpg")
// Returns: CGSize(1920, 1080)

// 3. Create point (normalized)
let normalizedPoint = CGPoint(x: 0.5, y: 0.5)
let point = SAMPoint(normalizedCoords: normalizedPoint)

// 4. Predict mask
let maskURL = try await predict(points: [point], box: nil, imageSize: imageSize)
// Returns: URL(fileURLWithPath: "/path/to/mask.png")
// Takes: ~50ms (vs ~3000ms for CLI mode)

// 5. Load and display mask
let maskImage = NSImage(contentsOf: maskURL)

// 6. Reset for new image
try await resetPredictor()
```

### Error Handling Example

```swift
do {
    let maskURL = try await predict(points: [point], box: nil, imageSize: imageSize)
    // Display mask...
} catch PythonError.predictionFailed(let errorMsg) {
    print("Prediction failed: \(errorMsg)")
    // Show error to user
} catch PythonError.timeout {
    print("Request timed out")
    // Retry or show timeout error
} catch {
    print("Unexpected error: \(error)")
    // Show generic error
}
```

## Protocol Versioning

### Version 1.0 (Current)

**Fields:**
- `messageId`: String
- `version`: String ("1.0")
- `command`: String
- `imagePath`: String? (set_image only)
- `points`: [[Int]]? (predict only)
- `box`: [Int]? (predict only)
- `model`: String? (optional)

**Response Fields:**
- `messageId`: String?
- `version`: String?
- `success`: Bool
- `maskPath`: String? (predict only)
- `error`: String? (failure only)
- `inferenceTimeMs`: Int? (predict only)
- `ready`: Bool? (initial signal only)
- `score`: Double? (predict only)

### Future Versions

Backward compatibility considerations:
- Add new optional fields (additive changes)
- Never remove required fields
- Use `version` field for incompatible changes
- Support graceful degradation for missing fields

## Performance Characteristics

### Server Mode (SAM2)

| Operation | Time | Notes |
|-----------|------|-------|
| Worker startup | ~3s | Model loading |
| set_image | ~100ms | Image encoding |
| predict (points only) | ~50ms | Inference |
| predict (box only) | ~45ms | Inference |
| predict (points + box) | ~55ms | Inference |
| reset | ~5ms | State cleanup |

### CLI Mode (Hunyuan3D)

| Operation | Time | Notes |
|-----------|------|-------|
| Model load | ~20s | First run only |
| Warmup | ~10s | Pre-download |
| 3D generation (30 steps) | ~45s | On M2 Pro |
| 3D generation (50 steps) | ~75s | On M2 Pro |

## Debugging

### Enable Debug Logging

**Python:**
```python
from logging_config import get_logger
logger = get_logger("sam_wrapper")
logger.setLevel(logging.DEBUG)
```

**Swift:**
```python
# All stdout/stderr from Python is printed
# Look for: [Python stderr] and [Hunyuan] prefixes
```

### Common Issues

**Issue:** "No image set" error
- **Cause:** Called `predict` before `set_image`
- **Fix:** Call `set_image` first

**Issue:** "Invalid JSON" error
- **Cause:** Corrupted stdin buffer
- **Fix:** Restart worker process

**Issue:** Timeout errors
- **Cause:** Worker hung or crashed
- **Fix:** Check Python logs, restart worker

## Related Files

- `ModelrV3/Core/Models/Models.swift:193-285` - Request/response models
- `ModelrV3/Core/Services/Implementations/PythonEnvironment.swift:630-787` - Persistent worker implementation
- `Resources/sam_wrapper.py:486-664` - Server mode implementation
- `Resources/hunyuan_wrapper.py:154-207` - CLI mode implementation
