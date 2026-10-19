# Wavedrop

A MilkDrop-style music visualizer for macOS (14.2+). It listens to whatever your Mac is playing and drives feedback-warp visuals with beat tracking.

## Build & run

```bash
./build.sh && open /Applications/Wavedrop.app
```

`build.sh` builds `build/Wavedrop.app` and installs a copy into `/Applications`, quitting a running copy first. Pass `--no-install` to only build.

On first launch macOS asks for **System Audio Recording** permission. If you miss the prompt, enable Wavedrop under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then relaunch. After a rebuild macOS may ask again because the app is ad-hoc signed.

## Keys

| Key | Action |
| --- | --- |
| ← / → / Space | previous / next preset |
| M | style: Auto → Electronic → Classical |
| L | lock the current preset |
| F / Return / double-click | full screen (Esc exits) |
| H | pin the status panel |
| K | show / hide the on-screen shortcut list (shown by default) |
| [ / ] | nudge beat sync −/+10 ms |

## How it handles different genres

- **Beat tracking:** spectral-flux onsets are autocorrelated to estimate tempo, and a phase-locked beat clock keeps the visuals pulsing on the beat even when the kick drops out. Beat phase follows the low end so off-beat hi-hats can't take it over.
- **Auto style:** a "rhythm" score (how clear and percussive the pulse is) blends between two behaviours:
  - *Pulse (electronic):* zoom and rotation kicks on every beat, flashes on downbeats, preset changes on 16-beat phrase boundaries, and a hard cut plus flash when a drop hits after a breakdown.
  - *Flow (classical):* motion speed follows the dynamics (calm in pianissimo, wild in fortissimo), note onsets cause soft ripples, colours follow the harmony (dominant pitch classes on the circle of fifths), and presets morph slowly over 6–9 s at section changes.

## Developer flags

- `--demo` uses a built-in synthetic signal instead of system audio.
- `--selftest` prints the tempo, phase and style detected on synthetic test signals.
- `--snapshot out.png` renders every preset offscreen into one contact sheet.
