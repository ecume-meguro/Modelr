# Modelr State Machine Analysis

## Step Definitions

| Internal Value | Step Name | Display # | Optional | Displayed |
|----------------|-----------|-----------|----------|-----------|
| 0 | Setup | - | No | Collapsed after complete |
| 1 | Input | 1 | No | Yes |
| 2 | Segment | 2 | No | Yes |
| 3 | Touchup | 3 | **Yes** | Yes |
| 4 | GenerateSettings | 4 | **Yes** | Yes (via "Custom Settings") |
| 5 | Generate | 5 | No | Yes |
| 6 | PostProcess | 6 | No | Yes |

## All Forward Transitions

### From Setup (0)
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Setup completes | Input | `finalizeSetup()` | Automatic |
| Env refresh completes | Input | `runEnvironmentRefresh()` | Automatic |

### From Input (1)
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Image loaded | Segment | `loadImage()` | Drop zone / Select Image button |
| Restore cached seg | Segment | `restoreCachedSegmentation()` | (if cache exists) |

### From Segment (2)
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Refine mask | Touchup | `startTouchup()` | "Refine Mask" button |
| Generate with preset | Generate | `generateImmediately()` | "Generate with X" button |
| Restore cached gen | PostProcess | `restoreCachedGeneration()` | "Restore Previous Model" |

### From Touchup (3)
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Generate with preset | Generate | `generateImmediately()` | "Generate with X" button |
| Restore cached gen | PostProcess | `restoreCachedGeneration()` | "Restore Previous Model" |

### From GenerateSettings (4) - Optional
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Generate model | Generate | `startGeneration()` | "Generate Model" button |
| Back | Touchup/Segment | `handleBackAction()` | Back button |
| **Entry via**: "Custom Settings" option in preset dropdown menu | |

### From Generate (5)
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Generation completes | PostProcess | `transitionToPostProcess()` | Automatic |
| Generation stops | (stays) | `stopGeneration()` | "Stop Generation" button |

### From PostProcess (6)
| Trigger | Target | Function | UI Element |
|---------|--------|----------|------------|
| Export | (end) | Various export functions | Export buttons |

## All Back Transitions

| From | To | Condition | Warning Dialog |
|------|-----|-----------|----------------|
| Input | Setup | Only if setup incomplete | - |
| Segment | Input | If masks exist | "Discard Image?" |
| Touchup | Segment | If `hasMaskEdits` | "Lose Touchup Changes?" |
| GenerateSettings | Touchup/Segment | Based on visitedSteps | - |
| Generate | Segment/Touchup | If model exists or generating | "Discard 3D Model?" |
| PostProcess | Generate | If pending deletions or processed | "Discard 3D Model?" |

## Complete Forward Paths

### Path A: Full Path (Visit Touchup, Skip Settings)
```
Setup → Input → Segment → Touchup → Generate → PostProcess
         [1]      [2]       [3]        [5]         [6]
                                   (skip [4])
```
visitedSteps: {.setup, .input, .segment, .touchup, .generate, .postProcess}
Settings shows: "(skipped)" with bypass arc

### Path B: Full Path with Custom Settings
```
Setup → Input → Segment → Touchup → Settings → Generate → PostProcess
         [1]      [2]       [3]        [4]        [5]         [6]
```
visitedSteps: {.setup, .input, .segment, .touchup, .generateSettings, .generate, .postProcess}
Entry to Settings via: "Custom Settings" in preset dropdown

### Path C: Skip Both Optional Steps
```
Setup → Input → Segment → Generate → PostProcess
         [1]      [2]        [5]         [6]
                          (skip [3],[4])
```
visitedSteps: {.setup, .input, .segment, .generate, .postProcess}
Touchup shows: "(skipped)", Settings shows: "(skipped)"

### Path D: Skip Touchup, Visit Settings
```
Setup → Input → Segment → Settings → Generate → PostProcess
         [1]      [2]        [4]        [5]         [6]
                          (skip [3])
```
visitedSteps: {.setup, .input, .segment, .generateSettings, .generate, .postProcess}
Touchup shows: "(skipped)"

### Path E: Restore from Segment
```
Setup → Input → Segment → PostProcess
         [1]      [2]         [6]
                      (restore cached)
```
visitedSteps: {.setup, .input, .segment, .postProcess}
Touchup, Settings show: "(skipped)", Generate shows: completed (has model URL)

### Path F: Restore from Touchup
```
Setup → Input → Segment → Touchup → PostProcess
         [1]      [2]       [3]         [6]
                               (restore cached)
```
visitedSteps: {.setup, .input, .segment, .touchup, .postProcess}
Settings shows: "(skipped)", Generate shows: completed (has model URL)

## Cycles (Repeated Patterns)

### Cycle 1: Refinement Loop (Segment ↔ Touchup)
```
Segment → Touchup → Back → Segment → Touchup → ...
```
- User refines mask, goes back to change segmentation, refines again
- visitedSteps updates correctly: .touchup removed on back, re-added on forward

### Cycle 2: Image Retry Loop (Input ↔ Segment)
```
Segment → Back → Input → (new image) → Segment → ...
```
- User tries different images
- Segmentation state cleared on back

### Cycle 3: Regeneration Loop (Segment/Touchup ↔ Generate)
```
Segment → Generate → Back → Segment → Generate → ...
```
- User generates, reviews, goes back to try different mask
- Generation state cleared on back
- If going back from PostProcess first, generation cached

### Cycle 4: Post-Process Review Loop (Generate ↔ PostProcess)
```
Generate → PostProcess → Back → Generate → PostProcess → ...
```
- User reviews post-process, goes back to regenerate
- Model kept when going back to Generate
- Post-process state cleared

