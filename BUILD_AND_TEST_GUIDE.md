# Build and Test Guide - Setup Improvements

## Building the Project

1. **Add New Files to Xcode:**
   The following new files need to be added to your Xcode project:
   ```
   Modelr/Core/Services/ProcessTracker.swift
   Modelr/Core/Services/SetupStateManager.swift
   Modelr/Core/Services/NetworkMonitor.swift
   ```

2. **Framework Dependencies:**
   These files use standard frameworks already in your project:
   - `Foundation`
   - `AppKit` (NetworkMonitor uses Network framework)

3. **Expected Compiler Warnings:**
   - SourceKit may show some type resolution warnings during editing
   - These should resolve during actual build
   - If you see persistent errors, check that all files are added to the target

## Testing the Changes

### Quick Smoke Test

```bash
# 1. Build the project
# 2. Clear any existing setup state
rm -rf ~/Library/Application\ Support/Modelr/Config/setup_state.json

# 3. Run the app
# 4. Go through setup wizard
```

### Test 1: Process Cleanup
**What to test:** Verify no orphaned processes remain after cancel

```bash
# Terminal 1: Monitor processes
watch -n 1 'ps aux | grep -E "(python|uv)" | grep Modelr | grep -v grep'

# Terminal 2: Run app, start setup, then cancel

# Expected: All processes should terminate within 1-2 seconds of cancel
```

### Test 2: Network Handling
**What to test:** Setup detects offline state

```bash
# 1. Disconnect from network (turn off WiFi)
# 2. Launch app and try to start setup
# 3. Expected: Immediate error: "No internet connection"
# 4. Reconnect network
# 5. Click "Test Connection" button
# 6. Expected: "Connection to HuggingFace successful!"
```

### Test 3: Sleep Prevention
**What to test:** Mac doesn't sleep during setup

```bash
# 1. Set System Settings > Lock Screen > Turn display off after: 1 minute
# 2. Start setup
# 3. Don't touch Mac for 2 minutes
# 4. Expected: Display dims but Mac stays awake, setup continues
# 5. Setup completes or shows progress
```

### Test 4: Enhanced Error Messages
**What to test:** Errors show recovery suggestions

```bash
# 1. Simulate network error (disconnect mid-setup)
# 2. Wait for error screen
# 3. Expected:
#    - Clear error message
#    - Recovery suggestion shown with lightbulb icon
#    - "Retry", "View Logs", "Test Connection" buttons visible
# 4. Click "View Logs"
# 5. Expected: Finder opens to Logs directory
```

### Test 5: State Persistence
**What to test:** Setup state is saved

```bash
# 1. Start setup
# 2. While setup is running, force quit app (Cmd+Opt+Esc)
# 3. Check state file:
cat ~/Library/Application\ Support/Modelr/Config/setup_state.json

# Expected: JSON with completedStages array
# 4. Restart app
# 5. State should be loaded (check console logs)
```

## Verification Checklist

After building and testing:

- [ ] Project builds without errors
- [ ] Setup wizard launches
- [ ] Network check works (shows error when offline)
- [ ] Cancel button terminates all processes cleanly
- [ ] No orphaned Python/UV processes after cancel (`ps aux | grep`)
- [ ] Mac doesn't sleep during setup
- [ ] Error messages show recovery suggestions
- [ ] "View Logs" button opens Finder
- [ ] "Test Connection" button works
- [ ] Setup state persists across app restarts
- [ ] Sleep prevention activity ends after setup

## Debug Logging

All changes include extensive logging. To see debug output:

```bash
# Run from Xcode and watch console for:
[ProcessTracker] Tracking process: ...
[ProcessTracker] Killing PID ...
[NetworkMonitor] Connected via wifi
[SetupState] Saved state: current=...
[Setup] Cancelling setup...
[Setup] Setup cancelled successfully
```

## Known Issues After Phase 1

1. **Resume not fully functional:**
   - State is persisted but UI doesn't offer "Resume" option yet
   - Retry still restarts from beginning
   - Phase 2 will add full resume UI

2. **Progress still incomplete:**
   - Progress bar still mostly shows 0-60% range
   - HuggingFace download progress not tracked yet
   - Phase 2 will fix

3. **SourceKit warnings:**
   - You may see "Cannot find type" warnings in Xcode
   - These are false positives from SourceKit
   - Build will succeed

## Troubleshooting

### Issue: Build fails with "Cannot find type..."

**Solution:**
1. Clean build folder (Cmd+Shift+K)
2. Ensure all new files are added to the target
3. Check that no import statements are missing

### Issue: Processes not terminating on cancel

**Solution:**
1. Check console for "[ProcessTracker] Killing PID..." messages
2. Verify `processTracker` is wired up in `SetupWizardViewModel.init()`
3. Ensure `cancelDownload()` calls `processTracker.killAll()`

### Issue: Network check always fails

**Solution:**
1. Check that Network framework is linked
2. Verify you're not behind a restrictive firewall
3. Try the async version: `await NetworkMonitor.canReachHuggingFace()`

### Issue: Setup state not persisting

**Solution:**
1. Check permissions on Application Support directory
2. Verify state file path: `~/Library/Application Support/Modelr/Config/setup_state.json`
3. Check console for "[SetupState]" logs

## Next Steps After Successful Testing

Once testing is complete and all checks pass:

1. **Commit changes:**
   ```bash
   git add Modelr/Core/Services/ProcessTracker.swift
   git add Modelr/Core/Services/SetupStateManager.swift
   git add Modelr/Core/Services/NetworkMonitor.swift
   git add Modelr/Features/Setup/SetupWizardViewModel.swift
   git add Modelr/Core/Services/Python/PythonDependencyService.swift
   git add Modelr/Features/Setup/Views/SetupDownloadView.swift
   git commit -m "Phase 1: Setup flow improvements - process cleanup, network handling, error messages"
   ```

2. **Consider Phase 2:**
   - Review `SETUP_FLOW_ANALYSIS.md` for Phase 2 items
   - Prioritize based on user feedback
   - Full resume capability is highest priority

3. **Monitor production:**
   - Watch for setup failure rates
   - Check for orphaned process reports
   - Gather user feedback on error messages

## Support

If you encounter issues during testing:

1. Check console logs for error messages
2. Review the state file: `setup_state.json`
3. Check for orphaned processes: `ps aux | grep Modelr`
4. Verify logs directory has content: `~/Library/Application Support/Modelr/Logs/`
