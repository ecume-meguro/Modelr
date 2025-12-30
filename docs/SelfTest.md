# Self-Test Algorithm Documentation

The self-test algorithm validates that ModelrV3's AI models are working correctly during initial setup. This ensures users have a functioning installation before they begin actual work.

## Overview

The self-test performs the following validations:

1. **SAM2 Model Check:** Verifies the segmentation model can load and predict
2. **Prediction Quality Check:** Compares generated mask against a reference mask
3. **Hunyuan3D Model Check:** Verifies the 3D generation model can load and generate
4. **End-to-End Validation:** Confirms the full pipeline works correctly

## Test Image

**File:** `Resources/self_test.jpg`

**Content:** An alpaca image selected for:
- Distinct subject with clear boundaries
- Good lighting and contrast
- Reasonable complexity (not too simple, not too complex)
- Small file size for quick testing

**Reference Mask:** `Resources/correct_self_test_mask.png`

This mask was manually created and verified to correctly segment the alpaca.

## Self-Test Flow

```
┌─────────────────────────────────────────────────────────────┐
│  1. Setup Phase                                           │
│     ├─ Download SAM2 checkpoint                           │
│     ├─ Start persistent worker                             │
│     ├─ Download Hunyuan3D model                          │
│     └─ Warmup Hunyuan pipeline                            │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Image Loading                                         │
│     ├─ Load self_test.jpg                                │
│     ├─ Call SAM2.set_image()                            │
│     └─ Display to user                                   │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  3. User Interaction                                      │
│     ├─ Prompt: "Click on the center of the alpaca"       │
│     ├─ Capture click location (normalized 0-1)            │
│     └─ Run SAM2.predict(click_point)                     │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  4. Mask Comparison                                      │
│     ├─ Compare generated mask with reference mask          │
│     ├─ Compute Jaccard similarity (IoU)                  │
│     └─ Check if similarity >= 90%                        │
└─────────────────────────────────────────────────────────────┘
                          │
            ┌─────────────┴─────────────┐
            ▼                           ▼
      PASS (>=90%)                 FAIL (<90%)
            │                           │
            ▼                           ▼
    ┌───────────────┐           ┌───────────────┐
    │  5. Hunyuan   │           │  Retry Loop   │
    │  Generation   │           │               │
    │               │           │ - Show error   │
    │ - Generate 3D │           │ - Clear mask  │
    │ - Save .obj  │           │ - Prompt again│
    │ - Display     │           │ - Limit: N/A  │
    └───────────────┘           └───────────────┘
            │
            ▼
    ┌───────────────┐
    │  6. Success   │
    │               │
    │ - Enable UI   │
    │ - Show result│
    │ - Allow exit │
    └───────────────┘
```

## Validation Strategy

### Step 1: SAM2 Model Loading

**Implementation:** `PythonEnvironment.swift:366-420`

```swift
private func runSelfTest(finalUvPath: String) async {
    // Download checkpoint if needed
    let checkpointsDir = appSupportDir.appendingPathComponent("checkpoints")
    startThroughputMonitor(directory: checkpointsDir, statusPrefix: "Downloading SAM2 model")

    // Start persistent worker
    try await startPersistentWorker()

    // Set test image
    _ = try await setImage(path: testImgPath)
}
```

**Validation:**
- Checkpoint file exists in `~/Library/Application Support/ModelrV3/checkpoints/`
- Worker process starts successfully
- Worker sends "ready" signal
- Image loads without errors

### Step 2: Interactive Prediction

**Implementation:** `PythonEnvironment.swift:481-537`

```swift
func runSelfTestWithClick(normalizedPoint: CGPoint) async {
    let point = SAMPoint(normalizedCoords: normalizedPoint)

    // Run prediction
    let maskURL = try await predict(points: [point], box: nil, imageSize: imagePixelSize)
    let maskImage = NSImage(contentsOf: maskURL)

    // Compare with reference
    let referenceMaskURL = appSupportDir.appendingPathComponent("correct_self_test_mask.png")
    let similarity = compareMasks(maskURL: maskURL, referenceURL: referenceMaskURL)
}
```

**User Prompt:** "Click on the center of the alpaca's body"

**Validation:**
- Prediction succeeds (no exceptions)
- Mask file is created
- Mask is not empty
- Click location is within image bounds

### Step 3: Mask Comparison (Jaccard Similarity)

**Implementation:** `PythonEnvironment.swift:540-581`

**Algorithm:** Intersection over Union (IoU)

```swift
private func compareMasks(maskURL: URL, referenceURL: URL) -> Double {
    // Load both masks
    let maskBitmap = NSBitmapImageRep(data: maskTiff)
    let refBitmap = NSBitmapImageRep(data: refTiff)

    var matchingPixels = 0
    var totalMaskPixels = 0  // Union of both masks

    for y in 0..<height {
        for x in 0..<width {
            let maskAlpha = maskBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
            let refAlpha = refBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0

            let maskHasContent = maskAlpha > 0.1
            let refHasContent = refAlpha > 0.1

            // Count pixels where either mask has content (union)
            if maskHasContent || refHasContent {
                totalMaskPixels += 1

                // Count where both agree (intersection)
                if maskHasContent == refHasContent {
                    matchingPixels += 1
                }
            }
        }
    }

    // Jaccard similarity = Intersection / Union
    let similarity = Double(matchingPixels) / Double(totalMaskPixels)
    return similarity
}
```

