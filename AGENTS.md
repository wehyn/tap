# Tap repository agent instructions

Before making changes, read these project documents in order:

1. [`docs/TASKS.md`](docs/TASKS.md) for the current milestone, completed work, and next tasks.
2. [`docs/PRD.md`](docs/PRD.md) for the full product requirements, scope, user journeys, and acceptance targets.
3. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full sensor, recognition, process-boundary, privacy, and distribution design.

Keep `docs/TASKS.md` current when work starts or finishes. Product documentation belongs in `docs/`; this root `AGENTS.md` is the project-agent entry point.

## Repository conventions

- This is a Swift Package for a native macOS app prototype.
- Use `apply_patch` for source and documentation edits.
- Keep raw sensor traces in `/tmp` or another explicit local diagnostic location. Do not commit traces, serial numbers, or personal paths.
- Do not run the full app as root. If direct HID access fails on another machine, preserve the unprivileged UI and evaluate the signed helper/XPC fallback described in `docs/ARCHITECTURE.md`.
- Keep the sensor adapter, report parser, calibration, recognizer, action layer, and UI as replaceable boundaries.
- Treat AppleSPUHIDDevice usage, report layout, activation properties, and scale as undocumented observations. Revalidate before claiming hardware compatibility.
- Sensitivity must remain user-adjustable. Preserve the Low/Medium/High presets and custom threshold path unless measured fixtures justify changing them.
- Do not add action execution until recognition has replay coverage and permission behavior is explicitly designed.

## Required verification

For changes to core recognition or probe behavior, run at least:

```bash
swift build
swift run TapProbeCoreCheck
```

When traces are available, replay them with `TapReplay` at the relevant sensitivity and compare candidate counts. For HID changes, also run `swift run TapProbe --list` and a short non-root live run on the target Mac.

Use current official documentation or Context7 when researching a changing Swift, macOS, IOKit, SwiftPM, or related API. Do not infer support for Core Motion on macOS from iOS examples.
