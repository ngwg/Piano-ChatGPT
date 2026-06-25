# PianoAR

Head-mounted AR piano trainer for iPhone 16 Pro inserted into a Cardboard-style lens shell. See [AGENTS.md](AGENTS.md) or [CLAUDE.md](CLAUDE.md) for the full project brief, constraints, and phase plan.

## Status

Phase 5 prototype:

- ARKit passthrough with LiDAR-backed world tracking.
- Virtual keyboard placement on detected horizontal surfaces.
- Real-piano four-corner calibration path.
- Vision hand-pose tracking with LiDAR depth sampling.
- Falling-note/highlight guide driven by the simple JSON song format.
- Vision-based press detection using fingertip depth and trajectory.
- Microphone note/onset hinting for debug, key flashes, and confidence boosting.

The microphone detector is a confidence signal, not MIDI-grade ground truth. Real-device testing on the target iPhone is still required after every phase gate.

## How this repo is built

There is no local Xcode loop in this Windows checkout. The `.xcodeproj` is not committed; it is generated from [`project.yml`](project.yml) by XcodeGen inside GitHub Actions.

Edit Swift sources under `PianoAR/` and `project.yml`. Push to `main`. CI produces an unsigned `.ipa` artifact.

## To get a build on the phone

1. Push to `main`, or run the **Build unsigned IPA** workflow manually from the Actions tab.
2. Wait for the `macos-latest` build to finish.
3. Download the `PianoAR-unsigned-ipa` artifact from the workflow run.
4. Open Sideloadly on the PC, drag in the IPA, sign with the Apple ID, and install to the iPhone over USB.

## Sideloadly limits

- Free Apple ID installs expire after 7 days and need re-signing.
- Free Apple IDs allow at most 3 sideloaded apps installed at once.
- Free Apple IDs allow at most 10 new App IDs per rolling 7 days.
- A paid Apple Developer account removes the 7-day expiry and is worth considering once iteration speed matters.

## File layout

```text
AGENTS.md                       project brief for Codex/agent runs
CLAUDE.md                       same project brief for Claude Code
project.yml                     XcodeGen project definition
PianoAR/                        Swift sources
  PianoARApp.swift
  ContentView.swift
  ARSessionModel.swift
  ARPassthroughView.swift
  AudioPitchDetector.swift
  PressDetector.swift
.github/workflows/build.yml     CI: generate project, build, export unsigned IPA
```