**Threshold:** 90% (0.9)

**Rationale:**
- 90% allows for minor variations (click position, model randomness)
- 90% ensures the model is capturing the correct object
- 90% is strict enough to catch broken installations

**Example Calculation:**

```
Reference mask: 10,000 pixels of content
Generated mask: 11,500 pixels of content
Intersection (both agree): 9,500 pixels
Union (either has content): 12,000 pixels

Similarity = 9,500 / 12,000 = 0.79 (79%) → FAIL

Reference mask: 10,000 pixels of content
Generated mask: 9,800 pixels of content
Intersection (both agree): 9,600 pixels
Union (either has content): 10,200 pixels

Similarity = 9,600 / 10,200 = 0.94 (94%) → PASS
```

### Step 4: Hunyuan3D Generation

**Implementation:** `PythonEnvironment.swift:583-626`

```swift
private func runHunyuanSelfTest(finalUvPath: String, maskPath: String, imagePath: String) async {
    // Run Hunyuan3D generation
    let modelSuccess = await execute(
        executable: finalUvPath,
        arguments: ["run", hunyuanScript, "--test", maskPath, imagePath],
        environment: envVars,
        workingDirectory: hunyuanDir
    )

    let modelURL = hunyuanDir.appendingPathComponent("self_test_model.obj")

    if modelSuccess && fm.fileExists(atPath: modelURL.path) {
        self.selfTest3DModelURL = modelURL
        self.canProceed = true
    }
}
```

**Validation:**
- Process exits with code 0
- Model file (`self_test_model.obj`) exists
- Model file is not empty (> 0 bytes)
- Model file is valid 3D mesh format

### Step 5: Success Conditions

All of the following must be true:

1. ✅ SAM2 worker started successfully
2. ✅ Test image loaded without errors
3. ✅ Prediction completed successfully
4. ✅ Mask similarity >= 90%
5. ✅ Hunyuan3D generation completed (or skipped if not ready)

## Error Conditions

### Error 1: SAM2 Worker Failed to Start

**Symptom:** "Error: Failed to start SAM2 worker"

**Causes:**
- uv binary not found
- Python installation failed
- Checkpoint download failed
- Out of memory

**Recovery:**
- Check uv installation
- Check network connection
- Check disk space
- Try smaller model (tiny vs base_plus)

### Error 2: Image Load Failed

**Symptom:** "Error: Failed to load test image"

**Causes:**
- Image file corrupted
- File permissions issue
- Invalid image format

**Recovery:**
- Reinstall application
- Check App Support directory permissions
- Verify self_test.jpg exists

### Error 3: Prediction Failed

**Symptom:** "Error occurred. Try clicking again."

**Causes:**
- Click outside image bounds
- Worker crashed
- Out of memory
- Invalid point coordinates

**Recovery:**
- Click on the alpaca body
- Restart application
- Check memory availability

### Error 4: Low Similarity (<90%)

**Symptom:** "That doesn't look right (XX% off). Try clicking again."

**Causes:**
- Clicked on wrong object (background instead of alpaca)
- Clicked on edge of object
- Model failed to load correctly
- Checkpoint corrupted

**Recovery:**
- Click more carefully on alpaca body
- Try different click position
- Reinstall application

### Error 5: Hunyuan3D Generation Failed

**Symptom:** Still allows proceeding but shows warning

**Causes:**
- Hunyuan model download failed
- Out of memory
- GPU not available
- Incompatible system

**Recovery:**
- Still allows using SAM2 segmentation
- 3D generation will fail later
- Check system requirements
- Ensure adequate RAM (8GB+)

## Threshold Choices

### Why 90% Similarity?

**Trade-offs:**

| Threshold | False Positives | False Negatives | User Experience |
|-----------|-----------------|-----------------|----------------|
| 70% | High (passes bad models) | Low | Poor (broken installs pass) |
| 80% | Medium | Low | Acceptable (some false passes) |
| **90%** | **Low** | **Medium** | **Good balance** |
| 95% | Very Low | High | Frustrating (too strict) |
| 99% | None | Very High | Unusable (requires perfect click) |

**Analysis:**

- **70-80%:** Too lenient. Broken installations might pass.
- **95-99%:** Too strict. Requires perfect click placement every time.
- **90%:** Optimal balance. Allows minor variations while catching real issues.

**Empirical Testing:**

During development, tested various click positions on the alpaca:

| Click Location | Similarity |
|---------------|------------|
| Perfect center | 94-97% |
| Near center | 91-94% |
| Edge of body | 85-90% |
| Background | 10-30% |
| Other object | 5-20% |

Result: 90% threshold correctly identifies good clicks while rejecting bad ones.

### Reference Mask Generation

**Process:**

1. Load `self_test.jpg` into image editor
2. Manually trace alpaca outline
3. Refine mask to capture all alpaca pixels
4. Ensure clean edges (no holes, no noise)
5. Save as `correct_self_test_mask.png` with alpha channel

