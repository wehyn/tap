# Tap

Tap is a native macOS menu-bar prototype that recognizes one-, two-, and
three-tap gestures on the left or right side of a supported MacBook chassis.
It reads the built-in accelerometer and gyroscope through the internal
`AppleSPUHIDDevice` HID interfaces, classifies the tap side, and maps the
gesture to a configurable action.

> This is an active hardware-validation prototype. The internal sensor
> interface is undocumented, so hardware and macOS compatibility still need to
> be validated beyond the development MacBook.

## Requirements

- macOS 14 or later
- A supported Apple-Silicon MacBook with exposed `AppleSPUHIDDevice` sensors
- Swift 6 toolchain and the macOS SDK

Tap processes sensor data locally. Raw traces are created only when explicitly
requested by the probe and should be kept outside the repository, such as in
`/tmp`.

## Build and run

Build the package:

```bash
swift build
```

Check whether the internal accelerometer and gyroscope are available:

```bash
swift run TapProbe --list
```

Run the live detector. Keep the MacBook still during the initial calibration,
then tap the chassis:

```bash
swift run TapProbe --detect --duration 10 --sensitivity high --group
```

The detector supports `low`, `medium`, and `high` sensitivity presets. For
development tuning, use a custom threshold, for example:

```bash
swift run TapProbe --detect --threshold-g 0.05 --group
```

Build the menu-bar app bundle:

```bash
./Scripts/build-app.sh debug
open dist/Tap.app
```

`TAP_SIGNING_IDENTITY` can be set to choose a specific local signing identity.
Without one, the script uses ad-hoc signing for local development.

## Tests and trace tools

Run the deterministic parser, calibration, recognition, and grouping checks:

```bash
swift run TapProbeCoreCheck
```

Replay a trace recorded by `TapProbe`:

```bash
swift run TapReplay --trace /tmp/tap-session.jsonl \
  --sensitivity high --bundled-side-profile --group --verbose
```

Build a side profile from labeled left and right traces:

```bash
swift run TapTrain \
  --left /tmp/left-tap.jsonl \
  --right /tmp/right-tap.jsonl \
  --output /tmp/tap-side-profile.json
```

The guided recalibration flow in the app is the normal user-facing recovery
path. `TapTrain` and custom side profiles are development and diagnostics
tools.

## Current behavior

- The app performs a quiet baseline measurement automatically when recognition
  starts.
- Gestures are grouped into one, two, or three taps using a configurable time
  window.
- The bundled directional fallback supports plug-and-play side detection on
  the development MacBook; optional guided recalibration can save local side
  examples.
- Recognition remains conservative and can report `unknown` when evidence is
  insufficient or conflicting.
- Actions are permission-gated and run locally. The UI does not run as root.

See [`docs/TASKS.md`](docs/TASKS.md) for the current milestone and validation
status, [`docs/PRD.md`](docs/PRD.md) for product requirements, and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the sensor and process
architecture. The repeatable hardware test procedure is in
[`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md).
