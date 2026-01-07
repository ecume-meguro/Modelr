# Contributing to Modelr

Thank you for your interest in contributing to Modelr! This document provides guidelines for contributing code, documentation, and other improvements.

## Table of Contents

- [Code Style Guidelines](#code-style-guidelines)
- [Commit Message Conventions](#commit-message-conventions)
- [Pull Request Process](#pull-request-process)
- [Testing Requirements](#testing-requirements)
- [Documentation Standards](#documentation-standards)
- [Getting Started](#getting-started)

## Code Style Guidelines

### Swift

**Indentation:** 4 spaces (no tabs)

```swift
// Good
func calculateMask() {
    if condition {
        doSomething()
    }
}

// Bad (tabs)
func calculateMask() {
	if condition {
		doSomething()
	}
}
```

**Naming Conventions:**

- **Types:** PascalCase
- **Functions/Methods:** camelCase
- **Variables:** camelCase
- **Constants:** camelCase (let)
- **Enums:** PascalCase with lowercase cases

```swift
// Types
struct SAMPoint { }
enum SAMTool { case point, box }
class PythonEnvironment { }

// Functions
func predictMask() -> URL
func isPointInsidePolygon(_ point: CGPoint) -> Bool

// Variables
let imageWidth = 1920
var currentMask: URL?

// Constants
let maxPoints = 100
let maskColor = RGB(50, 100, 200)
```

**Comments:**

- Use `//` for single-line comments
- Use `/* */` for multi-line comments (rarely needed)
- Add documentation comments for public APIs

```swift
/// Convert normalized coordinates to pixel coordinates
/// - Parameter imageSize: The size of the target image
/// - Returns: Tuple of (x, y) pixel coordinates
func pixelCoords(for imageSize: CGSize) -> (x: Int, y: Int) {
    // Implementation...
}
```

**No Comments Policy:** Keep code self-documenting. Add comments only for "why," not "what."

```swift
// Good (explains why)
// Checkpoints are cached in App Support to avoid repeated downloads
let cacheDir = appSupportDir.appendingPathComponent("checkpoints")

// Bad (restates what is obvious)
// Get the cache directory path
let cacheDir = appSupportDir.appendingPathComponent("checkpoints")
```

### Python

**Style:** Follow PEP 8 guidelines

**Indentation:** 4 spaces

**Naming Conventions:**

- **Classes:** PascalCase
- **Functions/Methods:** snake_case
- **Variables:** snake_case
- **Constants:** UPPER_CASE

```python
# Classes
class ModelManager:
    pass

# Functions
def load_predictor(model_type: str) -> SAM2ImagePredictor:
    pass

# Variables
image_width = 1920
current_mask = None

# Constants
MAX_POINTS = 100
MASK_COLOR = (50, 100, 200, 255)
```

**Docstrings:** Use Google style

```python
def save_mask(mask: np.ndarray, output_path: str) -> str:
    """Save mask as RGBA PNG with alpha channel.

    Args:
        mask: Binary mask array (0-1 range)
        output_path: Path where to save the mask file

    Returns:
        Path to saved mask file

    Raises:
        ValueError: If mask is empty or invalid
        IOError: If file cannot be written
    """
    # Implementation...
```

**Type Hints:** Use type hints for all function signatures

```python
from typing import Optional, List, Tuple

def predict(
    points: Optional[List[List[int]]],
    box: Optional[List[int]]
) -> Tuple[np.ndarray, float]:
    """Predict segmentation mask."""
    pass
```

### General Guidelines

**Line Length:** Max 120 characters

**Import Organization:**

```swift
// Swift
import Foundation
import AppKit
import SwiftUI
```

```python
# Python
import os
import sys
from typing import Optional, List
import torch
import numpy as np
```

**Error Handling:**

- Use typed errors
- Provide context in error messages
- Handle errors gracefully

```swift
enum ModelError: Error, LocalizedError {
    case invalidCommand(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let cmd):
            return "Invalid command: \(cmd)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        }
    }
}
```

## Commit Message Conventions

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

- **feat:** New feature
- **fix:** Bug fix
- **docs:** Documentation changes
- **style:** Code style changes (formatting, no logic change)
- **refactor:** Code refactoring
- **test:** Adding or updating tests
- **chore:** Maintenance tasks (build, deps, etc.)
- **perf:** Performance improvements
- **ci:** CI/CD changes

### Examples

**Feature:**

```
feat(editor): add lasso selection tool

Implemented freehand polygon selection for object segmentation.
Users can draw a closed path around objects to select them.
```

**Bug Fix:**

```
fix(python): handle worker timeout gracefully

Previously, if the Python worker didn't respond within 30s,
the app would hang. Now throws a proper timeout error
that can be caught and displayed to the user.
```

**Refactor:**

```
refactor(state): move image state to separate module

Extracted image-related state and actions into ImageState
and ImageAction to reduce AppState complexity and improve
testability.
```

**Documentation:**

```
docs(architecture): add system diagram

Added ASCII art diagram showing the overall architecture
and data flow between Swift and Python components.
```

### Guidelines

- **Subject line:** Max 50 characters, imperative mood, no period
- **Body:** Explain "what" and "why," not "how"
- **Footer:** Reference issues, breaking changes, etc.
- **One commit per logical change:** Don't combine unrelated changes

## Pull Request Process

### Before Submitting

1. **Update documentation:** Update README, docs, or inline comments if needed
2. **Add tests:** Write tests for new functionality
3. **Run tests:** Ensure all tests pass (`make test`)
4. **Format code:** Ensure code follows style guidelines
5. **Self-review:** Review your own changes before submitting

### Creating PR

1. **Create feature branch:**

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Commit changes:**

   ```bash
   git add .
   git commit -m "feat(scope): your commit message"
   ```

3. **Push to remote:**

   ```bash
   git push origin feature/your-feature-name
   ```

4. **Create PR:**
   - Go to GitHub repository
   - Click "New Pull Request"
   - Select your branch
   - Fill in PR template
   - Reference related issues (e.g., "Closes #123")

### PR Template

```markdown
## Description

Brief description of what this PR does and why.

## Type of Change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update

## Testing

- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual testing completed

## Checklist

- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex code
- [ ] Documentation updated
- [ ] No new warnings generated
- [ ] Tests added/updated
- [ ] All tests passing

## Related Issues

Closes #123, #456
```

### Review Process

1. **Assign reviewer:** Request review from a maintainer
2. **Address feedback:** Respond to all review comments
3. **Update PR:** Make requested changes
4. **Squash commits (optional):** Maintain clean history
5. **Merge:** Wait for approval and CI checks to pass

## Testing Requirements

### Unit Tests

**Coverage:** Aim for 80%+ coverage for new code

**Location:** `ModelrV3Tests/`

**Examples:**

```swift
final class CoordinateTests: XCTestCase {
    func testNormalizedToPixelBasic() throws {
        let imageSize = CGSize(width: 100, height: 100)
        let normalized = CGPoint(x: 0.5, y: 0.5)
        let pixel = normalized.toViewCoords(imageSize)

        XCTAssertEqual(pixel.x, 50, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 50, accuracy: 0.1)
    }
}
```

### Integration Tests

**Purpose:** Test communication between Swift and Python

**Location:** `ModelrV3Tests/IntegrationTests.swift`

**Example:**

```swift
func testSAM2PredictionFlow() async throws {
    let mockService = MockPythonService()

    // Set image
    let size = try await mockService.setImage(path: testImagePath)

    // Predict
    let maskURL = try await mockService.predict(
        points: [testPoint],
        box: nil,
        imageSize: size
    )

    // Verify mask exists
    XCTAssertTrue(FileManager.default.fileExists(atPath: maskURL.path))
}
```

### Running Tests

```bash
# Run all tests
make test

# Run specific test
xcodebuild test -scheme ModelrV3Tests -only-testing:ModelrV3Tests/CoordinateTests

# Run with coverage
xcodebuild test -scheme ModelrV3Tests -enableCodeCoverage YES
```

### Test Helpers

Use provided test helpers:

- `MockFileSystem` - Mock file operations
- `MockPythonService` - Mock Python communication
- `TestDataGenerator` - Generate test data

```swift
let mockFileSystem = MockFileSystem()
mockFileSystem.createFile(at: testURL, contents: testData)

let mockPython = MockPythonService()
mockPython.mockPredictResponse = mockResponse
```

## Documentation Standards

### Inline Documentation

**Public APIs:** Always document

```swift
/// Predict a segmentation mask from points and/or bounding box
/// - Parameters:
///   - points: Array of points in normalized coordinates (0-1)
///   - box: Optional bounding box in normalized coordinates
///   - imageSize: Size of the target image
/// - Returns: URL to generated mask file
/// - Throws: PythonError if prediction fails
func predict(
    points: [SAMPoint],
    box: SAMBox?,
    imageSize: CGSize
) async throws -> URL
```

**Complex Algorithms:** Add comments explaining approach

```swift
// Ray casting algorithm for point-in-polygon test
// Draws a ray from point to infinity, counts intersections
// with polygon edges. Odd count = inside, even = outside.
// See: https://en.wikipedia.org/wiki/Point_in_polygon
private func isPointInsidePolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
    // Implementation...
}
```

### File Documentation

Add file header for complex files:

```swift
//
//  ImageProcessingService.swift
//  Modelr
//
//  Created by [Name] on [Date].
//  Provides image processing operations including cropping,
//  lasso deletion, and mask stroke application.
//

import Foundation
import AppKit
```

### External Documentation

**README:** Update with new features or breaking changes

**docs/:** Create/update documentation for significant changes

- `docs/API.md` - New public APIs
- `docs/Architecture.md` - Major architecture changes
- `docs/CoordinateSystems.md` - New coordinate systems

## Getting Started

### Setting Up Development Environment

1. **Clone repository:**

   ```bash
    git clone https://github.com/yourusername/Modelr.git
    cd Modelr
   ```

2. **Install dependencies:**

   ```bash
   make generate
   make build
   ```

3. **Run tests:**

   ```bash
   make test
   ```

4. **Run app:**
   ```bash
   make run
   ```

### Development Workflow

1. **Create feature branch:**

   ```bash
   git checkout -b feature/your-feature
   ```

2. **Make changes:**

   - Write code
   - Add tests
   - Update documentation

3. **Test locally:**

   ```bash
   make test
   ```

4. **Commit and push:**

   ```bash
   git add .
   git commit -m "feat: description"
   git push origin feature/your-feature
   ```

5. **Create pull request**

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Welcome new contributors
- Focus on what is best for the community

## Questions?

- Open an issue for questions or bugs
- Join discussions for design discussions
- Check existing issues before creating new ones

Thank you for contributing to Modelr!
