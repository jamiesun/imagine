#!/bin/sh
# Qwen-Image-2.1 local server installer — the install half of the optional
# `qwen_image` integration. POSIX sh, source-checkout or curl-pipeable.
#
#   integrations/qwen-image/install.sh            # venv + dependencies
#   integrations/qwen-image/install.sh --prefetch # also download the weights
#   integrations/qwen-image/install.sh --mock     # light deps only, wiring test
#
# It creates a self-contained venv (nothing is installed system-wide), copies
# server.py next to it, and writes a `qwen-image-server` launcher. Your imagine
# config is only touched with --write-config.
#
# Options:
#   --home DIR      install dir        (default ~/.imagine/qwen-image)
#   --bin-dir DIR   launcher dir       (default ~/.local/bin)
#   --python CMD    python interpreter (default python3)
#   --model ID      model to serve     (default Qwen/Qwen-Image-2.1)
#   --prefetch      download model weights into the HF cache now
#   --mock          install fastapi/uvicorn/pillow only (no torch/diffusers)
#   --write-config  append the qwen-image-2.1 model block to the imagine config
#   --no-launcher   skip the qwen-image-server launcher
#   -h, --help
#
# Env: QWEN_IMAGE_HOME, QWEN_IMAGE_BIN_DIR, QWEN_IMAGE_MODEL, IMAGINE_CONFIG,
#      IMAGINE_REPO (default talkincode/imagine), IMAGINE_REF (default main)

set -eu

REPO="${IMAGINE_REPO:-talkincode/imagine}"
REF="${IMAGINE_REF:-main}"
HOME_DIR="${QWEN_IMAGE_HOME:-$HOME/.imagine/qwen-image}"
BIN_DIR="${QWEN_IMAGE_BIN_DIR:-$HOME/.local/bin}"
PYTHON="${QWEN_IMAGE_PYTHON:-python3}"
MODEL="${QWEN_IMAGE_MODEL:-Qwen/Qwen-Image-2.1}"
MODEL_KEY="qwen-image-2.1"
PORT="${QWEN_IMAGE_PORT:-8000}"
PREFETCH=0
MOCK=0
WRITE_CONFIG=0
LAUNCHER=1

RED=''; GRN=''; YLW=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
  BLD=$(printf '\033[1m'); RST=$(printf '\033[0m')
fi
info() { printf '%s\n' "${BLD}==>${RST} $*"; }
ok()   { printf '%s\n' "${GRN}ok ${RST} $*"; }
warn() { printf '%s\n' "${YLW}warn${RST} $*" >&2; }
die()  { printf '%s\n' "${RED}error${RST} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --home)         HOME_DIR="$2"; shift 2 ;;
    --bin-dir)      BIN_DIR="$2"; shift 2 ;;
    --python)       PYTHON="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    --prefetch)     PREFETCH=1; shift ;;
    --mock)         MOCK=1; shift ;;
    --write-config) WRITE_CONFIG=1; shift ;;
    --no-launcher)  LAUNCHER=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ----- prerequisites ------------------------------------------------------
have "$PYTHON" || die "'$PYTHON' not found. Install Python 3.10+ (or pass --python /path/to/python3)."
"$PYTHON" - <<'PY' || die "need Python 3.10 or newer"
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
info "python: $("$PYTHON" -c 'import sys; print(sys.executable, sys.version.split()[0])')"

# ----- fetch the server sources ------------------------------------------
SRC_DIR=$(dirname "$0")
if [ -f "$SRC_DIR/server.py" ]; then
  SRC_DIR=$(cd "$SRC_DIR" && pwd)
else
  SRC_DIR=""
  have curl || have wget || die "need 'curl' or 'wget' to download server.py"
  info "downloading server.py from ${REPO}@${REF}"
fi

mkdir -p "$HOME_DIR"
fetch() { # fetch <name> <dest>
  if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/$1" "$2"
  elif have curl; then
    curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/integrations/qwen-image/$1" -o "$2"
  else
    wget -qO "$2" "https://raw.githubusercontent.com/$REPO/$REF/integrations/qwen-image/$1"
  fi
}
fetch server.py "$HOME_DIR/server.py"
fetch requirements.txt "$HOME_DIR/requirements.txt"
ok "server   -> $HOME_DIR/server.py"

