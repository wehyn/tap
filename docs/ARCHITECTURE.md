# Architecture: Tap Native macOS App

**Status:** Research-backed draft with native app vertical slice
**Scope:** Native macOS menu-bar utility that detects taps on an Apple-Silicon MacBook chassis and dispatches configured actions.
**Last researched:** 2026-09-07

## 1. Executive decision

The app should not be designed around Apple's normal `Core Motion` entry point. The local macOS SDK header marks `CMMotionManager` as `API_UNAVAILABLE(macos)`. On the development Mac, I/O Registry inspection found the internal IMU exposed as separate `AppleSPUHIDDevice` HID interfaces named `accel` and `gyro`.

The working architecture is therefore:

1. A narrow IOKit HID sensor adapter reads the Apple SPU's accelerometer and gyroscope reports.
2. The adapter converts raw reports into a typed, timestamped sensor stream.
3. A deterministic recognition pipeline filters motion, identifies tap impulses, infers left/right side, and groups one/two/three taps.
4. A local action layer maps the recognized gesture to a built-in action or Apple Shortcut.
5. The UI remains unprivileged. If the sensor cannot be opened safely in-process, only the sensor reader moves into a signed helper; the rest of the app never runs as root.

This is the implementation direction, not an Apple-supported API guarantee. The feasibility probe and distribution test are release gates.

## 2. What the sensors measure

### 2.1 Accelerometer

An accelerometer is a three-axis MEMS sensor. A tiny proof mass is suspended inside the chip. When the package accelerates, the mass shifts relative to the frame; the sensor measures the resulting change in capacitance and reports acceleration along X, Y, and Z.

Important consequences for Tap:

- An accelerometer measures **specific force**, so gravity appears in the signal. A stationary laptop normally has a vector whose magnitude is close to 1 g; a freely falling device approaches 0 g.
- A tap is a short mechanical impulse transferred through the chassis. It appears as a transient change in the acceleration waveform, often with ringing after the initial impact.
- The raw axes are attached to the sensor/package, not to the user's idea of “left” and “right.” The app needs a per-device coordinate mapping and calibration.
- Bias, noise, temperature, mounting, desk surface, and chassis flex all affect the observed waveform.

Bosch's general IMU documentation describes capacitive MEMS acceleration sensing and the distinction between acceleration and free fall. The exact sensor model inside every MacBook must not be treated as confirmed until validated on the target hardware.

### 2.2 Gyroscope

A gyroscope measures angular velocity, not position. In a MEMS gyro, a driven vibrating mass experiences a Coriolis force when the package rotates. The sensor converts that deflection into angular-rate values around three axes.

Important consequences for Tap:

- A stationary laptop should report near-zero angular rate, apart from bias and noise.
- A tap can create a tiny twist or rocking motion in the chassis. The gyro can help distinguish an impulse's rotational signature from normal acceleration, but it does not directly tell us which side was tapped.
- Integrating angular rate to estimate orientation accumulates drift. For short tap events, gyro features are more useful for event classification and rotation rejection than for long-term orientation.

### 2.3 Six-axis IMU behavior

The accelerometer and gyro together form a six-degree-of-freedom inertial measurement unit: three linear-acceleration axes plus three angular-rate axes. On platforms where Core Motion is available, Apple's sensor-fusion layer can separate gravity from user acceleration and provide attitude. That is not the expected MacBook path here, so the app must perform only the filtering and calibration it actually needs.

For Tap, the first recognizer should remain deliberately simple:

```text
raw accel + raw gyro
  -> timestamp/order validation
  -> axis normalization
  -> bias and baseline estimation
  -> dynamic-acceleration / angular-rate features
  -> impact candidate
  -> side classifier
  -> one/two/three-tap grouping
  -> confidence + cooldown gate
  -> configured action
```

Do not begin with a machine-learning model. A deterministic recognizer with recorded sensor fixtures is easier to debug, tune, explain, and keep private. A learned classifier can be considered only after the signal and hardware matrix are understood.

## 3. Mac-specific research

### 3.1 Core Motion is not the MacBook implementation

