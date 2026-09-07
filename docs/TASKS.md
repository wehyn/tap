# Tap implementation tasks

**Updated:** 2026-09-07
**Current milestone:** hardware acceptance, permission recovery, and distribution hardening

## Completed

- [x] Research MacBook accelerometer and gyroscope access on macOS.
- [x] Confirm the development Mac exposes `AppleSPUHIDDevice` `accel` and `gyro` interfaces.
- [x] Implement dynamic IOKit HID enumeration and 22-byte report parsing.
- [x] Activate the SPU sensor driver before registering timestamped callbacks.
- [x] Record local NDJSON traces and replay them offline.
- [x] Verify non-root live streaming at approximately 800 Hz per channel.
- [x] Add quiet-window calibration for accelerometer and gyro baselines.
- [x] Add deterministic tap detection with jerk, gyro support, rising-edge gating, recovery-window validation, noise-floor adaptation, and cooldown.
- [x] Add `TapProbeCoreCheck` coverage for parsing, calibration, sensitivity ordering, impulse recovery, refractory behavior, and one/two/three-tap grouping.
- [x] Add `TapProbe --sensitivity low|medium|high` and custom `--threshold-g VALUE` controls.
- [x] Capture and replay labeled development fixtures: `/tmp/left-tap.jsonl` (2 candidates at `0.10g`) and `/tmp/right-tap.jsonl` (1 candidate at `0.10g`).
- [x] Validate a High-sensitivity live/replay run: `/tmp/tap-high.jsonl` replayed to 4 candidates at `0.10g`.
- [x] Add a conservative `TapSideClassifier`/`TapSideProfile` that returns `unknown` until both sides have enough labeled samples and a clear distance margin.
- [x] Preserve onset and peak acceleration/gyro directions plus recovery duration as side-classification features.
- [x] Add `TapTrain` to build a JSON side profile from labeled left/right traces.
- [x] Add `TapSequenceAggregator` for one-, two-, and three-tap grouping with a configurable 450 ms window.
- [x] Expose side-profile loading and grouped-gesture output in `TapProbe` and `TapReplay`.
- [x] Verify replay emits a two-tap gesture from the real `/tmp/tap-session-010.jsonl` fixture; its side remains `unknown` because that session is unlabeled.
- [x] Add `TapTrain` separation reporting, leave-one-out validation, and verbose replay distances so a sample-count-complete profile is not mistaken for a validated profile.
- [x] Extract a reusable `AppleSPUHIDReader` and `RecognitionSession` boundary for the product app.
- [x] Add a native `Tap` SwiftUI menu-bar target with enabled, paused, starting, listening, and sensor-unavailable states.
- [x] Make normal recognition plug-and-play by using a bundled directional fallback when no saved side profile exists; retain guided calibration as an optional recovery/training tool outside first-run setup.
- [x] Replace the threshold-dependent onset-polarity fallback with a flat-chassis two-mode classifier for the development MacBook Air: negative-Z impacts use onset gyro X, while positive-Z impacts use peak gyro magnitude; conflicting events still resolve to `unknown`.
- [x] Reproduce and fix the left-to-right inversion using same-posture captures. At Custom `0.05g`, the bundled app classifier now replays 3/3 accepted left events as left and 10/10 accepted right events as right; the earlier flat traces remain 1/1 left and 4/4 right.
- [x] Relax the low-gyro impulse support gate from `2×` to `1.5×` the jerk floor after live taps measured only `1–3 deg/s` gyro but `0.031–0.037g/sample` jerk.
- [x] Make High sensitivity usable for lighter palm-rest impulses, relax the recovery hysteresis, and re-arm after a timed-out movement so later taps are not suppressed.
- [x] Add a guarded very-sensitive low-energy impulse path for short palm-rest taps while retaining negative coverage for sustained typing, trackpad, vibration, carrying, lid, and palm-contact motion.
- [x] Add `TapReplay --bundled-side-profile` so saved traces can exercise the exact profile used by Tap.app.
- [x] Reduce the internal tap refractory window from 250 ms to 120 ms so normal fast double and triple taps reach the sequence grouper.
- [x] Group candidates by timing before resolving side; use majority/confidence across the full sequence so one `unknown` or inconsistent side result does not split a multi-tap gesture.
- [x] Persist sensitivity, custom threshold, calibration duration, grouping window, cooldown, six gesture slots, side profile data, and derived calibration data locally.
- [x] Add sensitivity controls, diagnostics, and per-slot test controls; keep side-profile import/export available only to development tooling.
- [x] Add the first permission-light action executors: confirmation feedback and validated HTTP(S) URL opening.
- [x] Add a deterministic guided side-calibration state machine and optional in-app recovery flow; keep its prompts out of first-run setup.
- [x] Verify the reusable app reader non-root for three seconds: approximately 2,400 accelerometer and 2,400 gyroscope samples on the development MacBook Air.
- [x] Add a local `Tap.app` bundle builder with `LSUIElement` and stable local development signing when an identity is available, with an ad-hoc fallback.
- [x] Add an optional packaged-app launch-at-login setting through `SMAppService.mainApp`, including approval and unavailable states.

## Next recognition work

