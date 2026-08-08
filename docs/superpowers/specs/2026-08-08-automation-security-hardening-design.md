# Automation Security Hardening Design

**Date:** 2026-08-08  
**Status:** Proposed for implementation  
**Scope:** Browser control, local app control, profile extraction, logging, and Playwright setup

## Goal

Keep HeyDebby's useful automation automatic while making the capability boundary enforceable in code. Safe browser filling and a small set of harmless Mac actions continue without approval dialogs. Irreversible browser actions, secrets, arbitrary AppleScript, and unvalidated profile data are rejected rather than delegated to model judgment.

## Constraints

- Do not add an approval prompt before ordinary automated actions.
- Leave the visible browser open when the user must complete an action themselves.
- Do not add a runtime dependency.
- Do not change global Claude settings or affect Claude sessions launched outside HeyDebby.
- Preserve the current SwiftPM, self-check, and ad-hoc app build workflow.
- Treat the profile and scanned document output as private data.

## Decisions

### 1. Browser access is a per-run capability

`agentCommand` will receive the browser setting and include `mcp__playwright` only when browser control is enabled. Turning the toggle off therefore removes the tool from future agent invocations even if removing the globally registered MCP server is delayed or fails.

The setup command will pin Playwright MCP to `@playwright/mcp@0.0.79` instead of `@latest`. Registration remains user-scoped because that is how the existing Claude CLI discovers the server, but registration is no longer the authorization boundary.

Disabling browser control will await `claude mcp remove playwright --scope user` and report failure in the UI. A failed removal does not restore HeyDebby's capability because the per-run allowlist remains the primary gate.

### 2. Browser safety is enforced by an app-scoped Claude hook

Prompt instructions remain as guidance, but they are not the security control. When browser control is enabled, HeyDebby will generate a temporary Claude settings file for that run and pass it through `--settings`. The file registers a `PreToolUse` hook for `mcp__playwright` that invokes the current HeyDebby executable in a dedicated policy mode. The hook reads Claude's JSON event on standard input and returns an allow or deny decision on standard output.

This uses the existing app executable and Foundation JSON handling, so no script, package, or second service is required. The temporary settings file contains no credentials or profile values and is deleted when the run ends. It does not modify `~/.claude/settings.json`.

The policy uses an allowlist, not keyword-only blocking:

- Allow observation and reversible navigation: page inspection, snapshots, screenshots, scrolling, tab selection, back/forward navigation, and navigation to HTTP(S) URLs.
- Allow filling ordinary non-secret fields and selecting ordinary options.
- Allow reversible progression controls such as Next or Continue only when the action is not a final submission, purchase, authorization, or account mutation.
- Deny clicks whose target or accessible name represents Submit, Pay, Purchase, Buy, Place order, Confirm, Authorize, Sign, Delete, Send, Publish, Book, Reserve, or equivalent irreversible actions.
- Deny typing into password, payment-card, security-code, CVV/CVC, one-time-code, PIN, or CAPTCHA fields.
- Deny generic browser evaluation and arbitrary JavaScript execution.
- Deny CAPTCHA interaction, file upload, download initiation, permission prompts, and credential-manager interaction in the first implementation.
- Deny unknown Playwright tools or inputs by default.

Policy decisions are based on the MCP tool name and structured arguments, including role, label, field type, and requested text. Values are inspected only in memory and are never logged. Tests will use representative Playwright payload fixtures and prove that unknown shapes fail closed.

Browser-enabled runs will never use `--dangerously-skip-permissions`, even when the Full agent access setting is on. Full access continues to apply to non-browser runs. This prevents the broad mode from bypassing the browser boundary.

When the hook denies an irreversible action, its denial message directs the agent to stop and leave the browser open for the user. There is no approval dialog and no resume path that later performs the denied action. The user completes it directly in the visible browser.

This design relies on Claude Code's documented behavior that `PreToolUse` hooks execute before permission evaluation and can allow or deny a tool call. The installed CLI also exposes the per-run `--settings <file-or-json>` option. Reference: [Anthropic Claude Code CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage/).

### 3. App control uses typed actions, never model-authored code

The `RUN: <AppleScript>` protocol will be removed. The model may emit only an `ACTION:` JSON object matching a Codable enum. The initial automatic action set is intentionally small:

- `set_volume` with an integer from 0 through 100.
- `change_volume` with an integer delta from -20 through 20.
- `media` with `play_pause`, `next`, or `previous`, targeting only Music or Spotify.

`BeatSplitter` validates the complete payload and drops malformed, unknown, or out-of-range actions. `Control` converts a validated enum case into a hard-coded `osascript` argument list. No model-authored string reaches `osascript`, a shell, System Events, or an application name interpolation point.

The Claude agent allowlist will no longer grant `Bash(osascript:*)` when app control is enabled. Larger app tasks continue through the existing agent/Composio path. This closes both current arbitrary-AppleScript routes: direct `RUN:` beats and background-agent shell access.

### 4. Document extraction is private by construction

`AgentRunner.spawn` will accept an explicit logging policy:

- `.standard` records the command label, streamed output, and exit status as today.
- `.privateOutput(label:)` records only the supplied generic label and exit status. It still streams and buffers output for the caller but never writes the command, prompt, or child output to `DebbyLog`.

Document scanning uses `.privateOutput(label: "profile scan")`. The prompt will refer to the selected folder and output contract without copying extracted values into the command label.

The HeyDebby log directory will be created with mode `0700` and the log file with mode `0600`, including after rotation. Choosing Delete profile will remove both `profile.json` and the diagnostic log so previously created versions cannot leave the user's identity data behind. Failures are surfaced rather than silently reported as success.

### 5. Profile data has a strict schema and trusted provenance

