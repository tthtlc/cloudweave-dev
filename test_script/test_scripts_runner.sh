#!/usr/bin/env bash
#
# Minimal test infrastructure: run a random sample of ./scripts through the
# AWS admin wrapper and report success/failure with captured stdout/stderr.
#
# For each chosen script $s we execute:  bash myrun_aws_admin.sh $s
# stdout and stderr are written to separate files inside a temporary logging
# directory, and a per-script + aggregate report is printed at the end.
#
# Usage:
#   ./test_scripts_runner.sh            # random 5 scripts
#   ./test_scripts_runner.sh 3          # random 3 scripts
#   SAMPLE_SIZE=5 ./test_scripts_runner.sh
#
# Env overrides:
#   SAMPLE_SIZE     number of scripts to run (default 5)
#   SCRIPTS_DIR     directory to scan (default ./scripts)
#   RUNNER          wrapper to invoke (default ./myrun_aws_admin.sh)
#   KEEP_LOGDIR=1   do not delete the log dir at exit (default: keep)

set -u

cd "$(dirname "$0")"

SCRIPTS_DIR="${SCRIPTS_DIR:-./scripts}"
RUNNER="${RUNNER:-./myrun_aws_admin.sh}"
SAMPLE_SIZE="${SAMPLE_SIZE:-${1:-5}}"
KEEP_LOGDIR="${KEEP_LOGDIR:-1}"

if [ ! -x "$RUNNER" ] && [ ! -f "$RUNNER" ]; then
    echo "ERROR: runner '$RUNNER' not found." >&2
    exit 2
fi

if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "ERROR: scripts dir '$SCRIPTS_DIR' not found." >&2
    exit 2
fi

# Temporary logging output directory. Keep it (do not auto-clean) so the user
# can inspect the captured streams; print its path at the end.
LOG_DIR=$(mktemp -d -t libcloud_test_XXXXXX)
trap 'if [ "${KEEP_LOGDIR}" != "1" ]; then rm -rf "$LOG_DIR"; fi' EXIT

# Build the candidate list:
#   - regular files only
#   - anywhere under $SCRIPTS_DIR, but skip build-artifact subdirs
#   - skip nutanix-related files (name contains ntnx or nutanix)
#   - skip deprovision_aws.sh and deprovision_nutanix.sh
candidates=()
while IFS= read -r f; do
    rel="${f#"$SCRIPTS_DIR"/}"
    base=$(basename "$f")
    case "$base" in
        deprovision_aws.sh|deprovision_nutanix.sh) continue ;;
    esac
    case "$rel" in
        generated/*|__pycache__/*) continue ;;
    esac
    case "$base" in
        *ntnx*|*nutanix*|*NTNX*|*NUTANIX*) continue ;;
    esac
    candidates+=("$f")
done < <(find "$SCRIPTS_DIR" -type f | sort)

count=${#candidates[@]}
if [ "$count" -eq 0 ]; then
    echo "ERROR: no candidate scripts found under $SCRIPTS_DIR." >&2
    exit 2
fi

# Clamp sample size to the available population.
if [ "$SAMPLE_SIZE" -gt "$count" ]; then
    SAMPLE_SIZE=$count
fi

# Random, non-repeating selection.
shuffled=()
for i in "${!candidates[@]}"; do
    shuffled[$RANDOM]="${candidates[$i]}"
done
selected=($(printf '%s\n' "${shuffled[@]}" | head -n "$SAMPLE_SIZE"))

echo "============================================================"
echo " libcloud minimal test runner"
echo "   scripts dir : $SCRIPTS_DIR  ($count candidates)"
echo "   runner      : $RUNNER"
echo "   sample size : ${#selected[@]}"
echo "   log dir     : $LOG_DIR"
echo "============================================================"

summary_log="$LOG_DIR/_summary.txt"
{
    echo "# test run summary"
    echo "# started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# runner : $RUNNER"
    echo "# logdir : $LOG_DIR"
    echo "# sample : ${#selected[@]} of $count"
    echo
} > "$summary_log"

pass=0
fail=0
failed_list=()

for script in "${selected[@]}"; do
    base=$(basename "$script")
    safe=${base//[^A-Za-z0-9._-]/_}
    out_log="$LOG_DIR/${safe}.stdout"
    err_log="$LOG_DIR/${safe}.stderr"

    echo
    echo "---- running: $script"
    # Execute the wrapper with the script as $1; capture streams separately.
    bash "$RUNNER" "$script" >"$out_log" 2>"$err_log"
    rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "    [PASS] exit=0"
        pass=$((pass + 1))
        status="PASS"
    else
        echo "    [FAIL] exit=$rc"
        fail=$((fail + 1))
        failed_list+=("$script (exit=$rc)")
        status="FAIL"
        # Surface a short excerpt of the error stream.
        echo "    stderr (last 5 lines):"
        awk 'END{print NR" lines total"}' "$err_log" | sed 's/^/      /'
        tail -n 5 "$err_log" | sed 's/^/      | /'
    fi

    {
        echo "## $script"
        echo "  status : $status"
        echo "  exit   : $rc"
        echo "  stdout : $out_log ($(wc -l < "$out_log") lines)"
        echo "  stderr : $err_log ($(wc -l < "$err_log") lines)"
    } >> "$summary_log"
done

echo
echo "============================================================"
echo " RESULTS: pass=$pass  fail=$fail  total=${#selected[@]}"
echo " log dir : $LOG_DIR"
echo " summary : $summary_log"
if [ "$fail" -gt 0 ]; then
    echo
    echo " FAILED:"
    for f in "${failed_list[@]}"; do
        echo "   - $f"
    done
    echo "============================================================"
    exit 1
fi
echo "============================================================"
exit 0