The current local SDK header at:

```text
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/CMMotionManager.h
```

declares:

```text
COREMOTION_EXPORT API_AVAILABLE(ios(4.0)) API_UNAVAILABLE(macos)
@interface CMMotionManager : NSObject
```

Therefore `CMMotionManager`, `CMDeviceMotion`, and their usual iOS sampling flow should not be the assumed production solution for a Mac app.

### 3.2 Observed Apple Silicon HID devices

On the development Mac, this read-only command:

```bash
ioreg -r -n AppleSPUHIDDevice -l -w0
```

showed internal HID devices with these relevant properties:

| Observed property | Accelerometer | Gyroscope |
|---|---:|---:|
| Product | `accel` | `gyro` |
| Transport | `SPU` | `SPU` |
| Usage page | `0xFF00` | `0xFF00` |
| Usage | `3` | `9` |
| Maximum input report | `22` bytes | `22` bytes |
| Built-in | Yes | Yes |

The report descriptor and device names are internal implementation details, not a stable public contract. They are useful for the probe and must be detected dynamically rather than assumed by device index.

### 3.3 What independent implementations suggest

Open-source Apple-Silicon projects report that the same `AppleSPUHIDDevice` interface exposes a three-axis accelerometer and gyroscope. Their observed path uses IOKit HID callbacks, vendor usage page `0xFF00`, usage `3` for acceleration, usage `9` for gyro, and 22-byte reports. One implementation documents Q16-style values scaled by `65536` and roughly 100 Hz after decimation; these values are implementation observations, not facts to hard-code before measuring our target devices.

Some projects use a privileged sensor daemon because ordinary HID access is restricted in their setup. This creates three possible packaging modes:

| Mode | Purpose | Decision |
|---|---|---|
| In-process IOKit reader | Fastest prototype and simplest local architecture | Try first on a clean signed build |
| Signed sensor helper + XPC | Commercial direct-download fallback if direct access is restricted | Prototype only if needed; UI stays unprivileged |
| Mac App Store target | Broadest distribution but highest API/entitlement risk | Do not promise until sensor access is proven |

The app must not silently run the complete product as root or instruct users to disable macOS protections.

## 4. System architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Tap.app — unprivileged native UI and product process                │
│                                                                     │
│  MenuBarController   Onboarding   Settings   Diagnostics            │
│          │                │           │          │                   │
│          └────────────────┴───────────┴──────────┘                   │
│                           │                                          │
│                    GestureCoordinator                               │
│             ┌─────────────┴─────────────┐                            │
│             │                           │                            │
│       RecognitionEngine            ActionRouter                      │
│             │                           │                            │
│  normalize → filter → impact      permission gate                    │
│  → side → count → confidence       → executor                        │
│             │                           │                            │
│             └──────────────┬────────────┘                            │
│                            │                                         │
│                    MotionSample stream                              │
└────────────────────────────┼────────────────────────────────────────┘
                             │ direct adapter or constrained XPC
              ┌──────────────┴────────────────┐
              │                               │
       AppleSPUHIDReader              TapSensorHelper (fallback)
       IOKit HID callbacks              IOKit HID callbacks
              │                               │
              └──────────────┬────────────────┘
                             │
                    AppleSPUHIDDevice
                    accel + gyro reports
