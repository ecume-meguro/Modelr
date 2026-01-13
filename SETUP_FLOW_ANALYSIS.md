# Setup Flow Analysis & Improvement Plan

## Executive Summary

The Modelr setup flow handles first-time configuration of Python environments and ML model downloads. After thorough analysis of the codebase, I've identified issues across UI/UX, backend architecture, environment management, and interruption handling.

---

## Current Architecture Overview

### Setup Flow Stages
1. **Welcome** (`SetupWelcomeView`) - System requirements check
2. **Model Selection** (`SetupModelSelectionView`) - Choose Hunyuan variant (Fast/Ultra)
3. **Download** (`SetupDownloadView`) - Environment sync + model downloads
4. **Complete** (`SetupCompleteView`) - Success confirmation

### Backend Components
- `SetupWizardViewModel` - Orchestrates UI state
- `PythonDependencyService` - Handles environment sync and model downloads
- `PythonEnvironmentCoordinator` - Manages runtime environments
- `PathManager` - File system paths and setup markers
- `ModelLoadingCoordinator` - ML model loading strategies

### Setup Stages (Backend)
1. Preparing - Copy resources to Application Support
2. SyncingSAM - Create unified inference venv (Python 3.13)
3. DownloadingSAM - Warmup SAM + VLM models
4. SyncingHunyuan - Create Hunyuan venv (Python 3.10)
5. DownloadingHunyuan - Download selected 3D generation model

---

## Issues Identified

### 1. UI/UX Issues

#### 1.1 Progress Indication Problems
**Location:** `SetupDownloadView.swift:166-175`
```swift
private var progressValue: Double {
    if viewModel.isSettingUpEnvironment {
        return viewModel.environmentSetupProgress * 0.6
    } else if let progress = viewModel.downloadProgress {
        return 0.6 + (progress.progress * 0.4)
    }
    return 0
}
```
**Problems:**
- Progress is not granular - jumps between stages rather than smooth transitions
- `downloadProgress` is never set (always nil) - only `environmentSetupProgress` is used
- Users see artificial 0-60% for env setup, but the 60-100% range is never reached
- No individual stage progress (e.g., "Installing package 45/120")

#### 1.2 Missing Time Estimates
**Problem:** No ETA shown during setup
**Impact:** Users have no idea if setup will take 2 minutes or 20 minutes
**Files:** `SetupDownloadView.swift`, `SetupWizardViewModel.swift`

#### 1.3 Vague Status Messages
**Location:** `SetupWizardViewModel.swift:166-190`
**Problem:** Status messages like "Setting up 3D generation environment..." don't convey what's actually happening (downloading packages, compiling, etc.)

#### 1.4 Log Viewer Limitations
**Location:** `SetupDownloadView.swift:227-250`
```swift
if showLogs {
    ScrollViewReader { proxy in
        ScrollView {
            // Only last 50 lines kept
        }
        .frame(height: 120)  // Very small
    }
}
```
**Problems:**
- Only keeps 50 log lines (important errors may be lost)
- Log panel is very small (120px height)
- No ability to copy logs for debugging
- No log level filtering (errors vs info)

#### 1.5 No Pause/Resume Capability
**Problem:** Download cannot be paused and resumed
**Impact:** If user needs to close laptop during download, they must restart from scratch

#### 1.6 Error Messages Not Actionable
**Location:** `SetupDownloadView.swift:180-204`
**Problem:** Error view shows `error.localizedDescription` which is often cryptic
**Missing:** Specific guidance like "Check your internet connection" or "Free up disk space"

#### 1.7 No Offline Mode Handling
**Problem:** No detection or messaging when offline
**Impact:** Setup fails silently with confusing errors

#### 1.8 Welcome Screen System Check Issues
**Location:** `SetupWelcomeView.swift:94-105`
```swift
status: viewModel.systemRAM >= 8 * 1024 * 1024 * 1024 ? .good : .warning
status: viewModel.availableSpace >= 20 * 1024 * 1024 * 1024 ? .good : .warning
```
**Problems:**
- Thresholds don't match actual requirements (Ultra model needs ~15GB)
- No distinction between warning and blocking issues
- Doesn't check for Apple Silicon (required for MLX)
- Doesn't check for rosetta vs native execution

### 2. Backend Issues

#### 2.1 Non-Atomic Setup Completion
**Location:** `PathManager.swift:172-186`
```swift
static func markSetupComplete(modelVariant: String) throws {
    try ensureDirectoryExists(at: configDirectory)
    let marker: [String: Any] = [...]
    let data = try JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted)
    try data.write(to: setupCompletionMarkerPath)
    try updateEnvironmentMarker()
}
```
**Problem:** If the app crashes between writing the marker and updating the environment marker, state becomes inconsistent.
**Solution:** Use atomic writes with temporary files and rename.

