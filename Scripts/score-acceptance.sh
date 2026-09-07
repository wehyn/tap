#!/bin/zsh
set -euo pipefail
setopt null_glob

if (( $# < 1 || $# > 3 )); then
    print -u2 "Usage: $0 DIRECTORY [low|medium|high] [CALIBRATION_SECONDS]"
    exit 2
fi

INPUT_DIR="${1:A}"
SENSITIVITY="${2:-high}"
CALIBRATION="${3:-2}"

if [[ ! -d "$INPUT_DIR" ]]; then
    print -u2 "Directory does not exist: $INPUT_DIR"
    exit 1
fi

case "$SENSITIVITY" in
    low|medium|high)
        ;;
    *)
        print -u2 "Sensitivity must be low, medium, or high"
        exit 2
        ;;
esac

swift build --product TapReplay >/dev/null
BIN_PATH="$(swift build --show-bin-path)"
REPLAY_BIN="$BIN_PATH/TapReplay"

typeset -a traces=(
    "$INPUT_DIR"/positive/*.jsonl
    "$INPUT_DIR"/negative/*.jsonl
)
if (( ${#traces[@]} == 0 )); then
    print -u2 "No .jsonl traces found under $INPUT_DIR/positive or $INPUT_DIR/negative"
    exit 1
fi

print "file\ttype\texpected\tcandidates\tleft\tright\tunknown\tresult"

for trace in $traces; do
    relative_path="${trace#$INPUT_DIR/}"
    file_name="${trace:t}"
    case "$relative_path" in
        positive/left-*)
            type=positive
            expected=left
            ;;
        positive/right-*)
            type=positive
            expected=right
            ;;
        negative/*)
            type=negative
            expected=none
            ;;
        *)
            type=other
            expected=none
            ;;
    esac

    set +e
    replay_output="$("$REPLAY_BIN" \
        --trace "$trace" \
        --calibrate "$CALIBRATION" \
        --sensitivity "$SENSITIVITY" \
        --bundled-side-profile \
        --verbose 2>&1)"
    replay_status=$?
    set -e

    candidates="$(print -r -- "$replay_output" | awk '/^tap candidate / { count += 1 } END { print count + 0 }')"
    left_count="$(print -r -- "$replay_output" | awk '/^tap candidate .*side=left([[:space:]]|$)/ { count += 1 } END { print count + 0 }')"
    right_count="$(print -r -- "$replay_output" | awk '/^tap candidate .*side=right([[:space:]]|$)/ { count += 1 } END { print count + 0 }')"
    unknown_count="$(print -r -- "$replay_output" | awk '/^tap candidate .*side=unknown([[:space:]]|$)/ { count += 1 } END { print count + 0 }')"

    result=FAIL
    if (( replay_status != 0 )); then
        result=ERROR
    elif [[ "$type" == positive ]]; then
        if [[ "$expected" == left && "$candidates" == 1 && "$left_count" == 1 ]] || \
           [[ "$expected" == right && "$candidates" == 1 && "$right_count" == 1 ]]; then
            result=PASS
        else
            result=REVIEW
        fi
    elif [[ "$type" == negative ]]; then
        if [[ "$candidates" == 0 ]]; then
            result=PASS
        else
            result=FAIL
        fi
    fi

    print "$file_name\t$type\t$expected\t$candidates\t$left_count\t$right_count\t$unknown_count\t$result"
done