```

### Process boundary rule

The default prototype is one app with a replaceable `MotionSource` abstraction. If opening the HID devices requires elevated access, split only the sensor reader into a small signed helper:

- `Tap.app` owns UI, recognition, settings, permissions, and action execution.
- `TapSensorHelper` owns device enumeration, HID callbacks, report parsing, and reconnects.
- The IPC contract carries typed samples, health/status, and bounded error codes only.
- The helper cannot execute shell commands, control other apps, or receive arbitrary commands from the UI.
- The UI never runs as root.

The helper's installer, authorization path, launch-at-login behavior, signing, update behavior, and uninstall behavior require a separate security review.

## 5. Module boundaries

### App shell

- `TapApp`: process entry point and lifecycle.
- `MenuBarController`: status item, popover, enable/disable state.
- `OnboardingCoordinator`: first-run hardware and permission explanation; baseline startup is automatic and side training is not user-facing.
- `SettingsWindow`: six-slot configuration, sensitivity, and preferences.
- `DiagnosticsWindow`: sensor health, last event, baseline status, and local export.

### Motion input

- `MotionSource`: async stream of typed sensor samples.
- `AppleSPUHIDReader`: IOKit HID enumeration and callbacks.
- `SensorHelperClient`: XPC-backed `MotionSource` if a helper is required.
- `ReportMatcher`: matches usage page, usage, product, report length, and plausible payload.
- `ReportParser`: converts 22-byte reports into signed XYZ values without assuming a device index.
- `UnitConverter`: explicit raw-to-physical-unit conversion, configured from measured device behavior.
- `DeviceIdentity`: stable non-secret hardware profile key; never persist raw serial numbers.
- `SensorHealth`: availability, reconnects, dropped reports, cadence, and parser errors.

### Recognition engine

- `AxisNormalizer`: maps sensor axes into a canonical device frame.
- `BaselineEstimator`: learns stationary bias and noise floor.
- `DynamicMotionFilter`: removes slow gravity/bias components while preserving short impulses.
- `ImpactDetector`: identifies candidate tap events.
- `SideClassifier`: infers left/right from calibrated waveform and rotational features.
- `TapSequenceAggregator`: groups candidates into one, two, or three taps.
- `ConfidenceGate`: rejects ambiguous or low-confidence events.
- `CooldownController`: prevents duplicate dispatch and retriggering from chassis ringing.
- `RecognitionProfileStore`: stores per-device calibration and thresholds.

### Actions and permissions

- `ActionDefinition`: stable ID, label, category, parameters, availability, permission requirements.
- `ActionRegistry`: built-in catalog and feature flags.
- `PermissionManager`: checks Accessibility, Automation, Screen Recording, Input Monitoring, and other relevant macOS controls.
- `ActionRouter`: maps a recognized slot to an action.
- `ActionExecutor`: isolated executor for each action family.
- `ShortcutsExecutor`: launches and reports Apple Shortcut success/failure.
- `FeedbackController`: optional visual, notification, or sound confirmation.

### Storage and support

- `PreferencesStore`: versioned local settings with atomic writes.
- `CalibrationStore`: per-device profiles and calibration metadata.
- `DiagnosticsRecorder`: bounded in-memory history; raw traces only on explicit user request.
- `SupportBundleExporter`: redacts paths, shortcut parameters, and identifiers before export.
- `LicenseManager`: separate commercial-release module; never part of sensor hot path.

## 6. Sensor ingestion design

### 6.1 Enumeration

The reader should discover devices using IOKit HID matching and inspect properties at runtime:

- `AppleSPUHIDDevice` class/product.
- Vendor-defined usage page `0xFF00`.
- Usage `3` for the accelerometer candidate.
- Usage `9` for the gyroscope candidate.
- Expected report size and descriptor shape.

The reader must handle multiple `AppleSPUHIDDevice` entries, unknown products, reordered devices, and future report descriptors. It should reject a candidate if the report length or decoded vector is implausible.

### 6.2 Report parsing

The parser must:

1. Validate report length before reading offsets.
2. Decode signed little-endian integer components.
3. Preserve the original monotonic timestamp and sequence number.
4. Convert to canonical units only in one clearly tested layer.
5. Emit parser errors and drop malformed samples rather than guessing.
6. Keep raw bytes out of logs by default.

The current community observation is that the 22-byte report contains three XYZ values beginning at byte offset 6 and that values are Q16-like. Treat those offsets and scale as probe findings to verify, not as a public specification.

### 6.3 Sample contract

```swift
struct MotionSample: Sendable {
    enum Channel: Sendable { case accelerometer, gyroscope }