# ----- virtualenv + dependencies -----------------------------------------
if [ ! -x "$HOME_DIR/venv/bin/python" ]; then
  info "creating venv at $HOME_DIR/venv"
  "$PYTHON" -m venv "$HOME_DIR/venv"
fi
VENV_PY="$HOME_DIR/venv/bin/python"
VENV_PIP="$HOME_DIR/venv/bin/pip"
[ -x "$VENV_PIP" ] || VENV_PIP="$HOME_DIR/venv/bin/pip3"
PIP_ARGS="--disable-pip-version-check -q"

if [ "$MOCK" = "1" ]; then
  info "installing light dependencies (mock mode: no torch/diffusers)"
  "$VENV_PIP" install $PIP_ARGS fastapi uvicorn pillow
else
  info "installing dependencies (torch + diffusers; this can take a while)"
  "$VENV_PIP" install $PIP_ARGS -r "$HOME_DIR/requirements.txt"
fi

"$VENV_PY" - <<'PY' || die "dependency check failed; re-run with --python to pick another interpreter"
import fastapi, uvicorn, PIL  # noqa: F401
PY
ok "dependencies installed into $HOME_DIR/venv"

if [ "$PREFETCH" = "1" ]; then
  info "downloading weights for $MODEL into the Hugging Face cache"
  "$VENV_PY" - "$MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download

snapshot_download(sys.argv[1])
print("weights cached")
PY
  ok "weights cached (set HF_HOME to move the cache)"
fi

# ----- launcher -----------------------------------------------------------
if [ "$LAUNCHER" = "1" ]; then
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/qwen-image-server" <<EOF
#!/bin/sh
# Generated by imagine integrations/qwen-image/install.sh
exec "$VENV_PY" "$HOME_DIR/server.py" "\$@"
EOF
  chmod 0755 "$BIN_DIR/qwen-image-server"
  ok "launcher -> $BIN_DIR/qwen-image-server"
fi

# ----- optional: register the model in the imagine config ----------------
CONFIG_PATH="${IMAGINE_CONFIG:-$HOME/.imagine/config.toml}"
if [ "$WRITE_CONFIG" = "1" ]; then
  if [ -f "$CONFIG_PATH" ] && grep -q "\[models\.\"$MODEL_KEY\"\]" "$CONFIG_PATH"; then
    ok "config already lists model \"$MODEL_KEY\" ($CONFIG_PATH)"
  else
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cat >> "$CONFIG_PATH" <<EOF

[models."$MODEL_KEY"]
backend = "qwen_image"
api_model = "$MODEL"

[[models."$MODEL_KEY".endpoints]]
base_url = "http://127.0.0.1:$PORT/v1/images/generations"
auth = "none"

[models."$MODEL_KEY".defaults]
size = "2048x2048"
steps = 40
EOF
    ok "added model \"$MODEL_KEY\" to $CONFIG_PATH"
  fi
fi

# ----- next steps ---------------------------------------------------------
printf '\n'
ok "${BLD}Qwen-Image-2.1 server installed.${RST}"
if [ "$MOCK" = "1" ]; then
  warn "mock mode installs no model: generate with --mock to test the wiring only"
fi
printf '\nStart it:\n'
if [ "$LAUNCHER" = "1" ]; then
  printf '  qwen-image-server%s\n' "$([ "$MOCK" = "1" ] && printf ' --mock' || true)"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf '  # first: export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
  esac
else
  printf '  %s %s/server.py%s\n' "$VENV_PY" "$HOME_DIR" "$([ "$MOCK" = "1" ] && printf ' --mock' || true)"
fi
printf '\nThen, from another shell:\n'
if [ "$WRITE_CONFIG" = "1" ]; then
  printf '  imagine models                 # the model block is already in %s\n' "$CONFIG_PATH"
else
  printf '  imagine models                 # after adding the model block from\n'
  printf '  # integrations/qwen-image/README.md, or re-run with --write-config\n'
fi
printf '  # ... or skip the config file entirely:\n'
printf '  IMAGINE_BASE_URL=http://127.0.0.1:%s/v1/images/generations \\\n' "$PORT"
printf '  IMAGINE_MODEL=%s IMAGINE_BACKEND=qwen_image IMAGINE_AUTH=none \\\n' "$MODEL_KEY"
printf '    imagine generate -p "a neon Qwen sign" --size 16:9 --steps 40 -o qwen.png\n'