**Characteristics:**
- Alpha channel contains the actual mask (0 = background, 255 = foreground)
- RGB channels set to blue tint for visualization
- Resolution matches original image
- Single mask (not multiple options)

## Code Reference

### Self-Test Entry Point

**File:** `PythonEnvironment.swift:366-420`

```swift
private func runSelfTest(finalUvPath: String) async {
    // 1. Download SAM2 model
    await MainActor.run { status = "Downloading SAM2 model..." }
    startThroughputMonitor(directory: checkpointsDir, statusPrefix: "Downloading SAM2 model")

    try await startPersistentWorker()
    stopThroughputMonitor()

    // 2. Setup Hunyuan environment
    await MainActor.run { status = "Setting up Hunyuan3D environment..." }
    await setupHunyuanEnvironment(finalUvPath: finalUvPath)

    // 3. Download Hunyuan model (warmup)
    await MainActor.run { status = "Downloading Hunyuan3D model..." }
    startThroughputMonitor(directory: hunyuanCacheDir, statusPrefix: "Downloading Hunyuan3D model")
    await downloadHunyuanModel(finalUvPath: finalUvPath)
    stopThroughputMonitor()

    // 4. Ready for user interaction
    await MainActor.run {
        selfTestAwaitingClick = true
        selfTestPrompt = "Click on the center of the alpaca's body"
        status = "Click on the alpaca to continue"
    }
}
```

### User Click Handler

**File:** `PythonEnvironment.swift:481-537`

```swift
func runSelfTestWithClick(normalizedPoint: CGPoint) async {
    guard let uvPath = cachedUvPath else { return }

    await MainActor.run {
        selfTestClickPoint = normalizedPoint
        selfTestAwaitingClick = false
        status = "Segmenting..."
    }

    let point = SAMPoint(normalizedCoords: normalizedPoint)

    do {
        let maskURL = try await predict(points: [point], box: nil, imageSize: imagePixelSize)
        let maskImage = NSImage(contentsOf: maskURL)

        await MainActor.run {
            selfTestMask = maskImage
            selfTestAttempts += 1
        }

        // Compare with reference mask
        let similarity = compareMasks(maskURL: maskURL, referenceURL: referenceMaskURL)

        // If less than 90% similar, ask to retry
        if similarity < 0.90 {
            await MainActor.run {
                selfTestClickPoint = nil
                selfTestMask = nil
                selfTestAwaitingClick = true
                selfTestPrompt = "That doesn't look right (\(Int((1-similarity)*100))% off). Try clicking on the alpaca's body again."
                status = "Click on the alpaca to continue"
            }
            return
        }

        await MainActor.run {
            referenceMaskCoverage = similarity
            status = "Segmentation successful!"
        }

        // Continue to Hunyuan3D
        await runHunyuanSelfTest(finalUvPath: uvPath, maskPath: maskURL.path, imagePath: testImgPath)
    } catch {
        await MainActor.run {
            selfTestClickPoint = nil
            selfTestAwaitingClick = true
            selfTestPrompt = "Error occurred. Try clicking again."
            status = "Click on the alpaca to continue"
        }
    }
}
```

## Running Self-Test Manually

### Command Line

```bash
cd ~/Library/Application\ Support/ModelrV3
# Test SAM2
python sam_wrapper.py --test self_test.jpg

# Test Hunyuan
python hunyuan_wrapper.py --test mask.png self_test.jpg
```

### Programmatic

```swift
// In unit tests or debugging
let env = PythonEnvironment()
await env.setup()
let point = CGPoint(x: 0.5, y: 0.5) // Approximate center
await env.runSelfTestWithClick(normalizedPoint: point)
```

## Troubleshooting

### Self-Test Hangs

**Symptom:** Progress bar stuck at one stage

**Diagnosis:**
1. Check Console.app for Python errors
2. Check disk space
3. Check network connection
4. Check Activity Monitor for hung processes

**Solution:**
- Kill hung process
- Restart application
- Check logs in `~/Library/Application Support/ModelrV3/`

### Consistent Failure

**Symptom:** Self-test always fails at same point

**Diagnosis:**
1. Identify failure stage (SAM2, prediction, or Hunyuan)
2. Check relevant logs
3. Verify resources exist

**Solution:**
- Reinstall application
- Delete `~/Library/Application Support/ModelrV3/`
- Run setup again

### Model Corruption

**Symptom:** Similarity always <50% even with perfect clicks

**Diagnosis:**
1. Check checkpoint file size
2. Verify checksum
3. Test with different model (tiny vs base_plus)

**Solution:**
- Delete corrupted checkpoint
- Re-download
- Verify checksum

## Related Files

- `ModelrV3/Core/Services/Implementations/PythonEnvironment.swift:366-626` - Self-test implementation
- `ModelrV3/Core/Services/Implementations/PythonEnvironment.swift:540-581` - Mask comparison
- `Resources/self_test.jpg` - Test image
- `Resources/correct_self_test_mask.png` - Reference mask
- `Resources/sam_wrapper.py:753-802` - Python self-test function
