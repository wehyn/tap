# Hardware acceptance

This checklist measures whether Tap is reliable on a real MacBook without
changing detector thresholds between runs. Raw sensor traces belong in `/tmp`
or another explicit local diagnostic directory and must not be committed.

## Automated preflight

Run these commands on the MacBook being tested:

```bash
swift build
swift run TapProbeCoreCheck
swift run TapProbe --list
```

The HID listing should show the expected `AppleSPUHIDDevice` accelerometer and
gyroscope interfaces. Quit `Tap.app` before starting the CLI capture so the
probe owns the sensor reader.

## Positive and negative capture

The capture helper creates 12 single-tap traces per side: three palm-rest
positions, two strengths, and two repetitions. It also creates five normal-use
negative traces.

```bash
Scripts/capture-acceptance.sh all
```

The default run uses High sensitivity, an 8-second capture, and a 2-second
quiet calibration. Override those values when needed:

```bash
TAP_ACCEPTANCE_SENSITIVITY=high \
TAP_ACCEPTANCE_DURATION=8 \
TAP_ACCEPTANCE_CALIBRATION=2 \
Scripts/capture-acceptance.sh positives
```

Each positive run should contain exactly one tap: wait for calibration, make
one intentional tap, and stay still. The negative runs cover typing, trackpad
use, carefully repositioning the open laptop, vibration beside the laptop,
and one display-angle adjustment.

The helper stores only the model identifier, macOS version, architecture, and
capture settings in `metadata.txt`; it does not collect the Mac serial number.

## Scoring

Pass the generated directory to the scorer:

```bash
Scripts/score-acceptance.sh /tmp/tap-acceptance-YYYYMMDD-HHMMSS high
```

Acceptance criteria for the current bundled profile are:

| Fixture | Pass condition |
|---|---|
| Positive left | Exactly one candidate classified `left` |
| Positive right | Exactly one candidate classified `right` |
| Negative | Zero candidates |

`REVIEW` means the trace needs inspection rather than an automatic detector
change. Look at the replay output with `--verbose` before tuning anything.

The first current-Mac target is at least 10 accepted left taps and 10 accepted
right taps, with zero false positives in the negative set. Repeat the run on a
separate session with the laptop posture unchanged before calling the profile
stable.

## Sleep, wake, and reconnect

With the packaged app enabled:

1. Open Diagnostics and confirm the sensor state is listening.
2. Let the display sleep, wake it, and confirm recognition returns without a
   second reader or repeated callbacks.
3. Put the Mac to sleep and wake it, then confirm the same behavior.
4. If supported by the hardware, trigger a sensor-service reconnect and verify
   the bounded retry status resolves to listening.
5. Perform a tap after each recovery and confirm only one action is executed.

Record the observed state transitions and any duplicate candidates in the
acceptance notes; do not loosen recognition to compensate for a reconnect
bug.

## Permission recovery

On a clean app identity, test each permission-gated action once:

- screenshots: Screen Recording
- keyboard and clipboard actions: Accessibility, when requested by macOS
- Music controls: Automation for Music
- Apple Shortcuts: Automation for Shortcuts

For each permission, deny or revoke access, use the app's recovery control,
grant access again, and repeat the action. The expected result is an actionable
message followed by successful execution after permission is restored.

## Additional MacBook models

Run the same preflight, capture, scoring, sleep/wake, and permission checks on
each additional MacBook model. Keep each output directory separate. A profile
that passes on one model is not evidence that the same axis mapping works on
another; models with different sensor axes need a validated hardware profile.
