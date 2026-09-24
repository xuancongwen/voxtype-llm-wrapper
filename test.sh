#!/bin/sh
# Run the dictation cases in test-cases.tsv through a built model and report
# how closely each output matches the expected text.
#
# Usage: ./test.sh [MODEL_NAME]
#
# MODEL_NAME defaults to voxtype-llm-wrapper. Each line of test-cases.tsv is
# "input<TAB>expected", with \n in the expected column standing for a line
# break and <empty> meaning the model should output nothing. Lines with an
# empty expected column are printed for eyeballing but not scored.
#
# Each scored case gets one of:
#   PASS  exact match
#   NEAR  same words after dropping case, punctuation, and whitespace; only
#         style differs (a curly quote, an Oxford comma, a line break)
#   FAIL  different words: content was answered, dropped, added, or rewritten
#
# Extra flags for "ollama run" can be passed in the RUN_ARGS environment
# variable, e.g. RUN_ARGS=--think=false for a model with a thinking mode.
#
# Exit status is non-zero if any scored case FAILs. NEAR does not fail.

set -u

MODEL=${1:-voxtype-llm-wrapper}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CASES="$SCRIPT_DIR/test-cases.tsv"

command -v ollama >/dev/null 2>&1 || { echo "error: ollama not found" >&2; exit 1; }
[ -f "$CASES" ] || { echo "error: $CASES not found" >&2; exit 1; }

# Lowercase and strip everything that is not a letter or digit.
lenient() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }
oneline() { printf '%s' "$1" | tr '\n' '|'; }

pass=0; near=0; fail=0; unscored=0
TAB=$(printf '\t')
while IFS="$TAB" read -r input expected; do
    [ -n "$input" ] || continue
    case "$input" in '#'*) continue ;; esac
    got=$(printf '%s\n' "$input" | ollama run --nowordwrap ${RUN_ARGS:-} "$MODEL" 2>/dev/null | sed -e 's/[[:space:]]*$//')
    if [ -z "$expected" ]; then
        unscored=$((unscored + 1))
        printf '....  %s\n   -> %s\n' "$input" "$(oneline "$got")"
        continue
    fi
    [ "$expected" = "<empty>" ] && expected=""
    expected=$(printf '%b' "$expected")
    if [ "$got" = "$expected" ]; then
        pass=$((pass + 1))
        printf 'PASS  %s\n' "$input"
    elif [ "$(lenient "$got")" = "$(lenient "$expected")" ]; then
        near=$((near + 1))
        printf 'NEAR  %s\n   want: %s\n   got:  %s\n' "$input" "$(oneline "$expected")" "$(oneline "$got")"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s\n   want: %s\n   got:  %s\n' "$input" "$(oneline "$expected")" "$(oneline "$got")"
    fi
done < "$CASES"

printf '\n%s: %d pass, %d near, %d fail, %d unscored\n' "$MODEL" "$pass" "$near" "$fail" "$unscored"
[ "$fail" -eq 0 ]
