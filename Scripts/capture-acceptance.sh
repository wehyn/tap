#!/bin/zsh
set -euo pipefail

usage() {
    print "Usage: Scripts/capture-acceptance.sh [all|positives|negatives]"
    print ""
    print "Environment overrides:"
    print "  TAP_ACCEPTANCE_DIR          Output directory (default: /tmp/tap-acceptance-<timestamp>)"
    print "  TAP_ACCEPTANCE_SENSITIVITY  low, medium, or high (default: high)"
    print "  TAP_ACCEPTANCE_DURATION     Seconds per run (default: 8)"
    print "  TAP_ACCEPTANCE_CALIBRATION  Quiet calibration seconds (default: 2)"
    print "  TAP_ACCEPTANCE_LEAD_IN      Countdown seconds before each run (default: 5)"
    print ""
}

MODE="${1:-all}"
case "$MODE" in
    all|positives|negatives)
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

SENSITIVITY="${TAP_ACCEPTANCE_SENSITIVITY:-high}"
DURATION="${TAP_ACCEPTANCE_DURATION:-8}"
CALIBRATION="${TAP_ACCEPTANCE_CALIBRATION:-2}"
LEAD_IN="${TAP_ACCEPTANCE_LEAD_IN:-5}"
if [[ -n "${TAP_ACCEPTANCE_DIR:-}" ]]; then
    OUTPUT_DIR="$TAP_ACCEPTANCE_DIR"
else
    OUTPUT_DIR="/tmp/tap-acceptance-$(date '+%Y%m%d-%H%M%S')"
fi

case "$SENSITIVITY" in
    low|medium|high)
        ;;
    *)
        print -u2 "TAP_ACCEPTANCE_SENSITIVITY must be low, medium, or high"
        exit 2
        ;;
esac

if [[ ! "$DURATION" =~ '^[0-9]+([.][0-9]+)?$' || ! "$CALIBRATION" =~ '^[0-9]+([.][0-9]+)?$' || ! "$LEAD_IN" =~ '^[0-9]+$' ]]; then
    print -u2 "TAP_ACCEPTANCE_DURATION and TAP_ACCEPTANCE_CALIBRATION must be non-negative numbers; TAP_ACCEPTANCE_LEAD_IN must be a non-negative integer"
    exit 2
fi

mkdir -p "$OUTPUT_DIR/positive" "$OUTPUT_DIR/negative"

{
    print "captured_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    print "model=$(sysctl -n hw.model 2>/dev/null || print unknown)"
    print "macOS=$(sw_vers -productVersion 2>/dev/null || print unknown)"
    print "architecture=$(uname -m)"
    print "sensitivity=$SENSITIVITY"
    print "duration_seconds=$DURATION"
    print "calibration_seconds=$CALIBRATION"
    print "lead_in_seconds=$LEAD_IN"
} > "$OUTPUT_DIR/metadata.txt"

print "Building TapProbe before the interactive cases..."
swift build --product TapProbe >/dev/null
BIN_PATH="$(swift build --show-bin-path)"
PROBE_BIN="$BIN_PATH/TapProbe"

print "Acceptance captures will be written to: $OUTPUT_DIR"
print "Hardware metadata excludes the Mac serial number."
print "Quit Tap.app before starting so the CLI owns the sensor reader."
print "Each run begins with a quiet calibration; follow the prompt and perform one action."

capture_case() {
    local category="$1"
    local label="$2"
    local instruction="$3"
    local trace_path="$OUTPUT_DIR/$category/$label.jsonl"
    local log_path="$OUTPUT_DIR/$category/$label.log"
    local ignored_input

    print ""
    print "[$category/$label] $instruction"
    print -n "Press Return to start, or Ctrl-C to stop: "
    read -r ignored_input

    integer remaining=$LEAD_IN
    while (( remaining > 0 )); do
        print "Starting in ${remaining}s... keep the Mac still."
        sleep 1
        remaining=$(( remaining - 1 ))
    done

    "$PROBE_BIN" \
        --detect \
        --duration "$DURATION" \
        --calibrate "$CALIBRATION" \
        --sensitivity "$SENSITIVITY" \
        --record "$trace_path" \
        --verbose 2>&1 | tee "$log_path"

    print "Saved $(wc -l < "$trace_path" | tr -d ' ') samples to $trace_path"
}

if [[ "$MODE" == all || "$MODE" == positives ]]; then
    typeset -a sides=(left right)
    typeset -a positions=(inner center outer)
    typeset -a strengths=(light firm)

    for side in $sides; do
        for position in $positions; do
            for strength in $strengths; do
                for repetition in 1 2; do
                    capture_case \
                        positive \
                        "$side-$position-$strength-0$repetition" \
                        "Perform exactly one $strength $side-side tap at the $position palm-rest position; stay still afterward."
                done
            done
        done
    done
fi

if [[ "$MODE" == all || "$MODE" == negatives ]]; then
    capture_case negative typing-01 \
        "Type normally for the run; do not tap the chassis."
    capture_case negative trackpad-01 \
        "Use the trackpad normally for the run; do not tap the chassis."
    capture_case negative carrying-01 \
        "Carefully lift and reposition the open MacBook once, then leave it still; do not tap the chassis."
    capture_case negative desk-vibration-01 \
        "Lightly tap the desk beside the MacBook several times; do not touch the chassis."
    capture_case negative lid-01 \
        "Slowly adjust the display angle once during the run; do not tap the chassis."
fi

print ""
print "Capture complete: $OUTPUT_DIR"
print "Score it with: Scripts/score-acceptance.sh $OUTPUT_DIR $SENSITIVITY"
