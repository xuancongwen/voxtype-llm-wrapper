#!/bin/sh
# Build the voxtype-llm-wrapper model in Ollama and point voxtype at it.
#
# Usage: ./setup.sh [--profile NAME] [--model-only] [BASE_MODEL]
#
#   --profile NAME  Which profile in profiles/ to build: "max" (qwen2.5:7b,
#                   4.9 GB while loaded) or "light" (granite3.3:2b, 2.1 GB).
#                   Defaults to light on macOS and max everywhere else.
#   --model-only    Build the Ollama model and stop; do not touch voxtype.
#                   Implied on macOS, where voxtype does not run.
#   BASE_MODEL      Override the FROM line of the chosen profile for this run
#                   only (e.g. ./setup.sh gemma3:4b). Nothing in the repo is
#                   modified.
#
# Assumes Ollama and voxtype (1.0 or newer) are already installed. The script
# checks for both and stops with a message if either is missing. It never
# installs packages and never overwrites an existing post_process block.

set -eu

MODEL_NAME="voxtype-llm-wrapper"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Arguments --------------------------------------------------------------

OS=$(uname -s 2>/dev/null || echo unknown)
PROFILE=""
MODEL_ONLY=0
BASE_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)   [ $# -ge 2 ] || die "--profile needs a name"; PROFILE=$2; shift 2 ;;
        --profile=*) PROFILE=${1#--profile=}; shift ;;
        --model-only) MODEL_ONLY=1; shift ;;
        -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          die "unknown option $1" ;;
        *)           [ -z "$BASE_OVERRIDE" ] || die "unexpected argument $1"; BASE_OVERRIDE=$1; shift ;;
    esac
done

if [ -z "$PROFILE" ]; then
    case "$OS" in Darwin) PROFILE=light ;; *) PROFILE=max ;; esac
fi
case "$OS" in Darwin) MODEL_ONLY=1 ;; esac

PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE"
[ -f "$PROFILE_FILE" ] || die "no profile named '$PROFILE' in $SCRIPT_DIR/profiles (have: $(ls "$SCRIPT_DIR/profiles" | tr '\n' ' '))"

# --- Preflight checks -------------------------------------------------------

command -v ollama >/dev/null 2>&1 \
    || die "ollama is not installed. See https://ollama.com/download"

if ! ollama list >/dev/null 2>&1; then
    die "Ollama is installed but not running. Start it with 'ollama serve' (or the Ollama app on macOS), then re-run this script."
fi

if [ "$MODEL_ONLY" -eq 0 ]; then
    command -v voxtype >/dev/null 2>&1 \
        || die "voxtype is not installed. See https://github.com/peteonrails/voxtype (or pass --model-only to build just the model)"

    VOXTYPE_VERSION=$(voxtype --version 2>/dev/null | awk '{print $NF}')
    VOXTYPE_MAJOR=${VOXTYPE_VERSION%%.*}
    case "$VOXTYPE_MAJOR" in
        ''|*[!0-9]*) die "could not parse voxtype version from '$VOXTYPE_VERSION'" ;;
    esac
    [ "$VOXTYPE_MAJOR" -ge 1 ] \
        || die "voxtype $VOXTYPE_VERSION is too old; post-processing needs 1.0 or newer"

    [ -f "$CONFIG" ] \
        || die "no voxtype config at $CONFIG. Run 'voxtype' once to generate the default config, then re-run this script."
fi

# --- Build the model --------------------------------------------------------

info "Rendering Modelfiles from system_prompt.txt and profiles/"
"$SCRIPT_DIR/gen-modelfiles.sh" >/dev/null
MODELFILE="$SCRIPT_DIR/Modelfile.$PROFILE"

BASE_MODEL=${BASE_OVERRIDE:-$(awk '/^FROM[[:space:]]/ {print $2; exit}' "$MODELFILE")}
[ -n "$BASE_MODEL" ] || die "could not determine base model from $MODELFILE"

info "Pulling base model $BASE_MODEL (skips quickly if already present)"
ollama pull "$BASE_MODEL"

if [ -n "$BASE_OVERRIDE" ]; then
    TMP_MODELFILE=$(mktemp)
    trap 'rm -f "$TMP_MODELFILE"' EXIT
    sed "s|^FROM[[:space:]].*|FROM $BASE_MODEL|" "$MODELFILE" > "$TMP_MODELFILE"
    BUILD_FROM="$TMP_MODELFILE"
else
    BUILD_FROM="$MODELFILE"
fi

info "Building $MODEL_NAME (profile: $PROFILE, base: $BASE_MODEL)"
ollama create "$MODEL_NAME" -f "$BUILD_FROM"

info "Smoke test"
SAMPLE="um so let's meet tuesday no wait wednesday at four"
RESULT=$(printf '%s\n' "$SAMPLE" | ollama run --nowordwrap "$MODEL_NAME")
printf '    in:  %s\n    out: %s\n' "$SAMPLE" "$RESULT"
[ -n "$RESULT" ] || die "model returned no output; check 'ollama run $MODEL_NAME' by hand"

if [ "$MODEL_ONLY" -eq 1 ]; then
    info "Model built. Run ./test.sh for the full check, or pipe text through: echo 'some text' | ollama run --nowordwrap $MODEL_NAME"
    exit 0
fi

# --- Configure voxtype ------------------------------------------------------

if grep -Eq '^[[:space:]]*\[output\.post_process\]' "$CONFIG"; then
    info "$CONFIG already has a [output.post_process] section; leaving it alone:"
    awk '/^[[:space:]]*\[output\.post_process\]/ { p = 1; print; next }
         p && /^[[:space:]]*\[/ { exit }
         p { print }' "$CONFIG" | sed 's/^/    /'
    printf '    Edit it by hand if you want it to use: ollama run --nowordwrap %s\n' "$MODEL_NAME"
else
    BACKUP="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG" "$BACKUP"
    info "Backed up config to $BACKUP"
    info "Appending [output.post_process] to $CONFIG"
    cat >> "$CONFIG" <<EOT

# Added by voxtype-llm-wrapper/setup.sh
[output.post_process]
command = "ollama run --nowordwrap $MODEL_NAME"
timeout_ms = 30000
trim = true
fallback_on_empty = true
EOT
fi

# --- Restart the daemon -----------------------------------------------------

if systemctl --user is-active --quiet voxtype 2>/dev/null; then
    info "Restarting voxtype user service"
    systemctl --user restart voxtype
elif pgrep -x voxtype >/dev/null 2>&1; then
    info "voxtype is running outside systemd; restart it yourself to pick up the new config"
else
    info "voxtype is not running; start it with 'voxtype daemon' or 'systemctl --user start voxtype'"
fi

info "Done. Press your voxtype hotkey and dictate; cleaned text will be typed at the cursor."