    let monotonicNanoseconds: UInt64
    let sequence: UInt64
    let channel: Channel
    let x: Double
    let y: Double
    let z: Double
    let deviceProfile: String
}
```

Use monotonic time for event windows. Do not use wall-clock time to group taps. Keep the channel and units explicit so acceleration and angular rate cannot be accidentally combined as if they were the same measurement.

### 6.4 Implemented feasibility probe status

The first implementation is now in the repository as a Swift Package:

| Target | Responsibility |
|---|---|
| `TapProbeCore` | Typed channels, 22-byte report validation, signed little-endian XYZ parsing, Q16-style scaling, and NDJSON trace records. |
| `TapProbe` | IOKit HID enumeration, callback registration, sample statistics, verbose samples, and local trace recording. |
| `Tap` | Native SwiftUI menu-bar app, local settings, bundled plug-and-play side model, diagnostics, and gesture-slot test actions. |
| `TapReaderCheck` | Three-second non-root smoke check for the reusable product reader on real hardware. |
| `TapProbeCoreCheck` | Command-Line-Tools-compatible parser smoke checks for signed values, scaling, and short-report rejection. |

The reader enumerates all HID devices and filters locally because the development machine exposes the relevant usage reliably through the primary-usage properties. It accepts only `SPU` devices whose product is `accel` or `gyro`, usage page is `0xFF00`, usage is `3` or `9`, and maximum input report size is at least 22 bytes. This avoids mistaking an unrelated FIFO HID device for the accelerometer.

The initial passive-callback run on the development MacBook Air found and opened both `accel` and `gyro` but produced zero reports. The missing step was an SPU activation request before callback registration: set `SensorPropertyReportingState`, `SensorPropertyPowerState`, and `ReportInterval` on the matching `AppleSPUHIDDriver` services. After adding that kickstart and using the timestamped HID callback, a non-root two-second run succeeded with both channels at approximately 800 Hz and wrote live trace records. The current development Mac does not require `sudo` for this path, but the activation properties are undocumented and must be revalidated across clean boots, hardware, and macOS releases. A signed helper/XPC path remains the fallback if those writes or direct callbacks are restricted elsewhere.

Local verification currently passes with `swift build`, `swift run TapProbeCoreCheck`, `swift run TapReaderCheck`, `swift run TapProbe --list`, and a live non-root `TapProbe` run. `TapReaderCheck` uses the same reusable reader boundary as the app and observed approximately 2,400 accelerometer and 2,400 gyroscope samples in three seconds on the development MacBook Air. The installed Command Line Tools do not include the public XCTest runtime, so the parser check is an executable target until full Xcode is available.

### 6.5 Implemented calibration and recognizer core

The first recognition slice is now implemented in `TapProbeCore/Recognition.swift`:

- `MotionCalibrator` estimates per-axis resting means and standard deviations for both channels during a quiet window.
- `TapDetector` subtracts the accelerometer and gyro baselines, requires a rising acceleration edge plus jerk evidence, waits for the impulse to recover below 75% within a 150 ms window, uses angular rate only as supporting evidence, and applies a 120 ms refractory period. When gyro is below `8 deg/s`, jerk must reach `1.5×` the normal jerk floor; this accepts measured sharp low-rotation taps while sustained rotation or vibration remains insufficient on its own. At the very-sensitive `0.02–0.03g` range, a guarded short-pulse path accepts lower consecutive-sample jerk only when the peak is at least `1.25×` the active threshold and recovery completes within 80 ms. A candidate that times out after the signal has fallen below the rising-edge threshold re-arms the detector so one incomplete movement cannot suppress later taps.
- The dynamic threshold fails closed when the calibration window is noisy: it is at least the configured threshold and is raised to four times the measured accelerometer noise magnitude.
- `TapProbe --detect` (or `--calibrate SECONDS`) runs the calibration window live and prints accepted tap candidates without executing actions. `--threshold-g VALUE` overrides the conservative 0.18 g floor for controlled tuning.
- `TapSensitivity` exposes low/medium/high presets (`0.24g`, `0.18g`, and `0.05g` starting floors); the native settings UI maps directly to these presets, while custom thresholds down to `0.02g` remain available for diagnostics and lighter hardware responses.
- `TapReplay --trace PATH` replays a local NDJSON capture through the same detector, so threshold changes can be checked without touching the HID devices.
- `TapSideClassifier` learns normalized onset and peak acceleration/gyro direction centroids plus recovery duration from labeled events. It requires at least three samples per side plus a distance margin before returning left or right. Ambiguous or under-trained profiles return `unknown`.
- `TapSideProfile` remains readable across the prototype schema change: older profiles without onset vectors or recovery duration default onset to peak and recovery to zero.
- `TapTrain --left PATH --right PATH` writes a JSON `TapSideProfile` and reports labeled replay separation; `TapProbe` and `TapReplay` can load it with `--side-profile PATH`.
- `TapSequenceAggregator` groups candidates into one, two, or three taps using a 450 ms monotonic-time window before resolving the gesture side. A majority vote handles three-tap side jitter; tied two-tap labels use confidence and remain `unknown` when the result is still ambiguous. `--group` exposes the result in the probe and replay tools.

The old 11-left/15-right training set produced `26/26` in-sample and leave-one-out separation, but a later audit found materially different gravity baselines: the left recording was tilted while the right recording was nearly flat. That result therefore includes posture leakage and is not a valid shipping profile. The latest same-posture set contains 3 accepted left and 10 accepted right events at Custom `0.05g`. A single centroid scored only `11/13` in-sample and `8/13` leave-one-out because right impacts can cross the threshold on either a positive or negative vertical lobe. The bundled development-MacBook fallback now models both modes: negative-Z events compare onset gyro X against left/right prototypes, while positive-Z events compare peak gyro magnitude. It replays the set as 3/3 left and 10/10 right; earlier flat traces remain 1/1 left and 4/4 right, while two quiet traces emit no candidates. `TapReplay --bundled-side-profile --verbose` exercises the exact app fallback and prints distances and waveform fields. This fixes the observed inversion but does not replace the pending larger same-posture and cross-model acceptance set.

### 6.6 Native app vertical slice — 2026-09-07

The `Tap` target is the first product process built on the typed motion boundary. Its SwiftUI `MenuBarExtra` provides the menu-bar popover, while a `Settings` scene provides the configuration window. `TapAppModel` owns lifecycle state and remains the only UI-facing owner of the reader; `AppMotionRuntime` keeps recognition and sample counters behind a lock so the HID callback does not publish every sensor sample into SwiftUI. Recognition starts plug-and-play: the model supplies `TapSideProfile.bundledDefault` when no saved profile exists, and the engine performs only a silent quiet-window baseline. High sensitivity now starts at `0.05g`, Custom reaches `0.02g`, recovery hysteresis is less strict, and a timed-out movement no longer leaves later taps disarmed. If the bundled profile does not match a device or tap posture, Settings can run the existing `GuidedSideCalibration` flow on demand; it collects five accepted taps across each palm rest, stores both derived profile features and individual examples, and restarts normal recognition. This is a recovery action rather than a first-run requirement. Packaged builds use `SMAppService.mainApp` for the user-controlled launch-at-login setting and show unavailable/approval states when macOS cannot register the current process.

The app stores a versioned Codable settings payload in `UserDefaults`. It stores sensitivity, custom threshold, internal calibration duration/grouping/cooldown values, six gesture slots, an optional imported `TapSideProfile`, and the last derived `CalibrationProfile`. Recognition performs a fresh quiet-window baseline on enable without presenting a user task. A saved side profile is honored for backward compatibility; otherwise the bundled development-MacBook classifier is used. The bundled profile's zero timestamp is an internal marker that selects its two-mode decision boundary: require a predominantly vertical peak; for negative-Z peaks compare onset gyro X to left/right prototypes, and for positive-Z peaks compare peak gyro magnitude. The normal trained-profile path continues to use normalized onset/peak acceleration and gyro centroids plus recovery duration. Version 1 settings using the old 250 ms cooldown migrate automatically to 120 ms. Side-profile import/export is a development/replay capability, not a first-run requirement. Settings can export a user-initiated redacted diagnostics JSON containing health, counts, derived recognition summaries, and permission state; it deliberately omits raw samples, shortcut names, and personal paths.

The first action boundary now includes confirmation feedback, screenshot, screenshot-to-clipboard, Copy, mute/unmute, volume up/down, Music play/pause/next/previous, app launch, validated HTTP(S) URL opening, and Apple Shortcut execution. Executors use fixed paths (`screencapture`, `osascript`, `open`, and `shortcuts`) plus argument arrays; arbitrary shell text is never evaluated. The Shortcut editor can load the newline-delimited output of `/usr/bin/shortcuts list` into a local picker but keeps a manual name field for renamed or unavailable shortcuts; the executor distinguishes the CLI's missing-shortcut error from an Automation failure. Screen Recording is preflighted/requested through Core Graphics, and denied access exposes a Privacy & Security recovery link. Copy uses System Events to send ⌘C and exposes Accessibility recovery. Music and Shortcuts have no equivalent general preflight in this process; failed command execution exposes target-specific Automation recovery. A broader permission manager and clean-identity prompt/revocation validation remain open. `TapReaderCheck` proves that the app-facing `AppleSPUHIDReader` can activate and stream both SPU channels without root on the development Mac; a helper/XPC boundary remains the fallback for hardware or OS combinations that reject direct access.

`GuidedSideCalibration` remains a training boundary for development, hardware research, and on-demand app recovery. It can run `RecognitionSession` without an existing side profile, wait for the quiet baseline, label accepted `TapEvent` waveforms per side, and persist a `TapSideProfile`. The app recovery flow asks for five taps across each palm rest; the resulting profile preserves those individual feature examples so different points within the outlined zones can match a nearby calibrated tap. The normal app still starts with `TapSideProfile.bundledDefault` and does not require training; its Settings recovery flow invokes the state machine only when the user asks to recalibrate. `TapSideClassifier` still returns `unknown` for ambiguous events. The state-machine transition, opposite-ringing, high-gyro positive-lobe right, firm negative-lobe left, fast-triple, and side-jitter fixtures are covered by `TapProbeCoreCheck`; larger same-posture and cross-model physical validation remain open.

For local packaging, `Scripts/build-app.sh` copies the selected Swift build into `dist/Tap.app`, installs `Resources/Tap/Info.plist`, sets the app as a menu-bar accessory with `LSUIElement`, and uses a stable local development identity when one is available, with an ad-hoc fallback. The bundle is intentionally not represented as a release artifact: the development bundle identifier, Developer ID signing, notarization, entitlements, update channel, and clean-install verification remain open decisions.

The app model now calls the Core Graphics Screen Recording preflight/request APIs for screenshot slots, displays the current state in Settings, and refuses to launch `screencapture` until access is granted. It registers for `NSWorkspace` system and display sleep/wake notifications, stops the reader before either sleep state, and rebuilds the reader and recognition session after a short wake delay. The reader registers an HID-manager removal callback for the supported sensor descriptors, publishes a `noSensors` status when one disappears, and the app retries a bounded number of fresh reader sessions while recognition remains enabled. Physical sleep/removal exercise is still required before treating this as release-accepted behavior.

## 7. Recognition algorithm

### 7.1 Calibration

Baseline calibration is automatic and should be invisible to the user:

1. Observe a short quiet baseline with the laptop stationary when recognition starts.
2. Estimate per-axis bias, noise floor, and resting orientation.
3. Apply the configured sensitivity floor and keep grouping/cooldown values internal.
4. Store only derived baseline parameters and a calibration timestamp by default.

Side classification uses the bundled directional profile for plug-and-play startup. The development-only training path can still capture left/right impulse, early ringing, axis-ratio, sign, and gyro features to improve the bundled model for a validated hardware matrix.

### 7.2 Filtering and features

The initial detector should use bounded, explainable features:

- high-pass or baseline-subtracted acceleration for dynamic impulse;
- acceleration magnitude and per-axis peak values;
- first derivative/jerk around the candidate event;
- gyroscope magnitude and signed axis response;
- short-time energy and ring-down duration;
- time since previous accepted candidate.

The filter must preserve a short tap impulse. A slow low-pass alone will smear or hide it. Each filter needs replay tests for latency, attenuation, and noise.

### 7.3 Side classification

The accelerometer/gyro does not expose a literal “left tap” or “right tap” bit. Side is inferred from how a chassis impulse reaches the sensor. The first approach should compare calibrated left/right features:

- sign and ratio of canonical axes at onset and peak;
- relative acceleration versus rotational-rate direction and energy;
- polarity and timing of the first impulse;
- short ring-down/recovery duration;
- confidence margin between the left and right profiles.

If a device has an ambiguous or unstable side signature, the UI should allow one-sided or count-only fallback behavior rather than pretending classification is reliable.

### 7.4 Tap grouping

Use a small state machine:

```text
Idle
  -> Candidate
  -> FirstAccepted
  -> WaitingForNextTap
  -> SecondAccepted
  -> WaitingForThirdTap
  -> ThirdAccepted
  -> Dispatch
  -> Cooldown