- [x] Capture at least 3 accepted left and 3 accepted right events; the current labeled set has 11 left and 15 right events and produces a structurally usable profile.
- [x] Re-audit the old 26-event `tap-side-profile-v4` result and invalidate it as a shipping profile: its left and right calibration gravity vectors show the Mac was held at different postures, so the perfect split included posture leakage.
- [x] Verify side-labeled replay emits one-, two-, and three-tap groups within the 450 ms window; `/tmp/left-taps-3.jsonl` produces classified 1-, 2-, and 3-tap gestures.
- [ ] Expand the current same-posture flat-desk set beyond 3 accepted left and 10 accepted right events, including varied tap strength, exact edge position, typing/trackpad negatives, and repeated sessions.
- [x] Add guided calibration prompts for left and right taps instead of relying on manually labeled files.
- [ ] Validate the bundled directional fallback across additional MacBook models and replace it with a hardware-model profile matrix where axes differ.
- [x] Add deterministic negative fixtures for typing, trackpad use, palm contact, carrying, desk vibration, and lid movement to TapProbeCoreCheck; physical recordings remain part of hardware acceptance.
- [ ] Tune sensitivity presets against labeled positives and normal-use negatives on more than one MacBook; current development captures require High or Custom.

## Product app work

- [x] Create the native menu-bar app shell and enabled/paused/unsupported states.
- [x] Make first run plug-and-play: explain local processing without asking users to perform calibration or import a profile.
- [x] Persist sensitivity, cooldown, grouping window, six gesture slots, the optional saved side profile, and derived baseline data locally. Recognition still measures a quiet baseline silently on enable.
- [x] Add a sensitivity control with Low, Medium, High, and Custom modes plus per-slot test actions.
- [x] Add diagnostics showing sensor health, calibration state, last candidate, completed gesture count/side, and recognition feedback.
- [x] Add user-initiated redacted diagnostics export without raw motion traces or shortcut names.
- [x] Add left/right one/two/three gesture-slot configuration.
- [x] Add an independent enabled switch for every gesture slot with backward-compatible settings migration.
- [x] Keep side-profile export/import in the development CLI path for replay and diagnostics; do not expose it in the normal first-run flow.
- [x] Add an optional in-app left/right recalibration flow that saves a derived local profile and immediately resumes normal recognition.
- [x] Preserve multiple calibrated side examples and accept guarded non-vertical palm-rest impulses without labeling low-evidence motion.
- [x] Group the built-in action picker by category so the expanded catalog remains usable.
- [x] Add the first action executors: screenshot, screenshot-to-clipboard, selected-area screenshot, Copy, Paste, Paste Without Formatting, Undo, Redo, mute, volume up/down, media play/pause/next/previous, Toggle Wi-Fi, app launch, URL, and Apple Shortcut. Commands use fixed macOS executables and argument arrays; per-action permission notes are shown in Settings.
- [x] Add a refreshable local Apple Shortcut list and picker while preserving manual shortcut-name entry.
- [x] Treat renamed or deleted shortcuts as an actionable missing-shortcut state instead of misreporting them as permission failures.
- [x] Add Screen Recording preflight/request behavior for screenshots, a retry control for unavailable sensors, and an in-app Privacy & Security recovery link.
- [x] Add HID-specific `IOHIDCheckAccess`/`IOHIDRequestAccess` handling and explicit TCC diagnostics for packaged-app access to the internal Apple SPU HID sensors; recover stale bundle permission entries by re-adding the current app bundle.
- [x] Add actionable Automation-permission recovery after Music or Shortcuts execution fails.
- [x] Pause the reader before system or display sleep and restart it after wake; preserve a manual retry path for sensor access failures.
- [x] Detect supported HID-service removal and schedule bounded in-app reconnect attempts without running the app as root.
- [ ] Validate Automation prompts and revoked-permission recovery on a clean app identity.
- [ ] Exercise sleep/wake and unexpected sensor-service reconnect on hardware; verify no duplicate readers or callbacks.
- [ ] Decide and validate direct distribution versus a signed sensor helper/XPC fallback.
- [ ] Build, sign, notarize, and test a distributable app on a clean Mac.

## Sensitivity contract

The current detector exposes conservative starting points based on the development MacBook. Same-posture live captures at Custom `0.05g` now replay 3/3 accepted left candidates as left and 10/10 accepted right candidates as right. Earlier flat-desk traces remain 1/1 left and 4/4 right, and two quiet captures produce zero candidates. This is regression evidence, not yet a release-sized acceptance set.

| Setting | Dynamic acceleration floor | Intended behavior |
|---|---:|---|
| Low | `0.24g` | Fewer false positives; requires a firmer tap. |
| Medium | `0.18g` | Default balanced setting. |
| High | `0.05g` | Detects lighter taps; more sensitive to normal motion. |
| Custom | User value | Tuning and diagnostics only until validated. |

The internal quiet baseline can raise the effective floor when the sensor is noisy, but it is never a user task. The app UI exposes sensitivity as the only recognition-tuning control and preserves the selected setting across relaunches.

## Verification commands

```bash
swift build
swift run TapProbeCoreCheck
./Scripts/build-app.sh debug
swift run TapProbe --list
swift run TapTrain --left /tmp/left-tap.jsonl --right /tmp/right-tap.jsonl
swift run TapTrain --left /tmp/left-tap-1.jsonl --left /tmp/left-tap-2.jsonl --right /tmp/right-tap-1.jsonl --right /tmp/right-tap-2.jsonl
swift run TapReplay --trace /tmp/left-tap.jsonl --sensitivity high
swift run TapReplay --trace /tmp/right-tap.jsonl --sensitivity high
swift run TapReplay --trace /tmp/tap-high.jsonl --sensitivity high --group --side-profile /tmp/tap-side-profile.json
swift run TapReplay --trace /tmp/left-taps-3.jsonl --sensitivity high --side-profile /tmp/tap-side-profile-v3.json --group --verbose
```