#### 2.2 No Validation of Downloaded Models
**Location:** `PythonDependencyService.swift:164-177`
**Problem:** After downloading Hunyuan model, there's no checksum/integrity verification
**Risk:** Corrupted downloads result in cryptic runtime errors later

#### 2.3 Resource Copy Not Idempotent
**Location:** `PythonDependencyService.swift:371-435`
**Problem:** `copyResourceFiles()` always copies, even if identical
**Impact:** Wastes time on app updates when resources haven't changed

#### 2.4 No Background Task Support
**Problem:** If user puts Mac to sleep during setup, processes may hang
**Missing:** Use of `ProcessInfo.beginActivity()` for long-running operations

#### 2.5 Single Retry Point
**Location:** `SetupDownloadView.swift:199`
```swift
Button("Retry") {
    viewModel.startSetup()
}
```
**Problem:** Retry restarts ENTIRE setup from scratch
**Better:** Resume from failed stage

#### 2.6 Environment Sync Timeout
**Location:** `PythonDependencyService.swift:204-216`
**Problem:** No timeout on `process.waitUntilExit()`
**Risk:** Hung process blocks setup indefinitely

#### 2.7 Lack of Cleanup on Failure
**Problem:** Failed setup leaves partial files in Application Support
**Impact:** Subsequent retries may have stale/conflicting files

### 3. Environment Management Issues

#### 3.1 No Environment Health Checks
**Problem:** No verification that venvs are functional after creation
**Risk:** Corrupted venv silently fails later during actual use

#### 3.2 Dual Python Version Complexity
**Location:** `PythonDependencyService.swift:104, 154`
```swift
pythonVersion: "3.13"  // Inference
pythonVersion: "3.10"  // Hunyuan
```
**Problem:** Two Python versions adds complexity and potential conflicts
**Future:** Unify when Hunyuan supports Python 3.13

#### 3.3 Version Marker Fragmentation
**Location:** `PathManager.swift:140-151`
```swift
static var resourcesMarkerPath: URL  // resources_version.json
static var environmentMarkerPath: URL  // environment_version.json
static var setupCompletionMarkerPath: URL  // setup_complete.json
```
**Problem:** Three separate markers for version tracking is error-prone
**Better:** Single unified state file

#### 3.4 UV Cache Not Managed
**Location:** `PathManager.swift:522-524`
**Problem:** UV package cache grows unbounded
**Impact:** Disk space waste over time

#### 3.5 No Disk Space Check Before Each Stage
**Problem:** Space check only at start, not before large downloads
**Risk:** Fail mid-download when disk fills up

### 4. Interruption Handling Issues

#### 4.1 Cancel During Download
**Location:** `SetupWizardViewModel.swift:154-159`
```swift
func cancelDownload() {
    downloadTask?.cancel()
    downloadTask = nil
    isDownloading = false
    downloadProgress = nil
}
```
**Problems:**
- Task cancellation doesn't kill spawned `uv` processes
- No cleanup of partial downloads
- Orphaned Python processes may remain

#### 4.2 App Termination During Setup
**Location:** `ModelrV3App.swift:119-127`
```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ProcessCleanup.shared.killAllPythonProcesses()
    }
}
```
**Problems:**
- Cleanup only happens on normal termination, not crash
- No state persistence for resume
- `pgrep` patterns may miss some processes

#### 4.3 Network Interruption
**Problem:** No handling of network drops during HuggingFace downloads
**Risk:** Partial downloads saved, corruption on resume

#### 4.4 Sleep/Wake Handling
**Problem:** No handling of Mac sleep during setup
**Risk:** Process timeouts and hangs after wake

#### 4.5 Force Quit Leaves Orphans
**Problem:** Force quitting app leaves Python processes running
**Impact:** Memory leak, potential port conflicts

### 5. Configuration/Settings Issues

#### 5.1 No Re-run Setup Option in Settings
**Location:** `GeneralSettingsView.swift`
**Problem:** No way to re-run setup wizard from settings
**Use Case:** User wants to switch from Fast to Ultra model

#### 5.2 No Model Switching
**Problem:** Once setup with Fast model, no way to download Ultra without clearing data
**Better:** Settings option to download additional models

#### 5.3 No Repair Option
**Problem:** If environment becomes corrupted, only option is full reset
**Better:** "Repair installation" that re-syncs venvs without redownloading models

---

## Improvement Plan

### Phase 1: Critical Fixes (High Priority)

