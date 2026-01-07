# Color Scheme Documentation

Modelr uses a specific color palette for UI elements and visual feedback. This document explains color choices, accessibility considerations, and how to modify colors.

## Overview

Colors in Modelr serve multiple purposes:

- **Visual Feedback:** Indicate segmentation masks, selection areas
- **Accessibility:** Ensure readability and usability
- **Branding:** Maintain consistent visual identity
- **Contrast:** Distinguish overlapping elements

## SAM2 Mask Color

**Color:** RGB(50, 100, 200) - Medium Blue

**Hex:** `#3264C8`

**Where Used:**

- Generated segmentation masks
- Paint tool brush strokes (adding to mask)
- Mask overlays on images

**Why This Color?**

1. **High Visibility:** Blue stands out against most image backgrounds
2. **Good Contrast:** Works well on both light and dark images
3. **Distinct from Common Colors:**

   - Avoids green (common in nature photos)
   - Avoids red (often used for errors/important alerts)
   - Avoids yellow (can be hard to see on light backgrounds)

4. **Transparency Friendly:** Blue alpha blends smoothly with underlying content
5. **Neutral Hue:** Not too warm or cool, works with diverse image content

### Mask Color Implementation

**Swift (ImageProcessingService.swift):**

```swift
let color: NSColor = stroke.isErasing
    ? NSColor.clear
    : NSColor(red: 50/255, green: 100/255, blue: 200/255, alpha: 1.0)
```

**Python (sam_wrapper.py):**

```python
b, g, r, a = (50, 100, 200, 255)
rgba[:, :, 0] = b
rgba[:, :, 1] = g
rgba[:, :, 2] = r
rgba[:, :, 3] = mask_255
```

## UI Color Palette

### macOS System Colors

Modelr primarily uses Apple's system colors for UI elements to maintain native appearance:

```swift
// Standard UI elements
NSColor.controlAccentColor      // Active elements, buttons
NSColor.separatorColor        // Dividers, borders
NSColor.labelColor           // Primary text
NSColor.secondaryLabelColor   // Secondary text
NSColor.tertiaryLabelColor  // Tertiary text
NSColor.windowBackgroundColor // Main background
NSColor.controlBackgroundColor // Input fields, buttons
```

### Custom Accent Colors

**Selection Colors:**

| Element             | Color                      | Usage             |
| ------------------- | -------------------------- | ----------------- |
| Point tool          | RGB(0, 255, 0) - Lime      | Click points      |
| Bounding box        | RGB(0, 255, 255) - Cyan    | Box outlines      |
| Lasso               | RGB(255, 0, 255) - Magenta | Selection paths   |
| Paint brush (erase) | Clear                      | Erasing from mask |

**Implementation (sam_wrapper.py):**

```python
def save_debug_image(image_np, points, box, output_dir):
    debug_img = Image.fromarray(image_np)
    draw = ImageDraw.Draw(debug_img)

    # Point tool - lime green
    r = 15
    for x, y in points:
        draw.ellipse([x - r, y - r, x + r, y + r], outline="lime", width=3)
        draw.line([x - r, y, x + r, y], fill="lime", width=2)
        draw.line([x, y - r, x, y + r], fill="lime", width=2)

    # Bounding box - cyan
    if box is not None:
        x1, y1, x2, y2 = box
        draw.rectangle([x1, y1, x2, y2], outline="cyan", width=3)
```

### Progress Indicators

**Colors Used:**

- Progress bar: `controlAccentColor`
- Success state: Green (system)
- Error state: Red (system)
- Loading: Gray/Blue animation

## Accessibility Considerations

### Contrast Ratios

All text and important UI elements meet WCAG AA standards:

**Text Colors:**

- Label text: Dark gray on light background (contrast > 4.5:1)
- Secondary text: Medium gray (contrast > 3:1)

**Mask Visibility:**

- SAM2 mask alpha: 0.7-0.9 for visibility
- Adjustable based on user preference (future enhancement)

### Color Blindness

The palette considers common forms of color blindness:

1. **Deuteranopia (green-weak):**

   - Blue (50, 100, 200) is still distinguishable
   - Cyan (0, 255, 255) contrasts with blue

2. **Protanopia (red-weak):**

   - Blue remains unaffected
   - Green/blue distinction still works

3. **Tritanopia (blue-weak):**
   - Red (used sparingly) remains visible
   - Consider adding pattern overlays for masks (future enhancement)

### High Contrast Mode

Modelr respects macOS high contrast accessibility setting:

```swift
if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
    // Use higher contrast colors
    // Increase mask alpha to 1.0
    // Use darker/brighter UI elements
}
```

## Modifying Colors

### Changing SAM2 Mask Color

**Step 1: Update Swift code**

File: `Modelr/Core/Services/Implementations/ImageProcessingService.swift:91-93`

