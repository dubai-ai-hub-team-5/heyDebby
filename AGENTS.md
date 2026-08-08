# HeyDebby Project Rules

## Verification

Run after source changes:

```bash
swift test
.build/debug/HeyDebby --selfcheck
./build.sh
```

`./build.sh` runs the debug build, self-check, SwiftPM tests, release build, app-bundle assembly, and signing.

## Architecture

- `AppState.swift` owns main-actor UI orchestration.
- `ScreenWatchCoordinator.swift` owns the proactive watch loop.
- Intervention model output is accepted only through strict source-ID resolution in `Intervention.swift`.
- Browser operations remain constrained by `BrowserPolicy.swift`; never bypass it for intervention handoffs.
- Local app control uses typed `ACTION:` beats only.
- API credentials live in Keychain through `SecretStore.swift`, never UserDefaults or source.
- Screen captures use purpose-specific policies and owned temporary files in `Capture.swift`.
- Apple Speech and AssemblyAI implement `TranscriptionProvider`.
- Multi-monitor watch context is intentionally deferred.

## Demo

The investor scenario uses Google Slides, Google Sheets, and a Gmail draft. `--demo-scenario investor-revenue` enables scripted intervention mode while Google Workspace remains online. Command+Shift+K mutes or resumes proactive output.