```

The detector uses a 120 ms refractory window so chassis ringing is suppressed without swallowing ordinary fast repeated taps. Accepted candidates join a sequence when adjacent taps are within the 450 ms grouping window, regardless of a momentary per-event side-label disagreement. The completed gesture resolves side from all known labels: a count majority wins, a tied two-tap sequence uses confidence, and an unresolved tie remains `unknown`. This keeps ambiguous input fail-closed while allowing one noisy label to coexist with a valid double or triple tap. Final timing remains a measured tuning decision for the hardware matrix.

## 8. Action execution and permission model

Sensor recognition and action execution must be separate. A working sensor should remain usable even if a chosen action lacks permission.

Each action declares:

```text
id
displayName
category
parametersSchema
requiredPermissions
availabilityCheck
executor
```

Permission rules:

- Request Accessibility only for actions that control the Mac or synthesize input.
- Request Automation when running Shortcuts or controlling another application.
- Request Screen & System Audio Recording only for an implementation that actually needs it for screenshots.
- The direct packaged-app `AppleSPUHIDDevice` path has now proven to require Input Monitoring on the development Mac: macOS logs `TCC deny IOHIDDeviceOpen` for the signed app while the unbundled command-line probe streams normally. The app checks the HID-specific `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` state, can request access with `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`, shows an explicit permission-blocked state, provides a Privacy & Security deep link, and retains the reader's detailed denial status. It must not request or imply extra permissions beyond this sensor-access requirement.
- Explain the exact capability before opening System Settings.
- Handle revoked permission and app-update permission resets without crashing.

Apple's macOS privacy guide lists Accessibility, Automation, Input Monitoring, Motion & Fitness, and Screen & System Audio Recording as separate controls. Sensor access and action permissions must be modeled separately.

## 9. Lifecycle and energy behavior

- Start one reader when recognition is enabled.
- Stop callbacks and release device handles when disabled or quitting.
- Re-enumerate after sleep/wake and device-service changes.
- Pause when the app knows the lid is closed or the Mac is asleep; resume only after health checks pass.
- Detect dropped reports, cadence changes, and repeated parse errors.
- Keep UI updates off the sensor hot path; publish only recognition events and health changes.
- Measure CPU, energy, and battery impact on supported hardware before setting final targets.

## 10. Security and distribution

### Direct-download candidate

- UI app is Developer ID signed and notarized.
- If needed, a narrowly scoped signed helper owns only IOKit sensor access.
- XPC messages are typed and validated.
- Helper has no action-execution API and no network access requirement.
- Updates replace both app and helper atomically and verify signatures.

### Mac App Store candidate

Do not target the Mac App Store until the sensor path has been tested under its sandbox and entitlement rules. An undocumented HID access path may be incompatible with review or future macOS releases. Keep the distribution decision open through Phase 0.

### Privacy boundary

- No raw sensor data leaves the Mac during normal operation.
- No raw sensor data is written to disk unless the user starts a diagnostic recording.
- Diagnostic exports are opt-in, bounded, redacted, and deletable.
- No account is required for recognition.
- Do not request unrelated camera, microphone, contacts, location, or full-disk access.

## 11. Testing strategy

### Feasibility probe

The probe must run on real devices and record:

- model identifier and macOS version;
- presence of `AppleSPUHIDDevice` accel/gyro candidates;
- report length and descriptor;
- sample cadence and timestamp behavior;
- raw range and scale;
- axis orientation and sign;
- reconnect behavior after sleep/wake;
- whether direct open works for a signed non-root process;
- whether Input Monitoring or another privacy setting changes access;
- CPU, energy, and battery impact.

### Replay fixtures

Record local fixtures for:

- left/right single, double, and triple taps;
- gentle and firm taps;
- different tap locations and desk surfaces;
- typing, trackpad use, palm rest, and normal chassis contact;
- walking while carrying the laptop;
- opening/closing the lid;
- desk vibration, fans, speakers, and nearby impacts;
- sleep/wake and display lock.

The recognition engine must be testable entirely from replayed samples without opening a real HID device.

### Acceptance targets for beta

- At least 95% intentional recognition on each declared hardware profile.
- Fewer than one false activation in a four-hour normal-work session.
- No duplicate dispatch from one physical event.
- P95 action dispatch begins within 250 ms after an accepted single tap.
- No raw data in ordinary logs.
- Recovery after service interruption without relaunch.

## 12. Build order

### Step 1: Research probe

Build only the enumerator/parser and a local terminal/dashboard view. Prove the real sensor path before creating SwiftUI screens.

### Step 2: Recorded-data recognizer

Add the sample contract, filters, impact detector, calibration, side classifier, sequence grouping, and replay tests.

### Step 3: Native app shell

Add the menu-bar app, onboarding, configuration, diagnostics, and local persistence. Use a simulated motion source until the recognizer is stable.

### Step 4: Actions and permissions

Add the smallest reliable action set first: screenshot, mute, media play/pause, app launch, URL, and Shortcut execution. Add higher-risk actions only after permission behavior is verified.

### Step 5: Packaging decision

Test direct in-process access, then helper/XPC if necessary. Produce signed/notarized builds and choose direct distribution or Mac App Store based on evidence.

## 13. Risks and open decisions

1. The IMU interface is undocumented and may change across macOS releases.
2. The exact report scale, cadence, and axis mapping may differ by MacBook model.
3. Direct sensor access may require a privileged helper, which increases installation and support complexity.
4. Left/right classification is an inference from chassis response, not a hardware-provided location signal.
5. Normal typing, palm pressure, desk vibration, and transport may create false positives.
6. Some requested actions may require sensitive macOS permissions or unavailable/private APIs.
7. Core Motion's public iOS-style API cannot be assumed to provide the Mac implementation.
8. The product needs a clear answer on whether App Store distribution is a requirement.

## 14. Research sources

- [Apple Core Motion overview](https://developer.apple.com/documentation/coremotion/)
- [Apple CMMotionManager documentation](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
- [Apple CMDeviceMotion documentation](https://developer.apple.com/documentation/coremotion/cmdevicemotion)
- [Apple device sensors overview](https://developer.apple.com/documentation/technologyoverviews/device-sensors)
- [Apple macOS Privacy & Security settings](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac)
- [Bosch inertial sensor mechanics](https://www.bosch-mobility.com/en/solutions/sensors/inertial-measurement-unit/)
- [Apple-Silicon accelerometer IOKit HID implementation](https://github.com/olvvier/apple-silicon-accelerometer)
- [Go port documenting AppleSPUHIDDevice reports](https://github.com/taigrr/apple-silicon-accelerometer)
- [Swift MacBook knock implementation using IOKit HID](https://github.com/shaircast/nocnoc)

The Apple links describe the general motion concepts and macOS privacy model. The GitHub projects are implementation evidence for an undocumented MacBook HID path, not an Apple compatibility guarantee. The local `ioreg` observation is the authoritative evidence for the development machine; every supported model still requires a fresh probe.
