#!/bin/sh
# imagine installer — POSIX sh, curl-pipeable.
#
#   curl -fsSL https://raw.githubusercontent.com/terateams/imagine/main/install.sh | sh
#
# Installs the `imagine` binary to ~/.local/bin (PATH default) and the
# `imagine` skill to ~/.agents/skills/imagine. Detects OS/arch. Uses a
# prebuilt release binary when available, otherwise builds from source
# with Zig. Override any path with the env vars below.
#
#   IMAGINE_REPO        GitHub repo            (default terateams/imagine)
#   IMAGINE_REF         git ref / branch       (default main)
#   IMAGINE_BIN_DIR     binary install dir     (default $HOME/.local/bin)
#   IMAGINE_AGENTS_DIR  agents dir             (default $HOME/.agents)
#   IMAGINE_SKILL_DIR   skill install dir      (default AGENTS_DIR/skills/imagine)
#   IMAGINE_NO_SKILL=1  skip skill install
#   IMAGINE_NO_BIN=1    skip binary install

set -eu

REPO="${IMAGINE_REPO:-terateams/imagine}"
REF="${IMAGINE_REF:-main}"
BIN_DIR="${IMAGINE_BIN_DIR:-$HOME/.local/bin}"
AGENTS_DIR="${IMAGINE_AGENTS_DIR:-$HOME/.agents}"
SKILL_DIR="${IMAGINE_SKILL_DIR:-$AGENTS_DIR/skills/imagine}"
BIN_NAME="imagine"

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

# ----- detect platform ---------------------------------------------------
os_raw=$(uname -s 2>/dev/null || echo unknown)
arch_raw=$(uname -m 2>/dev/null || echo unknown)
case "$os_raw" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS: $os_raw (only macOS and Linux are supported)" ;;
esac
case "$arch_raw" in
  arm64|aarch64) ARCH=aarch64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) die "unsupported arch: $arch_raw" ;;
esac
info "platform: ${OS}-${ARCH}"

# ----- locate or fetch the source tree -----------------------------------
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT HUP TERM

SRC=""
if [ -f "./build.zig" ] && [ -d "./skills/imagine" ]; then
  SRC=$(pwd)
  info "using local checkout: $SRC"
else
  have curl || die "curl is required"
  TMP=$(mktemp -d 2>/dev/null || mktemp -d -t imagine)
  if have git; then
    info "cloning $REPO@$REF ..."
    git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$TMP/src" >/dev/null 2>&1 \
      || die "git clone failed"
    SRC="$TMP/src"
  else
    have tar || die "need git or tar to fetch source"
    info "downloading $REPO@$REF tarball ..."
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" | tar -xz -C "$TMP" \
      || die "tarball download/extract failed"
    SRC=$(find "$TMP" -maxdepth 1 -type d -name 'imagine-*' | head -n1)
    [ -n "$SRC" ] || die "could not locate extracted source"
  fi
fi

# ----- acquire the binary ------------------------------------------------
BIN_SRC=""
if [ "${IMAGINE_NO_BIN:-0}" != "1" ]; then
  ASSET="${BIN_NAME}-${OS}-${ARCH}"
  ASSET_URL="https://github.com/$REPO/releases/latest/download/$ASSET"
  TMP_DL="${TMP:-$(mktemp -d 2>/dev/null || mktemp -d -t imagine)}"
  [ -n "$TMP" ] || TMP="$TMP_DL"
  if have curl && curl -fsSL "$ASSET_URL" -o "$TMP_DL/$BIN_NAME" 2>/dev/null \
       && [ -s "$TMP_DL/$BIN_NAME" ]; then
    chmod +x "$TMP_DL/$BIN_NAME"
    BIN_SRC="$TMP_DL/$BIN_NAME"
    ok "downloaded prebuilt binary"
  else
    info "no prebuilt binary; building from source with Zig ..."
    have zig || die "Zig is required to build from source.
       Install it from https://ziglang.org/download/ (need >= 0.16.0), then re-run.
       On macOS: brew install zig"
    ( cd "$SRC" && zig build -Doptimize=ReleaseFast ) || die "zig build failed"
    BIN_SRC="$SRC/zig-out/bin/$BIN_NAME"
    [ -f "$BIN_SRC" ] || die "build produced no binary at $BIN_SRC"
    ok "built from source"
  fi

  mkdir -p "$BIN_DIR"
  install -m 0755 "$BIN_SRC" "$BIN_DIR/$BIN_NAME" 2>/dev/null \
    || { cp "$BIN_SRC" "$BIN_DIR/$BIN_NAME" && chmod 0755 "$BIN_DIR/$BIN_NAME"; }
  ok "binary -> $BIN_DIR/$BIN_NAME"
fi

# ----- install the skill -------------------------------------------------
if [ "${IMAGINE_NO_SKILL:-0}" != "1" ]; then
  [ -d "$SRC/skills/imagine" ] || die "skill source not found at $SRC/skills/imagine"
  mkdir -p "$SKILL_DIR"
  cp -R "$SRC/skills/imagine/." "$SKILL_DIR/"
  ok "skill  -> $SKILL_DIR"
fi

# ----- final guidance ----------------------------------------------------
printf '\n'
ok "${BLD}imagine installed.${RST}"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add this to your shell rc:"
     printf '       export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac
printf '\nNext steps:\n'
printf '  1. imagine config init      # write ~/.imagine/config.json\n'
printf '  2. export AZURE_API_KEY=...  # or edit the config\n'
printf '  3. imagine generate -m gpt-image-1.5 -p "a red fox in autumn" -o fox.png\n'