`Profile` will decode the extracted JSON into typed data before writing it. The top-level object remains a flexible dictionary so future fields do not require a release, but every entry must have exactly this shape:

```json
{
  "full_name": {
    "value": "Example Name",
    "source": "/Users/example/Documents/passport.pdf"
  }
}
```

Validation rules:

- Field names use lower snake case and are between 1 and 64 characters.
- `value` and `source` are strings; values are non-empty after trimming, contain no control characters, and are capped at 4,096 characters.
- Sources are absolute, standardized file paths. A leading `~` is expanded before validation.
- Every source must exist as a regular file under one of the roots that the current scan was allowed to inspect.
- Default roots are Documents, Desktop, and Downloads. A custom scan uses only the user-selected directory.
- Symlinks are resolved before containment checks so a path cannot escape an allowed root.
- Empty profiles, extra entry properties, malformed JSON, invalid paths, and partially invalid profiles reject the entire scan.

The validated structure is re-encoded with stable formatting and atomically written at mode `0600`. The model's original JSON text is never persisted. This preserves flexible profile keys while preventing fabricated provenance or unexpected object shapes.

## Data and control flow

### Browser run

1. `AppState` snapshots the browser toggle for the new agent run.
2. `agentCommand` grants Playwright only for that run and disables permission bypass.
3. HeyDebby writes the private temporary settings file that points `PreToolUse` to the current executable's policy mode.
4. Claude requests a Playwright operation.
5. The policy parses the structured operation and automatically allows a known-safe action or denies everything else.
6. A denied final action leaves the browser open for direct user control; it is not resumable as an automated action.
7. Run cleanup deletes the temporary settings file.

### Profile scan

1. `AppState` resolves the permitted scan roots.
2. The agent scan runs under `.privateOutput`.
3. `Profile` extracts the candidate JSON, decodes it, and validates every field and resolved source path against those roots.
4. Only the typed, re-encoded result reaches `profile.json`.
5. The log contains only scan lifecycle metadata, never extracted values.

### Local app action

1. Claude emits `ACTION:` JSON only when app control is enabled.
2. `BeatSplitter` decodes and validates a known action.
3. `Control` maps the enum case to fixed AppleScript syntax and runs `/usr/bin/osascript` directly.
4. Unknown or malformed actions do not execute.

## Files expected to change

- `Sources/HeyDebby/AgentRunner.swift`: conditional capability grants, temporary settings integration, logging policy, pinned browser policy arguments.
- `Sources/HeyDebby/AppState.swift`: browser setup/removal behavior, private scan execution, delete error handling, and run cleanup.
- `Sources/HeyDebby/Beats.swift`: replace raw run beats with typed action beats.
- `Sources/HeyDebby/Claude.swift`: replace `RUN:` prompt documentation with the typed `ACTION:` contract.
- `Sources/HeyDebby/Control.swift`: map validated actions to hard-coded `osascript` arguments.
- `Sources/HeyDebby/Profile.swift`: typed schema, path normalization, source containment, and validated persistence.
- `Sources/HeyDebby/Log.swift`: file permissions, private lifecycle support, and deletion.
- `Sources/HeyDebby/UI.swift`: accurate browser copy and surfaced setup/removal/delete failures.
- `Sources/HeyDebby/main.swift`: focused self-check coverage for every policy boundary.
- A new small Swift source file may hold browser-policy parsing if keeping it in `AgentRunner.swift` would blur responsibilities.

## Testing strategy

All behavior changes will be test-first through the existing `--selfcheck` seam, supplemented by build and command-level smoke checks.

Required tests:

- Browser off omits Playwright; browser on includes it and a per-run settings file.
- Browser on suppresses dangerous permission bypass.
- The Playwright package version is exact and contains no `@latest`.
- Browser policy allows representative observation, navigation, filling, and reversible progression fixtures.
- Browser policy denies every irreversible, secret, CAPTCHA, script-evaluation, transfer, and unknown fixture.
- A malformed hook event fails closed without logging its payload.
- App action decoding accepts only the documented enum cases and bounds.
- Generated AppleScript comes only from fixed templates; raw AppleScript and `Bash(osascript:*)` are absent from prompts and commands.
- Private-output runs return output to their caller without writing it to a temporary test log.
- Log directory/file permissions remain `0700`/`0600`, including rotation.
- Profile validation accepts a valid in-root fixture and rejects schema errors, traversal, symlink escape, missing files, extra properties, and one-invalid-entry profiles.
- Deleting a profile removes both profile and log and reports filesystem failure.

Final verification:

- Run the focused self-check after each slice.
- Run `./build.sh` for debug self-check, release build, and signing.
- Inspect the generated Claude command for both toggle states without printing profile content.
- Run the browser policy executable mode directly with safe and denied JSON fixtures.
- Confirm `git diff --check` and review the final diff for accidental secrets or unrelated changes.

## Rollout and failure behavior

- Existing profiles are read only after passing the new schema. An invalid legacy profile is treated as unavailable and the UI asks for a rescan; it is not silently rewritten.
- If the browser policy settings file cannot be created, browser automation does not start.
- If the policy receives an unrecognized event, it denies the tool call.
- If Playwright registration or removal fails, the toggle is restored to its truthful state and the error is shown.
- If profile validation or persistence fails, the previous valid profile remains intact because writes are atomic and occur only after full validation.

## Out of scope

- Automatically entering passwords, card details, one-time codes, or CAPTCHA responses.
- Automatically completing final submissions or purchases.
- General-purpose AppleScript, System Events UI scripting, shell execution, or arbitrary application control.
- Cloud synchronization or server-side storage of the profile.
- Expanding the typed app action catalog beyond volume and media transport in this pass.