```swift
// Current
NSColor(red: 50/255, green: 100/255, blue: 200/255, alpha: 1.0)

// Change to your color
NSColor(red: <R>/255, green: <G>/255, blue: <B>/255, alpha: 1.0)
```

**Step 2: Update Python code**

File: `Resources/sam_wrapper.py:432`

```python
# Current
b, g, r, a = (50, 100, 200, 255)

# Change to match Swift
b, g, r, a = (<R>, <G>, <B>, 255)
```

**Step 3: Update test reference mask**

File: `Resources/correct_self_test_mask.png`

1. Run self-test with new color
2. Generate new reference mask
3. Save as `correct_self_test_mask.png`
4. Verify self-test still passes (90%+ similarity)

### Changing Selection Colors

**File:** `Resources/sam_wrapper.py:462-468`

```python
// Point tool color
draw.ellipse([x - r, y - r, x + r, y + r], outline="<COLOR>", width=3)

// Box tool color
draw.rectangle([x1, y1, x2, y2], outline="<COLOR>", width=3)
```

Common color names: "red", "green", "blue", "yellow", "cyan", "magenta", "white", "black"

### Adding Theme Support (Future Enhancement)

To support dark/light mode or custom themes:

```swift
enum ColorTheme: String, CaseIterable {
    case light
    case dark
    case custom

    var maskColor: NSColor {
        switch self {
        case .light:
            return NSColor(red: 50/255, green: 100/255, blue: 200/255, alpha: 1.0)
        case .dark:
            return NSColor(red: 100/255, green: 150/255, blue: 255/255, alpha: 1.0)
        case .custom:
            return NSColor(red: <R>/255, green: <G>/255, blue: <B>/255, alpha: 1.0)
        }
    }
}
```

## Color Values Reference

### Common RGB Values

| Color     | RGB             | Hex         | Usage              |
| --------- | --------------- | ----------- | ------------------ |
| Black     | (0, 0, 0)       | #000000     | Text, borders      |
| White     | (255, 255, 255) | #FFFFFF     | Background         |
| SAM2 Mask | (50, 100, 200)  | #3264C8     | Segmentation masks |
| Lime      | (0, 255, 0)     | #00FF00     | Point markers      |
| Cyan      | (0, 255, 255)   | #00FFFF     | Bounding boxes     |
| Magenta   | (255, 0, 255)   | #FF00FF     | Lasso selections   |
| Clear     | (0, 0, 0, 0)    | Transparent | Eraser             |

### System Colors

```swift
// Text colors
NSColor.labelColor              // Primary text
NSColor.secondaryLabelColor     // Secondary text
NSColor.tertiaryLabelColor     // Tertiary text
NSColor.quaternaryLabelColor   // Disabled text

// Background colors
NSColor.windowBackgroundColor  // Main window background
NSColor.textBackgroundColor   // Text field background
NSColor.controlBackgroundColor // Button background

// Accent colors
NSColor.controlAccentColor     // Active elements

// Separator colors
NSColor.separatorColor         // Dividers, borders

// Selection colors
NSColor.selectedTextBackgroundColor  // Text selection
NSColor.keyboardFocusIndicatorColor  // Focus rings
```

## Visual Design Guidelines

### Principles

1. **Contrast:** Maintain minimum 4.5:1 contrast for text
2. **Hierarchy:** Use color to establish visual hierarchy
3. **Consistency:** Use same color for similar UI elements
4. **Feedback:** Use color changes to indicate state changes
5. **Accessibility:** Respect user accessibility preferences

### Best Practices

- Use system colors when possible for native feel
- Keep accent colors consistent throughout the app
- Ensure sufficient contrast between overlapping elements
- Test with different image types (dark, light, colorful)
- Consider color blindness when choosing palettes
- Use alpha transparency for overlays to show underlying content

### Testing Colors

**Visual Testing:**

1. Test with variety of images:

   - High contrast images
   - Low contrast images
   - Colorful images
   - Monochromatic images

2. Test mask visibility:
   - On light backgrounds
   - On dark backgrounds
   - On complex patterns
   - On similar-colored areas

**Automated Testing:**

```swift
func testMaskColor() {
    let maskImage = createTestMask()
    let color = maskImage.colorAt(x: 10, y: 10)

    XCTAssertEqual(color.redComponent, 50/255, accuracy: 0.01)
    XCTAssertEqual(color.greenComponent, 100/255, accuracy: 0.01)
    XCTAssertEqual(color.blueComponent, 200/255, accuracy: 0.01)
}
```

## Related Files

- `Modelr/Core/Services/Implementations/ImageProcessingService.swift:61-118` - Mask color application
- `Resources/sam_wrapper.py:426-447` - Python mask color
- `Resources/sam_wrapper.py:449-479` - Debug image colors
- `Resources/correct_self_test_mask.png` - Reference mask with correct colors
