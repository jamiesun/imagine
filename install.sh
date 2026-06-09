#!/bin/sh
# imagine installer — POSIX sh, curl-pipeable.
#
#   curl -fsSL https://raw.githubusercontent.com/terateams/imagine/main/install.sh | sh
#
# Downloads the prebuilt `imagine` binary for your platform and installs it to
# ~/.local/bin, plus the `imagine` agent skill to ~/.agents/skills/imagine.
# Detects OS/arch automatically. If no prebuilt binary is available it falls
# back to building from source with Zig. Override anything with the env vars:
#
#   IMAGINE_REPO        GitHub repo            (default terateams/imagine)
#   IMAGINE_VERSION     release tag to install (default latest, e.g. v0.1.0)
#   IMAGINE_REF         git ref for fallbacks  (default main)
#   IMAGINE_BIN_DIR     binary install dir     (default $HOME/.local/bin)
#   IMAGINE_AGENTS_DIR  agents dir             (default $HOME/.agents)
#   IMAGINE_SKILL_DIR   skill install dir      (default AGENTS_DIR/skills/imagine)
#   IMAGINE_NO_SKILL=1  skip skill install
#   IMAGINE_NO_BIN=1    skip binary install
#   IMAGINE_NO_VERIFY=1 skip SHA256 checksum verification

set -eu

REPO="${IMAGINE_REPO:-terateams/imagine}"
VERSION="${IMAGINE_VERSION:-latest}"
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

# ----- temp workspace ----------------------------------------------------
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT HUP TERM
tmpdir() {
  [ -n "$TMP" ] || TMP=$(mktemp -d 2>/dev/null || mktemp -d -t imagine)
  printf '%s' "$TMP"
}

# ----- download helper ---------------------------------------------------
# dl <url> <dest> -> 0 on success (non-empty file), 1 otherwise
dl() {
  _url="$1"; _dest="$2"
  if have curl; then
    curl -fsSL "$_url" -o "$_dest" 2>/dev/null && [ -s "$_dest" ]
  elif have wget; then
    wget -qO "$_dest" "$_url" 2>/dev/null && [ -s "$_dest" ]
  else
    return 1
  fi
}

# ----- detect platform ---------------------------------------------------
os_raw=$(uname -s 2>/dev/null || echo unknown)
arch_raw=$(uname -m 2>/dev/null || echo unknown)
case "$os_raw" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS: $os_raw (this installer covers macOS and Linux; on Windows download imagine-windows-*.exe from the releases page)" ;;
esac
case "$arch_raw" in
  arm64|aarch64) ARCH=aarch64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) die "unsupported arch: $arch_raw" ;;
esac
info "platform: ${OS}-${ARCH}"

# ----- release URL base --------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  REL_BASE="https://github.com/$REPO/releases/latest/download"
else
  REL_BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

# ----- lazy source fetch (only used by fallbacks) ------------------------
SRC=""
fetch_source() {
  [ -n "$SRC" ] && return 0
  if [ -f "./build.zig" ] && [ -d "./skills/imagine" ]; then
    SRC=$(pwd); info "using local checkout: $SRC"; return 0
  fi
  _t=$(tmpdir)
  if have git; then
    info "cloning $REPO@$REF ..."
    git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$_t/src" >/dev/null 2>&1 \
      || die "git clone failed"
    SRC="$_t/src"
  elif have tar && have curl; then
    info "downloading $REPO@$REF tarball ..."
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" | tar -xz -C "$_t" \
      || die "tarball download/extract failed"
    SRC=$(find "$_t" -maxdepth 1 -type d -name 'imagine-*' | head -n1)
    [ -n "$SRC" ] || die "could not locate extracted source"
  else
    die "need git or (tar + curl) to fetch source for fallback build"
  fi
}

# Prefer a local checkout's skill if present (dev convenience).
LOCAL_SRC=0
if [ -f "./build.zig" ] && [ -d "./skills/imagine" ]; then SRC=$(pwd); LOCAL_SRC=1; fi

# ----- checksum verification ---------------------------------------------
SUMS=""
sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}';
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}';
  else return 1; fi
}
load_sums() {
  [ "${IMAGINE_NO_VERIFY:-0}" = "1" ] && return 1
  have sha256sum || have shasum || return 1
  [ -n "$SUMS" ] && return 0
  _t=$(tmpdir)
  dl "$REL_BASE/SHA256SUMS" "$_t/SHA256SUMS" || return 1
  SUMS="$_t/SHA256SUMS"; return 0
}
# verify <file> <asset-name>
verify() {
  load_sums || { return 0; }
  _want=$(awk -v n="$2" '$2==n || $2=="*"n {print $1}' "$SUMS" | head -n1)
  [ -n "$_want" ] || { warn "no checksum listed for $2; skipping verify"; return 0; }
  _got=$(sha256_of "$1") || return 0
  if [ "$_want" = "$_got" ]; then ok "verified $2 (sha256)"; else
    die "checksum mismatch for $2
       expected $_want
       got      $_got"
  fi
}

# ----- acquire the binary ------------------------------------------------
if [ "${IMAGINE_NO_BIN:-0}" != "1" ]; then
  ASSET="${BIN_NAME}-${OS}-${ARCH}"
  T=$(tmpdir)
  BIN_SRC=""
  info "downloading $ASSET ($VERSION) ..."
  if dl "$REL_BASE/$ASSET" "$T/$BIN_NAME"; then
    verify "$T/$BIN_NAME" "$ASSET"
    chmod +x "$T/$BIN_NAME"
    BIN_SRC="$T/$BIN_NAME"
    ok "downloaded prebuilt binary"
  else
    warn "no prebuilt binary for ${OS}-${ARCH} at $VERSION; building from source ..."
    have zig || die "Zig is required to build from source.
       Install it from https://ziglang.org/download/ (need >= 0.16.0), then re-run.
       On macOS: brew install zig"
    fetch_source
    ( cd "$SRC" && zig build -Doptimize=ReleaseFast -Dstrip=true ) || die "zig build failed"
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
  mkdir -p "$SKILL_DIR"
  if [ "$LOCAL_SRC" = "1" ]; then
    cp -R "$SRC/skills/imagine/." "$SKILL_DIR/"
    ok "skill  -> $SKILL_DIR (from local checkout)"
  else
    T=$(tmpdir)
    if dl "$REL_BASE/imagine-skill.tar.gz" "$T/skill.tgz"; then
      verify "$T/skill.tgz" "imagine-skill.tar.gz"
      mkdir -p "$T/skill"
      tar -xzf "$T/skill.tgz" -C "$T/skill" || die "failed to extract skill archive"
      cp -R "$T/skill/imagine/." "$SKILL_DIR/"
      ok "skill  -> $SKILL_DIR"
    else
      warn "no skill archive at $VERSION; fetching from source ..."
      fetch_source
      [ -d "$SRC/skills/imagine" ] || die "skill source not found at $SRC/skills/imagine"
      cp -R "$SRC/skills/imagine/." "$SKILL_DIR/"
      ok "skill  -> $SKILL_DIR (from source)"
    fi
  fi
fi

# ----- final guidance ----------------------------------------------------
printf '\n'
ok "${BLD}imagine installed.${RST}"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add this to your shell rc:"
     # shellcheck disable=SC2016  # literal $PATH is intentional (user pastes it)
     printf '       export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac
printf '\nNext steps:\n'
printf '  1. imagine config init       # write ~/.imagine/config.json\n'
printf '  2. export AZURE_API_KEY=...   # or edit the config\n'
printf '  3. imagine generate -m gpt-image-1.5 -p "a red fox in autumn" -o fox.png\n'
