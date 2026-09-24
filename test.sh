#!/bin/sh
# Run the dictation cases in test-cases.tsv through a built model and report
# which ones match the expected output exactly.
#
# Usage: ./test.sh [MODEL_NAME]
#
# MODEL_NAME defaults to voxtype-llm-wrapper. Each line of test-cases.tsv is
# "input<TAB>expected", with \n in the expected column standing for a line
# break. Lines with an empty expected column are printed for eyeballing but
# not scored. Exit status is non-zero if any scored case fails.

set -u

MODEL=${1:-voxtype-llm-wrapper}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CASES="$SCRIPT_DIR/test-cases.tsv"

command -v ollama >/dev/null 2>&1 || { echo "error: ollama not found" >&2; exit 1; }
[ -f "$CASES" ] || { echo "error: $CASES not found" >&2; exit 1; }

pass=0; fail=0; unscored=0
TAB=$(printf '\t')
while IFS="$TAB" read -r input expected; do
    [ -n "$input" ] || continue
    case "$input" in '#'*) continue ;; esac
    expected=$(printf '%b' "$expected")
    got=$(printf '%s\n' "$input" | ollama run --nowordwrap "$MODEL" 2>/dev/null | sed -e 's/[[:space:]]*$//')
    if [ -z "$expected" ]; then
        unscored=$((unscored + 1))
        printf '....  %s\n   -> %s\n' "$input" "$(printf '%s' "$got" | tr '\n' '|')"
    elif [ "$got" = "$expected" ]; then
        pass=$((pass + 1))
        printf 'PASS  %s\n' "$input"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s\n   want: %s\n   got:  %s\n' "$input" "$expected" "$(printf '%s' "$got" | tr '\n' '|')"
    fi
done < "$CASES"

printf '\n%s: %d passed, %d failed, %d unscored\n' "$MODEL" "$pass" "$fail" "$unscored"
[ "$fail" -eq 0 ]
