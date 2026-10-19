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
| N | keep the Spotify song info on screen (otherwise it shows for 10 s per track) |

Wavedrop remembers your last settings between launches: style mode, preset, lock, pinned panels, shortcut list, beat-sync offset, window size and full screen.

## Spotify song info

When Spotify or Apple Music is playing, Wavedrop shows the song title, artist, album and cover art in the top-left corner for 10 seconds whenever the track changes (press **N** to keep it on screen). The visuals' colours also lean toward the cover's dominant colour. The first time, macOS asks whether Wavedrop may control Spotify; it only reads the current track.

## Full screen when Spotify plays

Wavedrop installs a login item that starts it hidden in the background: no window, no Dock icon and no audio capture. When Spotify starts playing, Wavedrop opens full screen. After Spotify has been paused or stopped for 20 seconds, it leaves full screen and hides again. **Esc** sends it back right away. Closing the window also just hides it; **⌘Q** quits until the next login. Both behaviours can be turned off in the app menu (*Full Screen When Spotify Plays*, *Open at Login*). The login item is `~/Library/LaunchAgents/local.wavedrop.visualizer.login.plist` and is only installed for the copy in `/Applications`. Background events are logged to `~/Library/Logs/Wavedrop.log`.

## How it handles different genres

- **Beat tracking:** spectral-flux onsets are autocorrelated to estimate tempo, and a phase-locked beat clock keeps the visuals pulsing on the beat even when the kick drops out. Beat phase follows the low end so off-beat hi-hats can't take it over.
- **Auto style:** a "rhythm" score (how clear and percussive the pulse is) blends between two behaviours:
  - *Pulse (electronic):* zoom and rotation kicks on every beat, flashes on downbeats, preset changes on 16-beat phrase boundaries, and a hard cut plus flash when a drop hits after a breakdown.
  - *Flow (classical):* motion speed follows the dynamics (calm in pianissimo, wild in fortissimo), note onsets cause soft ripples, colours follow the harmony (dominant pitch classes on the circle of fifths), and presets morph slowly over 6–9 s at section changes.

## Signing (one-time)

Run `scripts/make-signing-cert.sh` once. It creates a local code-signing certificate so macOS keeps Wavedrop's audio and Automation permissions across rebuilds. Without it, `build.sh` falls back to ad-hoc signing. `scripts/make-icon.sh` regenerates the app icon from a rendered frame.

## Developer flags

- `--demo` uses a built-in synthetic signal instead of system audio.
- `--selftest` prints the tempo, phase and style detected on synthetic test signals.
- `--snapshot out.png` renders every preset offscreen into one contact sheet.
- `--record <seconds> <out.wav>` captures system audio. Run it as `open -a /Applications/Wavedrop.app --args --record 40 /path/clip.wav` so the app's own permission applies.
- `--analyze <file>` reports tempo, rhythm score, bar position and beat-vs-kick alignment for an audio file.
- `--burst-test out.png` renders frames before and during the track-change shockwave.
