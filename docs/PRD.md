# PRD: Tap — Native macOS MacBook Gesture App

**Status:** Draft
**Product:** A native macOS menu-bar utility
**Working title:** Tap
**Reference behavior:** [shortap.app](https://shortap.app/)
**Primary deliverable:** A reliable local app that turns taps on a supported MacBook chassis into configurable actions.

## 1. Product summary

Tap uses a MacBook's built-in accelerometer and gyroscope to recognize taps on the left or right side of the chassis. Users assign actions to six gesture slots:

- Left side: one tap, two taps, three taps
- Right side: one tap, two taps, three taps

Actions can include screenshots, clipboard operations, media controls, system controls, window management, application launches, URLs, and Apple Shortcuts.

The product is the native app. A marketing site, checkout page, and demo video are optional launch-support work and are not part of the core MVP.

## 1.1 Immediate next milestone: `TapProbe`

The next deliverable is a small Swift executable named `TapProbe`, not the finished menu-bar UI. It exists to prove the sensor path on real hardware before the app architecture and distribution model are finalized.

`TapProbe` must:

1. Enumerate `AppleSPUHIDDevice` interfaces dynamically.
2. Identify accelerometer and gyroscope candidates by usage page/usage rather than device index.
3. Attach HID input callbacks and validate report length before parsing.
4. Decode live XYZ samples with monotonic timestamps and sequence numbers.
5. Report observed cadence, axis orientation, raw range, and parser health.
6. Save short, user-initiated local traces for taps and normal-use motion without logging hardware serial numbers.
7. Test reconnect behavior after sleep/wake and report whether a normal signed process can open the devices.

The milestone passes only when live accelerometer and gyroscope samples are reliable on the first test MacBook, sample traces can be replayed, and the access/distribution model is understood. No production UI work should begin before this gate passes.

## 2. Product principles

1. **Reliable before clever.** A gesture that fires accidentally is worse than one that does not fire.
2. **Local by default.** Sensor readings, gesture configuration, and action mappings stay on the Mac.
3. **Native Mac experience.** The app should feel like a small, polished menu-bar utility rather than a web wrapper.
4. **Least privilege.** Ask for a system permission only when the selected action requires it, and explain why.
5. **Fail clearly.** Unsupported hardware, unavailable sensors, denied permissions, closed-lid state, and sleeping Macs must produce understandable status rather than silent failure.

## 3. Problem and opportunity

Mac users repeat small actions throughout the day: taking screenshots, muting audio, controlling music, switching windows, opening apps, and running automations. Keyboard shortcuts are fast but require reaching for the keyboard and remembering combinations.

Tap makes the sides of the MacBook an additional input surface. The product must make that input dependable across supported hardware, avoid reacting to normal typing or trackpad use, and let users configure useful actions without technical knowledge.

## 4. Goals

- Detect intentional one-, two-, and three-tap gestures on the left and right sides of supported MacBooks.
- Let users install Tap and start using it without a calibration exercise; the app performs any required baseline measurement silently.
- Let users configure all six gesture slots independently.
- Support a useful initial action catalog plus Apple Shortcuts.
- Run quietly in the background with low CPU, memory, and energy impact.
- Explain and manage required macOS permissions without requesting unnecessary access.
- Keep all normal operation local and avoid uploading raw motion data.
- Ship as a signed, notarized, installable macOS app.

## 5. Non-goals for the MVP

- iPhone, iPad, Windows, or Linux support.
- A browser-based gesture detector or web wrapper.
- Cloud accounts, cloud-synced gesture profiles, or raw sensor-data uploads.
- A public SDK or third-party plugin marketplace.
- Machine-learning model training in the cloud.
- Automatic support for every MacBook model before it has been physically tested.
- A full custom payment backend. Licensing and checkout are a separate commercial-release workstream.

## 6. Target users

### Primary users

- MacBook power users who already rely on keyboard shortcuts.
- Developers, designers, creators, and operators who frequently run repeatable actions.
- Users who prefer one-time software purchases and local-first utilities.

### User needs

- “I want a quick gesture for actions I repeat constantly.”
- “I want to know exactly when the app is listening and what it can access.”
- “I need to tune the app so typing and trackpad use do not trigger actions.”
- “I want to change a gesture without editing a config file.”

## 7. Core user journeys

### Journey A: First install

1. User opens Tap.
2. App identifies the Mac model, macOS version, processor family, and sensor availability.
3. App explains local sensor processing and any permissions needed for the first selected action.
4. App silently measures a short quiet baseline and loads its bundled directional model.
5. User optionally tests one gesture and sees the recognized side, tap count, and action result.
6. App places a status item in the menu bar and enables background recognition.

### Journey B: Configure a gesture

1. User opens the menu-bar popover and chooses Configure.
2. User selects one of the six gesture slots.
3. User chooses a built-in action or Apple Shortcut.
4. If needed, the app requests the relevant permission at the moment the action is enabled.
5. User saves and tests the gesture.

### Journey C: Use the app day to day

1. User taps the left or right side of the open MacBook.
2. Sensor data passes through normalization, filtering, side classification, and tap-count grouping.
3. The matching slot resolves to an action.
4. The app checks action permissions and executes once.
5. A subtle visual or notification confirmation is shown only when enabled by the user.

### Journey D: Troubleshoot a false positive

1. User opens Diagnostics from the menu-bar popover.
2. App shows sensor availability, current profile, last recognized gesture, and permission status.
3. User lowers sensitivity or restarts recognition; if side labels remain wrong, the user can start an optional guided side recalibration from Settings.
4. User can temporarily disable recognition or a specific slot without uninstalling the app.

## 8. MVP scope

### 8.1 App shell and lifecycle

| ID | Requirement | Priority |
|---|---|---|
| APP-01 | Run as a native menu-bar app with a clear enabled/disabled state. | P0 |
| APP-02 | Support launch at login, with the setting off or on based on an explicit user choice. | P0 |
| APP-03 | Start and stop sensor processing cleanly when the app is enabled, disabled, sleeping, waking, or quitting. | P0 |
| APP-04 | Use one coordinated sensor reader for the app rather than multiple competing HID streams or device handles. | P0 |
| APP-05 | Show the current support status: supported, starting, paused, permission blocked, or sensor unavailable. | P0 |
| APP-06 | Persist configuration safely across relaunches and app updates. | P0 |

### 8.2 Hardware and sensor feasibility

The first engineering milestone is a real-device feasibility spike. The current macOS SDK marks `CMMotionManager` as `API_UNAVAILABLE(macos)`, so the app cannot assume that Apple's normal Core Motion API is available to a Mac app. Local I/O Registry inspection on the development Mac exposed separate `AppleSPUHIDDevice` entries named `accel` and `gyro`, both with 22-byte input reports, vendor usage page `0xFF00`, and usages `3` and `9`. Independent Apple-Silicon implementations report reading those HID reports through IOKit, but this is an undocumented system interface and may require a privileged helper or special distribution treatment. The exact access path, permissions, hardware coverage, and release route must be proven before production architecture is locked. See the research notes in [ARCHITECTURE.md](ARCHITECTURE.md).

| ID | Requirement | Priority |
|---|---|---|
| SENSOR-01 | Verify live accelerometer and gyroscope access on each target MacBook/macOS combination. | P0 |
| SENSOR-02 | Record short local sensor traces during controlled taps, typing, trackpad use, desk vibration, carrying, and lid movement. | P0 |
| SENSOR-03 | Confirm whether direct IOKit HID access works in-process; if not, validate a signed privileged helper/XPC design and its impact on notarization, sandboxing, and distribution. | P0 |
| SENSOR-04 | Detect sensor availability before starting recognition and present a useful unsupported-device state. | P0 |
| SENSOR-05 | Normalize axes and orientation per device rather than assuming one coordinate layout fits every MacBook. | P0 |
| SENSOR-06 | Keep raw sensor traces local and delete diagnostic recordings unless the user explicitly exports them. | P0 |
| SENSOR-07 | Document the validated hardware matrix before publishing compatibility claims. | P0 |

The likely prototype path is a narrow IOKit HID adapter that matches `AppleSPUHIDDevice`, identifies the accelerometer and gyroscope by usage, validates report length and plausibility, and emits normalized samples behind `MotionSource`. Do not ship the whole app as root. If the sensor cannot be opened safely in-process, isolate only that access in a signed helper and communicate with the UI/recognizer over a constrained local IPC contract. Treat continued use of this undocumented interface as an explicit product and maintenance decision, not as a stable Apple API guarantee.

### Phase 0 implementation status — 2026-09-06

The initial `TapProbe` Swift executable is implemented. It dynamically enumerates HID devices, identifies the local `accel` and `gyro` interfaces, attaches callbacks, validates 22-byte reports, parses signed XYZ values, records newline-delimited JSON traces, and reports per-channel cadence and health. Parser smoke checks pass through `TapProbeCoreCheck`.

On the development MacBook Air, the initial passive callback run opened both sensor interfaces but observed zero input callbacks. The probe now activates the SPU driver by setting its reporting state, power state, and report interval before registering a timestamped callback. A non-root two-second run then received approximately 800 accelerometer and gyroscope reports per second and wrote live trace records. The sensor-feasibility gate passes for this development Mac and current OS session, subject to clean-boot, sleep/wake, hardware-matrix, signing, and future-macOS validation. Keep the UI process unprivileged; retain the signed helper/XPC design as a fallback rather than assuming it is required everywhere.

### Phase 1 implementation status — 2026-09-07

Recognition tuning now uses `0.05g` for High sensitivity, permits Custom values down to `0.02g`, accepts a guarded short low-energy pulse in the `0.02–0.03g` range, uses 75% recovery hysteresis, and re-arms after a timed-out movement once the signal falls below the rising-edge threshold.

The first calibration and tap-candidate slice is implemented behind the probe rather than the product UI. `TapProbeCore` now exposes a typed motion sample, a per-channel calibration profile, and a deterministic detector using baseline-subtracted acceleration, rising-edge/jerk evidence, a short recovery window, gyro support, an adaptive noise floor, hysteresis, and a refractory window. `TapProbe --detect` calibrates on the live MacBook and prints candidates; `TapReplay` runs the identical detector against a saved trace. The detector exposes Low/Medium/High sensitivity presets (`0.24g`, `0.18g`, and `0.05g`) plus a custom threshold down to `0.02g` for diagnostics; the native app now exposes these as user settings. The core now also includes a conservative labeled side-profile classifier and one/two/three-tap sequence aggregator.

The synthetic parser, calibration, side-classifier, and one/two/three-tap sequence checks pass. Live reports arrive at about 801 Hz per channel without `sudo`. The detector now accepts measured low-gyro chassis impulses when jerk reaches `1.5×` the jerk floor; recent valid taps measured `0.031–0.037g/sample` jerk but only about `1–3 deg/s` gyro. High sensitivity now uses a `0.05g` starting floor, Custom can be lowered to `0.02g`, recovery accepts a return below `75%` of the active threshold, and a timed-out candidate re-arms once the signal has fallen below the rising-edge threshold. At Custom `0.05g`, the latest same-posture captures replay 3/3 accepted left candidates as left and 10/10 accepted right candidates as right. Earlier flat traces remain 1/1 left and 4/4 right, while two quiet traces produce zero candidates. A single left/right centroid scored only 11/13 in-sample and 8/13 leave-one-out on the new set because right impacts can cross the detector threshold on either waveform lobe. The bundled development-MacBook classifier therefore models those two right-impact modes explicitly. The earlier 26-event profile's perfect result is no longer treated as side-validation evidence because its left/right gravity baselines reveal different laptop postures and therefore posture leakage. A larger same-posture physical set is still required for release acceptance. Tap events retain onset and peak acceleration/gyro vectors plus recovery duration for side profiling. Grouped one-, two-, and three-tap behavior remains covered by deterministic checks and prior real grouped replay.

The first left-labelled fixture is now captured at `/tmp/left-tap.jsonl`: 24,044 records (approximately 12,021 per channel) replayed into two accepted candidates at `0.10g`. This is sufficient as a first left-side sample, but it is not enough to infer a side boundary; a matching right-labelled fixture is still required.

The matching right-labelled fixture at `/tmp/right-tap.jsonl` contains 24,042 records and replays to one accepted candidate at `0.10g`. The current development captures require the High preset or a custom threshold; Medium (`0.18g`) intentionally rejects these lighter `0.16–0.20g` events. Sensitivity must therefore remain a first-class user setting rather than a hidden constant.

### Phase 2 vertical-slice implementation status — 2026-09-07

This phase supersedes the earlier downstream-work note in the Phase 1 paragraph: the native UI and the first permission-light action slice are now implemented, while the full action catalog and production hardening remain pending.

The first native product slice is now implemented. The Swift Package contains a `Tap` executable target that uses SwiftUI's macOS `MenuBarExtra` and `Settings` scenes. It exposes enabled/paused, starting, listening, and sensor-unavailable states without running the product as root. Recognition starts plug-and-play with a conservative flat-chassis model for the development MacBook Air when no saved profile exists. It requires a dominant vertical impulse, then separates negative-Z impacts using onset gyro X and positive-Z impacts using peak gyro magnitude. This handles the two observed right-impact waveform modes and returns `unknown` when evidence is weak or non-directional; first run does not ask users to perform left/right training. High sensitivity now starts at `0.05g`, Custom reaches `0.02g`, and incomplete timed-out movements no longer suppress later taps. If the bundled model does not fit a user's device or tap posture, Settings now offers an optional guided side recalibration that collects five accepted taps across each palm rest and saves only derived features locally. A short quiet baseline still runs silently in the recognition engine. Packaged builds also expose an explicit launch-at-login setting through `SMAppService.mainApp`; raw command-line builds report that the setting is unavailable because they do not have an app bundle. `TapProbeCore` now owns the reusable `AppleSPUHIDReader` boundary and `RecognitionSession`; the app receives typed samples/status instead of depending on IOKit types in the UI.

The app persists a versioned local Codable settings payload in `UserDefaults`. It includes Low/Medium/High/Custom sensitivity, the custom threshold, internal calibration/grouping/cooldown values, six left/right one/two/three-tap slots, an optional saved side profile, and the last derived baseline profile. The app performs a fresh quiet baseline when recognition starts, but that work is silent and never blocks first-run setup. The menu-bar popover and settings window expose diagnostics, live sensitivity controls, per-slot test actions, and a user-initiated redacted diagnostics export that excludes raw traces and shortcut names. Side-profile JSON remains a development/replay artifact rather than a normal user setup requirement.

Development tooling can export a derived side profile as local JSON for replay inspection or hardware-matrix work without exporting raw motion traces; normal users do not need to create or export one.

The first action slice contains confirmation feedback, screenshot, screenshot-to-clipboard, selected-area screenshot, Copy, Paste, Paste Without Formatting, Undo, Redo, mute/unmute, volume up/down, Music play/pause/next/previous, Toggle Wi-Fi, app launch, validated HTTP(S) URL opening, and Apple Shortcut execution. Each executor invokes a fixed local macOS executable with an argument array; it does not construct a shell command from user text. The Shortcut slot can refresh the local output of `/usr/bin/shortcuts list` into a picker while retaining manual name entry, and a missing shortcut is reported as a replace/refresh error rather than silently ignored. Screenshot actions use Core Graphics preflight/request APIs and expose a Privacy & Security recovery link when access is denied; keyboard actions declare Accessibility because they send shortcuts through System Events. Music and Shortcuts have no equivalent general preflight in this process, so failed command execution exposes an Automation recovery link naming the target app. Toggle Wi-Fi resolves the current Wi-Fi interface from `networksetup -listallhardwareports`, reads its state, and sends a fixed on/off argument without invoking a shell. A reusable-reader check streamed approximately 2,400 samples per channel in three seconds on the development MacBook Air without `sudo`.

The reusable guided side-calibration state machine remains implemented and covered by `TapProbeCoreCheck` for development/training and optional app recovery. The app uses `TapSideProfile.bundledDefault` when no saved profile is present and still fails closed for ambiguous classifications. Settings can invoke the state machine on demand when the bundled model is not a match; the resulting profile keeps individual calibrated examples from five taps per palm rest, persists locally, and is used on the next recognition session. `TapReplay --bundled-side-profile` runs the same fallback against local traces. Multi-tap candidates are grouped by timing before the gesture side is resolved by majority and confidence, so one noisy per-tap side result does not split a double or triple tap. The app uses a 120 ms internal refractory window and a 450 ms grouping window. Same-posture and cross-model validation of the bundled directional fallback remain acceptance tasks.

The repository also includes `Scripts/build-app.sh`, which assembles the Swift executable into a local `Tap.app` bundle with `LSUIElement=true` and a stable local development signature when one is available, falling back to ad-hoc signing otherwise. This is sufficient for local launch and menu-bar testing; Developer ID signing, notarization, update behavior, and clean-Mac installation remain release work.

The app now preflights Screen Recording access before executing screenshots, offers the system request path and an explicit Privacy & Security recovery link, and observes macOS system and display sleep/wake notifications. Recognition stops before sleep and creates a fresh reader/baseline session after wake. The reader also reports supported HID-service removal and the app makes bounded reconnect attempts without running as root. Music and Shortcuts surface target-specific Automation recovery after command failure; prompt/revocation acceptance on a clean app identity and physical sleep/removal recovery remain open hardening work.

### 8.3 Gesture recognition engine

The recognizer should be implemented as a deterministic, testable pipeline:

```text
sensor samples
  -> axis/orientation normalization
  -> noise and gravity filtering
  -> tap impulse candidate detection
  -> left/right side classification
  -> one/two/three-tap grouping window
  -> confidence and cooldown checks
  -> gesture-slot resolution
  -> permission guard and action execution
```

| ID | Requirement | Priority |
|---|---|---|
| GEST-01 | Detect a single intentional tap and identify its side. | P0 |
| GEST-02 | Group repeated taps within a configurable timing window into double or triple taps. | P0 |
| GEST-03 | Apply debounce and cooldown rules so one physical gesture dispatches at most once. | P0 |
| GEST-04 | Reject normal typing, trackpad clicks, routine desk vibration, and low-confidence motion by default. | P0 |
| GEST-05 | Support a user-adjustable sensitivity setting with safe default, low, medium, and high presets. | P0 |
| GEST-06 | Perform baseline calibration silently and start with a bundled directional model; keep per-device training out of the normal user flow. | P0 |
| GEST-07 | Pause or suppress recognition during states known to create unsafe false positives, such as unsupported sensor state, sleep, or closed-lid operation. | P0 |
| GEST-08 | Expose enough local diagnostics to explain why a gesture was accepted, rejected, or ambiguous without exposing raw data by default. | P1 |
| GEST-09 | Make thresholds and timing values data-driven so they can be tuned from replay tests rather than hard-coded across the UI. | P0 |

### 8.4 Gesture slots and configuration

| ID | Requirement | Priority |
|---|---|---|
| CONFIG-01 | Provide exactly six visible slots: left/right × one/two/three taps. | P0 |
| CONFIG-02 | Allow each slot to be enabled, disabled, or assigned an action independently. | P0 |
| CONFIG-03 | Show the current action and required permission state for every slot. | P0 |
| CONFIG-04 | Provide a “Test gesture” affordance that shows detected side and count before executing the action. | P0 |
| CONFIG-05 | Allow users to edit sensitivity, launch at login, feedback, and pause behavior; keep detector baseline, grouping, cooldown, and side-model parameters internal. | P0 |
| CONFIG-06 | Keep configuration versioned and migrate old settings safely after updates. | P1 |

Suggested initial example mapping, subject to hardware/action validation:

| Slot | Example action |
|---|---|
| Left, 1 tap | Mute/unmute audio |
| Left, 2 taps | Screenshot |
| Left, 3 taps | A validated screen-flash/utility action |
| Right, 1 tap | Run an Apple Shortcut |
| Right, 2 taps | Play/pause media |
| Right, 3 taps | Next track |

### 8.5 Built-in action catalog

The action catalog must be typed, searchable, permission-aware, and extensible. Each action should declare its identifier, display name, category, parameters, required permissions, availability conditions, and executor.

Initial categories:

- **Screenshots:** clipboard, desktop, selected area.
- **Clipboard:** copy, paste, paste without formatting, undo, redo.
- **Media and volume:** mute, volume up/down, play/pause, next track, previous track.
- **Input and display:** microphone mute, brightness up/down, keyboard backlight up/down, Focus.
- **Shortcuts and custom actions:** run Apple Shortcut, press a keyboard shortcut, open application, open URL.
- **Windows and workspaces:** Mission Control, Spotlight, Quick Note, minimize, close, split left/right, maximize, full screen, hide apps, spaces, app switcher, quit front app.
- **Lock and power:** lock screen, screen saver, sleep display.
- **Connectivity and utilities:** Wi-Fi, Bluetooth, eject disks, Empty Trash, battery status, weather, email.

Actions that depend on unavailable public APIs, unsupported permissions, or unsafe automation must be marked unavailable or moved out of the MVP rather than presented as working.

### 8.6 Apple Shortcuts integration

| ID | Requirement | Priority |
|---|---|---|
| SHORT-01 | Let a user assign an existing Apple Shortcut to any gesture slot. | P0 |
| SHORT-02 | Provide a shortcut picker or a clear refreshable list of available shortcuts. | P0 |
| SHORT-03 | Handle renamed, deleted, or unavailable shortcuts without crashing or silently doing nothing. | P0 |
| SHORT-04 | Explain any Automation permission prompt and provide a path to retry after permission changes. | P0 |
| SHORT-05 | Keep shortcut names and mappings local to the Mac. | P0 |

### 8.7 Permissions and privacy

The app should request permissions just in time, not as a large batch on first launch. macOS exposes separate privacy controls for Accessibility, Automation, Screen & System Audio Recording, Input Monitoring, Motion & Fitness, and related capabilities. See [Apple's macOS privacy settings guide](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac).

| Permission area | When it may be needed | Product behavior |
|---|---|---|
| Motion/sensor access | Sensor recognition, if required by the chosen macOS access path | Explain that motion data is processed locally; show status and retry path. |
| Accessibility | Simulated keyboard shortcuts, window controls, or other system control | Request only when the first affected action is enabled; link to the exact setting. |
| Automation | Running Shortcuts or controlling another app | Explain the target app and why control is needed. |
| Screen & System Audio Recording | Only if the selected screenshot implementation requires it | Do not request it for unrelated actions. |
| Input Monitoring | Required by the direct packaged-app `AppleSPUHIDDevice` reader on the development Mac; not requested by the command-line probe | Explain that it is used only to read the local MacBook motion sensors, provide a just-in-time request and Privacy & Security recovery path, and never run the app as root. |

Privacy requirements:

- No raw motion data leaves the Mac during normal use.
- No account is required to recognize gestures.
- No microphone, camera, contacts, location, or full-disk access unless a separately approved action genuinely needs it.
- Diagnostic export is explicit, user-initiated, and clearly labeled.
- The privacy screen states what is read, what is stored, and what is never transmitted.

### 8.8 Feedback and diagnostics

- Menu-bar icon state: active, paused, unsupported, permission blocked, or error.
- Optional on-screen confirmation showing the recognized gesture and action.
- Optional sound/notification feedback, off by default if disruptive.
- Last recognized gesture with timestamp and result.
- Sensor availability and active profile.
- Permission checklist with “Open Settings” actions.
- Optional test mode; baseline calibration is automatic and not a first-run setup step. An on-demand guided side recalibration is available as a troubleshooting recovery.
- Local diagnostic export with automatic redaction of personal paths, shortcut parameters, and sensitive data.

## 9. UX and screen requirements

### First-run wizard

1. Welcome and local-processing explanation.
2. Hardware and macOS support check.
3. Sensor availability check.
4. Silent baseline startup and bundled directional model load.
5. Permission setup for the first chosen action.
6. Optional test gesture.
7. Enable recognition and optional launch-at-login.

### Menu-bar popover

- Enabled/disabled toggle.
- Current device/support status.
- Six gesture slots in a compact two-column layout.
- Last recognized gesture.
- Configure, Diagnostics, Preferences, Help, Quit.

### Configuration window

- Six-slot gesture map.
- Action picker with search and categories.
- Action parameter controls.
- Required-permission badge and setup button.
- Test button.
- Sensitivity control only; timing and calibration controls remain internal.
- Optional guided left/right side recalibration for devices where the bundled directional profile is not a match.

### Preferences

- General: launch at login, enable/disable, feedback.
- Recognition: sensitivity. Tap grouping, cooldown, and baseline calibration are internal implementation details.
- Privacy: local-processing explanation, diagnostic export/delete.
- Permissions: current status and links to System Settings.
- About: app version, support, license, update channel.

## 10. Data model

```text
GestureSlot
  id: left-1 | left-2 | left-3 | right-1 | right-2 | right-3
  enabled: Bool
  actionID: String?
  actionParameters: Codable

RecognitionProfile
  deviceIdentifierHash: String
  sensitivityPreset: low | medium | high | custom
  thresholds: Codable
  tapGroupingWindowMs: Int
  cooldownMs: Int
  calibratedAt: Date

AppPreferences
  enabled: Bool
  launchAtLogin: Bool
  feedbackMode: none | visual | notification | sound
  diagnosticsConsent: Bool
```

Store configuration in a versioned local format with atomic writes. Avoid storing raw sensor traces except in explicit, temporary diagnostic recordings.

## 11. Technical architecture

Recommended native stack:

- Swift and SwiftUI for configuration and preferences.
- AppKit integration for menu-bar lifecycle and macOS-specific behaviors.
- An IOKit HID sensor adapter behind a `MotionSource` protocol; do not use `CMMotionManager` as the Mac implementation because the current macOS SDK marks it unavailable.
- A deterministic recognition engine independent of the UI.
- An `ActionRegistry` with one executor per built-in action.
- A permission manager that maps actions to macOS privacy requirements.
- Local persistence with versioned Codable models and Keychain only for license secrets if licensing is added.

Suggested module boundaries:

```text
AppShell
  MenuBarController
  OnboardingCoordinator
  SettingsWindow

Motion
  MotionSource
  AppleSPUHIDReader
  SensorHelper (only if direct access is not viable)
  SensorAvailability
  AxisNormalizer
  SignalFilter
  TapDetector
  TapAggregator
  CalibrationStore

Actions
  ActionDefinition
  ActionRegistry
  PermissionRequirement
  ActionExecutor
  ShortcutsExecutor

Infrastructure
  PreferencesStore
  PermissionManager
  DiagnosticsRecorder
  UpdateManager
  LicenseManager (commercial release)
```

The sensor implementation must remain replaceable. The default investigation path is `AppleSPUHIDDevice` through IOKit HID; Core Motion is not a viable Mac default based on the current SDK headers. If a helper is required, the UI remains an unprivileged process and receives only typed sensor samples/status over a narrow XPC interface. Any undocumented interface remains a release-blocking risk because it affects signing, notarization, App Store eligibility, maintenance, and user trust.

## 12. Performance and reliability targets

These are initial beta targets and should be revised after the sensor feasibility spike:

- At least 95% intentional gesture recognition in controlled tests on every supported hardware profile.
- Fewer than one false activation during a four-hour normal-work session in beta testing.
- P95 action dispatch begins within 250 ms for a single tap after the gesture is classified.
- No duplicate dispatch for one physical gesture.
- Average CPU and energy impact low enough that the app is not visibly burdensome in normal use; capture measurements on battery and AC power.
- App recovers from sleep/wake, lid open/close, user switching, and sensor unavailability without requiring a relaunch.
- A crashed action executor cannot crash the recognition service or disable configuration.

## 13. Security, packaging, and distribution

- Sign every release with Developer ID and notarize it before distribution. macOS Gatekeeper and notarization are part of the user trust model; see [Apple's guidance on safely opening Mac apps](https://support.apple.com/en-lamr/102445).
- Decide between direct notarized distribution and the Mac App Store after validating sensor access and required permissions.
- Minimize entitlements and explain every sensitive permission.
- Do not instruct users to bypass Gatekeeper or disable macOS security controls.
- Use an update channel with signed update metadata and rollback support.
- Include a reproducible build version, release notes, and support bundle version.

## 14. Testing strategy

### Hardware matrix

Start with a representative matrix, then expand only after measurement:

- MacBook Air and MacBook Pro.
- Multiple Apple silicon generations.
- Different chassis sizes where available.
- Supported macOS versions beginning at the declared minimum.
- AC power and battery operation.
- External display and docked/undocked states.

### Sensor test fixtures

Create a local replay harness that can feed recorded sensor samples into the recognition engine. Test fixtures should cover:

- clean one-, two-, and three-tap gestures on both sides;
- typing and trackpad use;
- palm resting on the chassis;
- desk vibration and transport;
- opening, closing, and moving the lid;
- sleep/wake and display lock;
- multiple users and fast app switching;
- ambiguous or overlapping motion.

### App tests

- Unit tests for filters, side classification, tap grouping, cooldown, calibration, and settings migration.
- Action tests with mocked executors and permission states.
- UI tests for onboarding, slot configuration, permissions, diagnostics, and reset flows.
- Fresh-install tests on a clean Mac user account.
- Signed/notarized install and update tests.
- Accessibility checks with keyboard navigation and VoiceOver for all configuration controls.

## 15. Delivery plan

### Phase 0: Sensor feasibility spike — release gate

- Build the `TapProbe` Swift executable with no product UI.
- Build an IOKit HID probe that enumerates `AppleSPUHIDDevice` and identifies the `accel` and `gyro` interfaces by usage page/usage rather than hard-coded device indexes.
- Parse and validate live reports on multiple Apple-Silicon MacBooks; record report lengths, sample cadence, axis orientation, scale, wake/sleep behavior, and power impact.
- Determine whether an ordinary signed app can open the interfaces; if not, prototype the smallest signed helper and local IPC boundary.
- Validate signing, notarization, sandboxing, permission prompts, and the intended distribution route before building the product UI.
- Record a go/no-go decision and publish the initial hardware matrix.

### Phase 1: Recognition engine

- Implement the sensor abstraction, normalization, filtering, tap detector, side classifier, aggregator, calibration, cooldown, and replay harness.
- Tune against recorded traces.
- Define measurable false-positive and missed-gesture thresholds.

### Phase 2: Native app shell and plug-and-play startup

- Build the menu-bar app, preferences window, six-slot configuration, local persistence, status states, and first-run permission explanation.
- Add sensor diagnostics and silent baseline startup; do not require user calibration.

### Phase 3: Action system and permissions

- Implement the initial built-in action catalog.
- Add Apple Shortcuts integration.
- Add just-in-time permission setup and recovery states.
- Verify every action on clean user accounts and supported macOS versions.

### Phase 4: Beta hardening

- Run hardware-matrix tests and replay suites.
- Measure CPU, memory, battery, latency, recognition rate, and false positives.
- Fix sleep/wake, lid, dock, permission, and update edge cases.

### Phase 5: Commercial release

- Add one-time licensing and 1/2/3-device activation if required.
- Add signed auto-update flow and support diagnostics.
- Produce Developer ID signed/notarized builds, release notes, privacy policy, terms, and support channels.
- Build the optional marketing site and hosted checkout only after the app behavior and compatibility claims are verified.

## 16. Success metrics

### Product metrics

- Activation completion rate.
- Time from first launch to first successful gesture.
- Gestures executed per active day.
- Slot customization rate.
- Shortcut-assignment rate.
- Disable/uninstall rate caused by false positives or permission friction.
- Support tickets by hardware model, macOS version, and action type.

### Quality metrics

- Intentional recognition rate by hardware profile.
- False activation rate during normal work.
- P95 gesture-to-action latency.
- Crash-free sessions.
- Average CPU/energy impact.
- Percentage of release builds successfully signed and notarized on the first attempt.

## 17. Acceptance criteria

The native MVP is ready for beta when:

1. The app runs as a native menu-bar utility on every device in the declared initial support matrix.
2. The feasibility report proves the chosen accelerometer/gyroscope access path works on those devices and is compatible with the chosen distribution route.
3. Users can enable Tap and optionally test a gesture without editing files, using Terminal, or performing calibration.
4. All six gesture slots can be configured independently.
5. Single, double, and triple taps are detected on both sides with no duplicate dispatch.
6. Normal typing, trackpad use, and ordinary desk vibration do not routinely trigger actions in the beta test protocol.
7. Every action declares its permission requirements and fails with an actionable explanation when permission is denied.
8. Apple Shortcuts can be assigned, run, renamed, deleted, and recovered from gracefully.
9. The app survives sleep/wake, lid state changes, display lock, relaunch, and settings migration.
10. Raw sensor data remains local during normal use, derived side calibration stays local, and diagnostic export is explicit and user-controlled.
11. The app is Developer ID signed and notarized; installation does not require bypassing macOS security protections.
12. Performance, crash, latency, recognition, and false-positive results are recorded for the supported hardware matrix.

## 18. Open decisions

1. Which MacBook models and macOS versions are in the first supported matrix?
2. Does the target macOS environment expose the required accelerometer/gyroscope data through a documented API, or is a different approved access path needed?
3. Will the first distribution be direct notarized download or the Mac App Store?
4. Which actions are P0 after accounting for Accessibility, Automation, Screen Recording, and other permissions?
5. What does “Flashlight” mean on MacBook, and is it feasible enough to ship as a default action?
6. Should the app provide visible feedback after every action, only during setup, or never by default?
7. Is licensing required for the technical MVP, or only for the commercial release?
8. Should settings remain local-only, or is optional iCloud/profile sync a future product direction?

## Definition of done

The actual app is complete for commercial release when the sensor path is proven on the declared MacBook matrix, tap recognition meets the beta quality targets, all P0 actions and permission flows work, local privacy behavior is verified, the app survives lifecycle edge cases, and the shipped build is signed, notarized, installable, and supportable. The website is optional launch infrastructure, not a substitute for the native app.
