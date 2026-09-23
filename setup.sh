#!/bin/sh
# Build the voxtype-llm-wrapper model in Ollama and point voxtype at it.
#
# Usage: ./setup.sh [BASE_MODEL]
#
# BASE_MODEL overrides the FROM line in the Modelfile for this run only
# (e.g. ./setup.sh llama3.2:3b). The Modelfile in the repo is not modified.
#
# Assumes Ollama and voxtype (1.0 or newer) are already installed. The script
# checks for both and stops with a message if either is missing. It never
# installs packages and never overwrites an existing post_process block.

set -eu

MODEL_NAME="voxtype-llm-wrapper"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MODELFILE="$SCRIPT_DIR/Modelfile"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Preflight checks -------------------------------------------------------

[ -f "$MODELFILE" ] || die "Modelfile not found next to this script ($MODELFILE)"

command -v ollama >/dev/null 2>&1 \
    || die "ollama is not installed. See https://ollama.com/download"

command -v voxtype >/dev/null 2>&1 \
    || die "voxtype is not installed. See https://github.com/peteonrails/voxtype"

if ! ollama list >/dev/null 2>&1; then
    die "Ollama is installed but not running. Start it with 'ollama serve' or 'systemctl start ollama', then re-run this script."
fi

VOXTYPE_VERSION=$(voxtype --version 2>/dev/null | awk '{print $NF}')
VOXTYPE_MAJOR=${VOXTYPE_VERSION%%.*}
case "$VOXTYPE_MAJOR" in
    ''|*[!0-9]*) die "could not parse voxtype version from '$VOXTYPE_VERSION'" ;;
esac
[ "$VOXTYPE_MAJOR" -ge 1 ] \
    || die "voxtype $VOXTYPE_VERSION is too old; post-processing needs 1.0 or newer"

[ -f "$CONFIG" ] \
    || die "no voxtype config at $CONFIG. Run 'voxtype' once to generate the default config, then re-run this script."

# --- Build the model --------------------------------------------------------

BASE_MODEL=${1:-$(awk '/^FROM[[:space:]]/ {print $2; exit}' "$MODELFILE")}
[ -n "$BASE_MODEL" ] || die "could not determine base model from Modelfile"

info "Pulling base model $BASE_MODEL (skips quickly if already present)"
ollama pull "$BASE_MODEL"

if [ $# -ge 1 ]; then
    TMP_MODELFILE=$(mktemp)
    trap 'rm -f "$TMP_MODELFILE"' EXIT
    sed "s|^FROM[[:space:]].*|FROM $BASE_MODEL|" "$MODELFILE" > "$TMP_MODELFILE"
    BUILD_FROM="$TMP_MODELFILE"
else
    BUILD_FROM="$MODELFILE"
fi

info "Building $MODEL_NAME from $BASE_MODEL"
ollama create "$MODEL_NAME" -f "$BUILD_FROM"

info "Smoke test"
SAMPLE="um so let's meet tuesday no wait wednesday at four"
RESULT=$(printf '%s\n' "$SAMPLE" | ollama run --nowordwrap "$MODEL_NAME")
printf '    in:  %s\n    out: %s\n' "$SAMPLE" "$RESULT"
[ -n "$RESULT" ] || die "model returned no output; check 'ollama run $MODEL_NAME' by hand"

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
    cat >> "$CONFIG" <<EOF

# Added by voxtype-llm-wrapper/setup.sh
[output.post_process]
command = "ollama run --nowordwrap $MODEL_NAME"
timeout_ms = 30000
trim = true
fallback_on_empty = true
EOF
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