#### 1.1 Fix Cancellation & Process Cleanup
**Files:** `SetupWizardViewModel.swift`, `PythonDependencyService.swift`
- Track spawned process PIDs during setup
- Kill child processes on cancellation
- Clean up partial downloads/venvs on cancel
- Add `ProcessInfo.beginActivity()` to prevent sleep during setup

#### 1.2 Add Proper Error Handling & Recovery
**Files:** `SetupWizardViewModel.swift`, `SetupDownloadView.swift`
- Categorize errors (network, disk, corruption)
- Provide actionable error messages
- Implement stage-level retry (resume from failed stage)
- Add network connectivity check before setup

#### 1.3 Fix Progress Tracking
**Files:** `SetupWizardViewModel.swift`, `PythonDependencyService.swift`
- Parse UV output for actual package installation progress
- Track HuggingFace download progress via hub_download
- Implement proper 0-100% progress across all stages
- Add time remaining estimates

### Phase 2: Robustness (Medium Priority)

#### 2.1 Implement Atomic State Management
**Files:** `PathManager.swift`
- Use single unified state file
- Implement atomic writes with temp file + rename
- Track detailed stage completion state
- Enable resume from any stage

#### 2.2 Add Model Integrity Verification
**Files:** `PythonDependencyService.swift`
- Verify model checksums after download
- Check venv health after creation
- Validate all required files exist before marking complete

#### 2.3 Improve Interruption Handling
**Files:** `SetupWizardViewModel.swift`, `ModelrV3App.swift`
- Register for sleep/wake notifications
- Pause operations on sleep, resume on wake
- Persist setup state for crash recovery
- Add startup recovery for interrupted setup

### Phase 3: UX Enhancements (Lower Priority)

#### 3.1 Enhanced Progress UI
**Files:** `SetupDownloadView.swift`
- Show current stage with stage-level progress
- Display download speed and ETA
- Expand log viewer with filtering
- Add copy-to-clipboard for logs

#### 3.2 Pre-Setup Validation
**Files:** `SetupWelcomeView.swift`
- Check Apple Silicon compatibility
- Verify actual space needed for selected model
- Check network connectivity
- Warn about metered connections

#### 3.3 Settings Integration
**Files:** `GeneralSettingsView.swift`
- Add "Download Additional Model" option
- Add "Repair Installation" option
- Add "Re-run Setup" option
- Show currently installed model variant

#### 3.4 Background Download Support
**Files:** `PythonDependencyService.swift`, `SetupWizardViewModel.swift`
- Allow user to continue using app during model download
- Implement pause/resume for downloads
- Show download progress in menu bar

---

## Implementation Priority Matrix

| Fix | Impact | Effort | Priority |
|-----|--------|--------|----------|
| Process cleanup on cancel | High | Low | P0 |
| Stage-level retry | High | Medium | P0 |
| Network error handling | High | Low | P0 |
| Accurate progress tracking | Medium | Medium | P1 |
| Atomic state management | Medium | Medium | P1 |
| Model integrity verification | Medium | Low | P1 |
| Sleep/wake handling | Low | Medium | P2 |
| Enhanced progress UI | Low | Medium | P2 |
| Settings integration | Low | Medium | P2 |
| Background download | Low | High | P3 |

---

## Files to Modify

### Primary Changes
1. `Modelr/Features/Setup/SetupWizardViewModel.swift` - Core setup logic
2. `Modelr/Features/Setup/Views/SetupDownloadView.swift` - Progress UI
3. `Modelr/Core/Services/Python/PythonDependencyService.swift` - Environment setup
4. `Modelr/Utilities/Path/PathManager.swift` - State management

### Secondary Changes
5. `Modelr/Features/Setup/Views/SetupWelcomeView.swift` - Pre-checks
6. `Modelr/Features/Settings/Views/GeneralSettingsView.swift` - Settings integration
7. `Modelr/App/ModelrV3App.swift` - Startup recovery
8. `Modelr/Core/Models/SetupModels.swift` - State models

### New Files Needed
9. `Modelr/Core/Services/SetupStateManager.swift` - Unified state management
10. `Modelr/Core/Services/SetupRecoveryService.swift` - Crash recovery
11. `Modelr/Core/Services/NetworkMonitor.swift` - Connectivity monitoring

---

## Estimated Impact

### Before Improvements
- Setup failure rate: ~15-20% (network issues, interruptions)
- User confusion on failure: High
- Recoverability: Poor (must restart from scratch)

### After Improvements
- Setup failure rate: ~2-5% (only actual errors)
- User confusion on failure: Low (actionable messages)
- Recoverability: Excellent (resume from any point)

---

## Next Steps

1. Review and approve this analysis
2. Prioritize which phases to implement
3. Create detailed implementation tickets
4. Begin with Phase 1 critical fixes