### Cycle 5: Full Restart
```
PostProcess → Back → Back → Back → Input → ... → PostProcess
```
- Complete workflow restart
- All state progressively cleared
- Caches created for potential restore

## UI State Matrix

For each step, what should display:

### At Setup
| Element | State |
|---------|-------|
| Setup row | Active, expanded |
| Steps 1-5 | Locked (grayed, lock icon) |
| Back button | Hidden or disabled |

### At Input
| Element | State |
|---------|-------|
| Setup row | Collapsed, completed |
| Step 1 (Input) | Active, shows hint or "Image loaded" |
| Steps 2-5 | Locked or available |
| Back button | Hidden (can't go back to setup normally) |

### At Segment
| Element | State |
|---------|-------|
| Step 1 | Completed (checkmark) |
| Step 2 (Segment) | Active, SegmentationPanel visible |
| Step 3 (Touchup) | Available, shows "(optional)" |
| Steps 4-5 | Available but dimmed |
| "Refine Mask" | Enabled if masks > 0 |
| "Generate with X" | Always visible |
| Back button | "Back to Input" |

### At Touchup
| Element | State |
|---------|-------|
| Steps 1-2 | Completed |
| Step 3 (Touchup) | Active, TouchupPanel visible |
| Steps 4-5 | Available |
| "Generate with X" | Visible |
| Back button | "Back to Segment" |

### At Generate (Generating)
| Element | State |
|---------|-------|
| Steps 1-2 | Completed |
| Step 3 | Completed OR "(skipped)" based on visitedSteps |
| Step 4 (Generate) | Active, GenerationPanel with progress |
| Step 5 | Available |
| Stop button | Visible |
| Back button | Hidden during generation |

### At Generate (Stopped/Failed)
| Element | State |
|---------|-------|
| Step 4 (Generate) | Active, shows stopped/failed message |
| "Try Again" / "Retry" | Visible |
| Back button | Visible |

### At Generate (Idle - came back from PostProcess)
| Element | State |
|---------|-------|
| Step 4 (Generate) | Active, shows "Generation Complete" |
| Step 5 | Available |
| "Continue to Post-Process" | Should be visible? (CHECK THIS) |
| Back button | Visible |

### At PostProcess
| Element | State |
|---------|-------|
| Steps 1-2 | Completed |
| Step 3 | Completed OR "(skipped)" |
| Step 4 (Generate) | Completed, shows "Model generated" |
| Step 5 (PostProcess) | Active, PostProcessPanel visible |
| Back button | "Back to Generate" |

## Edge Cases to Verify

### Edge Case 1: Back from Generate with no model yet
- User at Generate, generation never started or was stopped
- Back should go to Segment or Touchup based on path
- No "Discard Model" warning needed

### Edge Case 2: Restore cached model then go back
- User restores cached model → at PostProcess
- Goes back to Generate → model should still be visible
- Goes back further → model cleared, cache preserved

### Edge Case 3: Generate fails immediately
- Generation starts but fails on first stage
- Should show failure state with retry option
- Back button should work

### Edge Case 4: Touchup visited but not edited
- User goes to Touchup, looks around, goes back
- Touchup removed from visitedSteps
- If user then generates from Segment, Touchup shows "(skipped)"

### Edge Case 5: Multiple back presses
- PostProcess → Generate → Touchup → Segment → Input
- Each back correctly uses previousVisitedStep
- State cleaned up progressively

## Issues Found & Fixed

### Issue 1: No "Continue" from Generate (completed) to PostProcess
When user goes back from PostProcess to Generate (with model intact), there's no button to proceed forward again. The only way forward is the automatic transition after generation.

**Status**: ✅ FIXED - Added "Continue to Post-Process" button in `generateContent` when model URL exists.

### Issue 2: GenerateSettings step appeared orphaned
Initially thought no UI path led to GenerateSettings.

**Status**: ✅ NOT AN ISSUE - Settings IS accessible via "Custom Settings" option in the preset dropdown menu. Step is now properly displayed in sidebar as step 4 (optional).

### Issue 3: Restore cached model skips Generate step visually
When restoring cached model, user goes directly to PostProcess. The Generate step shows as "completed" but user never saw generation progress.

**Status**: ✅ Acceptable - model exists, user can go back to see it.

### Issue 4: Back navigation ignored skipped optional steps
Original `goBack()` function went to the numerically previous step, ignoring whether optional steps were actually visited.

**Status**: ✅ FIXED - Added `previousVisitedStep()` function that respects `visitedSteps` tracking.

### Issue 5: Touchup warning showed even without edits
Warning dialog about losing touchup changes appeared even when user just entered and immediately left without editing.

**Status**: ✅ FIXED - Added `hasMaskEdits` flag that only triggers warning when actual edits were made.

### Issue 6: Back navigation assumed non-optional steps were always visited
The `previousVisitedStep()` function incorrectly returned non-optional steps even if they weren't visited. This caused issues with features like `restoreCachedGeneration()` that skip steps (e.g., going directly from Segment to PostProcess).

**Example bug scenario:**
1. User at Segment step
2. User clicks "Restore Previous Model" → jumps to PostProcess (skipping Generate)
3. User presses Back → incorrectly went to Generate (never visited) instead of Segment

**Root cause:** The logic `!c.isOptional || visitedSteps.contains(c)` assumed all mandatory steps were visited.

**Status**: ✅ FIXED - Changed `previousVisitedStep()` to only return steps that are actually in `visitedSteps`:
```swift
func previousVisitedStep(from step: Step) -> Step? {
    var candidate = step.previous
    while let c = candidate {
        if visitedSteps.contains(c) {
            return c
        }
        candidate = c.previous
    }
    return nil
}
```

This ensures "Back" always returns to the last step the user was actually on.
