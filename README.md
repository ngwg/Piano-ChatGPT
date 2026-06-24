# PianoAR

Head-mounted AR piano trainer for iPhone 16 Pro inserted into a Cardboard-style lens shell. See [CLAUDE.md](CLAUDE.md) for the full project brief, constraints, and phase plan.

## Status

**Phase 0** — minimal ARKit passthrough app. Confirms the lens shell setup is usable and the CI build/sideload loop works end to end before any piano-specific code exists.

## How this repo is built (no local Mac required)

There is no local Xcode in this checkout. The `.xcodeproj` is **not** committed — it is generated from [`project.yml`](project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen) inside GitHub Actions.

Edit Swift sources under `PianoAR/` and `project.yml`. Push. CI produces an unsigned `.ipa` artifact.

### To get a build on your phone

1. Push to `main` (or run the **Build unsigned IPA** workflow manually from the Actions tab).
2. Wait for the `macos-latest` build to finish (~5–10 min).
3. Download the `PianoAR-unsigned-ipa` artifact from the workflow run.
4. Open Sideloadly on your PC, drag in the IPA, sign with your Apple ID, install to your iPhone over USB.

### Sideloadly limits to be aware of (free Apple ID)

- Sideloaded apps **expire every 7 days** and need re-signing. Sideloadly's daemon can re-sign automatically if it's running and the phone is reachable.
- Max **3 sideloaded apps** installed simultaneously.
- Max **10 new App IDs per rolling 7 days** — don't change the bundle ID casually.
- A **paid $99/year Apple Developer account** removes the 7-day expiry. Recommended once you're iterating frequently.

## File layout

```
CLAUDE.md                       — full project brief for Claude Code
project.yml                     — XcodeGen project definition
PianoAR/                        — Swift sources
  PianoARApp.swift
  ContentView.swift
  ARSessionModel.swift
  ARPassthroughView.swift
.github/workflows/build.yml     — CI: generate project, build, export unsigned IPA
```
