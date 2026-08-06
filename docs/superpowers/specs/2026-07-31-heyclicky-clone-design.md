# HeyClicky Clone — Design

2026-07-31

## What HeyClicky is (research summary)

HeyClicky (heyclicky.com, YC Spring 2026) is a Mac-native "AI buddy": press a hotkey,
it screenshots your screen, you talk to it by voice, it answers out loud, draws
annotations on screen to point at UI elements, and can spawn background agents
("hey clicky agent …") to do tasks. Privacy-positioned: screenshots never stored.
Requires macOS 14.2+.

## Approach

Native Swift menu-bar app, zero dependencies. Every feature maps to a native API:

| HeyClicky feature | This clone |
|---|---|
| Hotkey activation | Carbon `RegisterEventHotKey` (⌥Space) — no Accessibility permission needed |
| Sees your screen | ScreenCaptureKit `SCScreenshotManager` (own windows excluded) |
| Talk mode (voice in) | `SFSpeechRecognizer` live transcription, auto-send on 1.6s silence |
| Speaks answers | `AVSpeechSynthesizer` (best installed en voice) |
| AI brain | Switchable: Codex subscription (OpenHands-style — reuses `~/.codex/auth.json` OAuth token against the ChatGPT Codex responses endpoint, model from `~/.codex/config.toml`) or Anthropic Messages API (default `claude-sonnet-5`). Auto prefers Codex when logged in |
| Screen drawing | Model returns `ANNOTATIONS: [{x,y,label}]` (normalized top-left coords); transparent click-through overlay window draws pulsing pointers, auto-hides after 8s |
| Background agents | `claude -p <task>` via `Process`, screenshot path passed as context, output streamed into panel. Optional "full access" toggle adds `--dangerously-skip-permissions` (off by default) |
| Sits next to cursor | Non-activating borderless `NSPanel` shown at mouse location |
| Privacy | Screenshot captured only at ask-time, kept as one overwritten temp file; text history capped at 20 turns |

Rejected alternatives: Electron (heavy, un-Mac-like), Python/pyobjc (fragile
permissions story). Native Swift is both the laziest and the most faithful.

## Components

- `main.swift` — app bootstrap, `AppDelegate`, menu-bar item, `--selfcheck`
- `AppState.swift` — @MainActor orchestration: listen → capture → ask → speak/annotate; agent routing (`agentTask(from:)`)
- `Hotkey.swift` — ⌥Space global hotkey
- `Capture.swift` — screenshot → JPEG base64 + temp file
- `Claude.swift` — API client, system prompt, `ANNOTATIONS:` parser
- `Speech.swift` — STT (silence auto-finalize) + TTS
- `AgentRunner.swift` — background `claude -p` process, streamed output
- `UI.swift` — floating panel (SwiftUI), settings popover (API key, model, voice, agent access), overlay window

## Error handling

API/permission errors surface as chat messages with the fix (e.g. grant Screen
Recording and relaunch). Agent launch failure prints install hint. Missing API
key prompts for settings; falls back to `ANTHROPIC_API_KEY` env.

## Testing

`HeyClicky --selfcheck` asserts the pure logic: annotation parsing, agent-trigger
detection, shell quoting. Everything else is OS-integration, verified by running.

## Deliberate cuts (add when needed)

Wake-word ("hey clicky" always-listening), streaming API responses, multi-display
overlay, configurable hotkey, Windows. All noted in README.
