#!/usr/bin/env bash
# Install any Ruby version with RVM on macOS — Apple Silicon (arm64) and Intel.
#
# Usage:
#   scripts/install_ruby.sh <version> [--bg] [--dry-run]
#
# Examples:
#   scripts/install_ruby.sh 2.6.5            # legacy ruby on an M-series Mac
#   scripts/install_ruby.sh 2.6.5 --dry-run  # print the plan, build nothing
#   scripts/install_ruby.sh 2.7.1 --bg       # detached, poll the printed log
#   scripts/install_ruby.sh 3.3.8            # modern ruby, normal path
#
# Strategy (version- and arch-aware, normal build preferred):
#   1. Ruby >= 2.7.2 on arm64 (and everything on Intel) builds stock; the
#      script only pins PKG_CONFIG_PATH to OpenSSL 1.1 for Ruby < 3.1, which
#      cannot build against OpenSSL 3/4.
#   2. arm64 + Ruby <= 2.7.1 can never build stock (no __arm64__ branch in
#      configure + legacy fiddle closure API removed from the macOS SDK), so
#      the script skips the doomed normal attempt and goes straight to the
#      bundled Apple Silicon patch (verified to apply to 2.3.8 - 2.7.1).
#   3. OpenSSL 1.1 is EOL (2024-09-30) and is disappearing from Homebrew;
#      when `brew install openssl@1.1` no longer works, the script builds
#      1.1.1w from the official openssl.org tarball (sha256-verified) into
#      ~/.local/openssl-1.1.
#   4. The result is verified: arch, OpenSSL version, fiddle closures.
#
# Compatible with the system bash 3.2 on macOS (no bash 4+ features).

set -u

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <version> [--bg] [--dry-run]
  version   exact Ruby version to install, e.g. 2.6.5, 2.7.1, 3.3.8 (X.Y.Z)
  --bg      run detached in the background, log to ${TMPDIR:-/tmp}/rvm-ruby-<version>-install.log
  --dry-run print the plan and exit without building
EOF
  exit 2
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

# version_lt A B — true when A < B (dot-separated numeric versions).
version_lt() {
  local va vb i x y
  IFS=. read -ra va <<< "$1"
  IFS=. read -ra vb <<< "$2"
  i=0
  while [ "$i" -lt 4 ]; do
    x="${va[$i]:-0}"
    y="${vb[$i]:-0}"
    if [ "$x" -lt "$y" ]; then
      return 0
    fi
    if [ "$x" -gt "$y" ]; then
      return 1
    fi
    i=$((i + 1))
  done
  return 1
}

# ------------------------------------------------------------------- args ----
VERSION=""
BG=0
DRY_RUN=0
for arg in "$@"; do
  if [ "$arg" = "--bg" ]; then
    BG=1
  elif [ "$arg" = "--dry-run" ]; then
    DRY_RUN=1
  elif [ -z "$VERSION" ]; then
    VERSION="${arg#ruby-}"
  else
    usage
  fi
done
if [ -z "$VERSION" ]; then
  usage
fi
# Exact X.Y.Z required: rvm would resolve "2.7" to 2.7.8, which must NOT be
# patched (the configure hunk conflicts once the upstream __arm64__ branch
# already exists in 2.7.2+).
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
  die "unsupported version format: $VERSION (pass an exact X.Y.Z version, e.g. 2.7.1, not 2.7)"
fi
VERSION_BASE="${VERSION%%-*}"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_SRC="$SKILL_DIR/assets/ruby-pre-2.7.2-apple-silicon.patch"
PATCH_DST="$HOME/.rvm/patches/ruby-pre-2.7.2-apple-silicon.patch"
RVM_BIN="$HOME/.rvm/bin/rvm"
LOG="${TMPDIR:-/tmp}/rvm-ruby-$VERSION-install.log"

# /bin/rm is used explicitly everywhere: IDE safe-delete shims wrapping `rm`
# make autoconf fail with "failed to create .ext/include/<arch>/ruby/config.h".
CLEAN_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.rvm/bin"

# Ruby 2.6 only supports OpenSSL 1.1.x; the last release of that line.
OPENSSL_VERSION=1.1.1w
OPENSSL_URL="https://www.openssl.org/source/old/1.1.1/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
OPENSSL_LOCAL_PREFIX="$HOME/.local/openssl-1.1"

# ---------------------------------------------------------------- checks ----
if [ "$(uname -s)" != "Darwin" ]; then
  die "not macOS: $(uname -s)"
fi
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
  die "unsupported CPU arch: $ARCH (supported: arm64, x86_64)"
fi
if [ ! -x "$RVM_BIN" ]; then
  die "rvm not found at $RVM_BIN"
fi

# Ruby < 3.1 only supports OpenSSL 1.1 (OpenSSL 3 support landed in Ruby 3.1).
NEEDS_OPENSSL11=0
if version_lt "$VERSION_BASE" "3.1"; then
  NEEDS_OPENSSL11=1
fi

# arm64 + Ruby <= 2.7.1 cannot build stock: configure has no __arm64__ branch
# (empty arch like "-darwin25") and ext/fiddle uses the removed legacy closure
# API. Both are fixed by the bundled patch; both landed upstream in 2.7.2.
NEEDS_PATCH=0
if [ "$ARCH" = "arm64" ] && version_lt "$VERSION_BASE" "2.7.2"; then
  NEEDS_PATCH=1
fi
if [ "$NEEDS_PATCH" = "1" ] && [ ! -f "$PATCH_SRC" ]; then
  die "patch not found at $PATCH_SRC"
fi

# --------------------------------------------------------------- homebrew ----
BREW_BIN=""
if command -v brew >/dev/null 2>&1; then
  BREW_BIN="$(command -v brew)"
elif [ -x /opt/homebrew/bin/brew ]; then
  BREW_BIN=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
  BREW_BIN=/usr/local/bin/brew
fi
BREW_PREFIX=""
if [ -n "$BREW_BIN" ]; then
  BREW_PREFIX="$("$BREW_BIN" --prefix 2>/dev/null)"
fi
if [ -n "$BREW_PREFIX" ] && [ ! -d "$BREW_PREFIX" ]; then
  BREW_PREFIX=""
fi

# --------------------------------------------------------------- openssl ----
# Resolution order for OpenSSL 1.1 (Ruby < 3.1):
#   1. an existing Homebrew openssl@1.1 install
#   2. a previous source build at ~/.local/openssl-1.1
#   3. `brew install openssl@1.1` (may fail: the EOL formula is being removed)
#   4. build 1.1.1w from the official tarball into ~/.local/openssl-1.1
resolve_openssl11() {
  if [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX/opt/openssl@1.1" ]; then
    OPENSSL11="$BREW_PREFIX/opt/openssl@1.1"
    return 0
  fi
  if [ -d "$OPENSSL_LOCAL_PREFIX" ]; then
    OPENSSL11="$OPENSSL_LOCAL_PREFIX"
    return 0
  fi
  return 1
}

sha256_of() {
  /usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
}

build_openssl11() {
  local tarball="$HOME/.local/src/openssl-$OPENSSL_VERSION.tar.gz"
  local srcdir="$HOME/.local/src/openssl-$OPENSSL_VERSION"
  local build_path="/usr/bin:/bin:/usr/sbin:/sbin"
  local target

  if [ "$ARCH" = "arm64" ]; then
    target="darwin64-arm64-cc"
  else
    target="darwin64-x86_64-cc"
  fi

  mkdir -p "$HOME/.local/src"
  if [ "$(sha256_of "$tarball")" != "$OPENSSL_SHA256" ]; then
    log "downloading $OPENSSL_URL"
    /bin/rm -f "$tarball"
    if ! /usr/bin/curl -fSL --retry 3 -o "$tarball" "$OPENSSL_URL"; then
      return 1
    fi
    if [ "$(sha256_of "$tarball")" != "$OPENSSL_SHA256" ]; then
      log "ERROR: sha256 mismatch for $tarball (expected $OPENSSL_SHA256)"
      return 1
    fi
  fi
  /bin/rm -rf "$srcdir"
  mkdir -p "$srcdir"
  if ! /usr/bin/tar -xzf "$tarball" -C "$srcdir" --strip-components=1; then
    return 1
  fi
  # Build with a clean PATH so IDE-injected shims cannot interfere.
  if ! (cd "$srcdir" &&
      env PATH="$build_path" ./Configure "$target" \
        --prefix="$OPENSSL_LOCAL_PREFIX" \
        --openssldir="$OPENSSL_LOCAL_PREFIX/ssl" shared no-tests &&
      env PATH="$build_path" make -j"$(/usr/sbin/sysctl -n hw.ncpu)" &&
      env PATH="$build_path" make install_sw install_ssldirs); then
    return 1
  fi
  log "openssl $OPENSSL_VERSION installed to $OPENSSL_LOCAL_PREFIX"
  return 0
}

# Cheap resolution first (directory checks only, no side effects).
OPENSSL11=""
if [ "$NEEDS_OPENSSL11" = "1" ]; then
  resolve_openssl11
fi

# ------------------------------------------------------------------- plan ----
if "$RVM_BIN" list strings 2>/dev/null | grep -qx "ruby-$VERSION"; then
  RVM_ACTION="reinstall"
else
  RVM_ACTION="install"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "plan for ruby-$VERSION on $ARCH (rvm $RVM_ACTION):"
  if [ "$NEEDS_PATCH" = "1" ]; then
    log "  build:       patched (a stock build cannot succeed: configure lacks the __arm64__ branch before 2.7.2 and ext/fiddle uses the removed legacy closure API)"
    log "  patch:       $PATCH_DST"
  else
    log "  build:       normal rvm $RVM_ACTION $VERSION (no patch needed)"
  fi
  if [ "$NEEDS_OPENSSL11" = "1" ]; then
    if [ -n "$OPENSSL11" ]; then
      log "  openssl 1.1: $OPENSSL11"
    else
      log "  openssl 1.1: required, none found yet (would brew install or build $OPENSSL_VERSION from source)"
    fi
  else
    log "  openssl:     system default (Ruby >= 3.1)"
  fi
  exit 0
fi

if [ "$BG" = "1" ]; then
  nohup bash "$0" "$VERSION" </dev/null >"$LOG" 2>&1 &
  log "started in background (pid $!), poll with: tail -f $LOG"
  exit 0
fi

# Full OpenSSL 1.1 resolution (side effects allowed from here on).
if [ "$NEEDS_OPENSSL11" = "1" ] && [ -z "$OPENSSL11" ]; then
  log "openssl@1.1 not found (Ruby < 3.1 needs OpenSSL 1.1)"
  if [ -n "$BREW_BIN" ]; then
    log "trying: brew install openssl@1.1"
    if "$BREW_BIN" install openssl@1.1 && [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX/opt/openssl@1.1" ]; then
      OPENSSL11="$BREW_PREFIX/opt/openssl@1.1"
    fi
  fi
  if [ -z "$OPENSSL11" ]; then
    log "falling back to building OpenSSL $OPENSSL_VERSION from source into $OPENSSL_LOCAL_PREFIX"
    if ! build_openssl11; then
      die "OpenSSL $OPENSSL_VERSION source build failed (Ruby < 3.1 needs OpenSSL 1.1)"
    fi
    OPENSSL11="$OPENSSL_LOCAL_PREFIX"
  fi
fi
if [ "$NEEDS_OPENSSL11" = "1" ]; then
  if [ ! -f "$OPENSSL11/lib/pkgconfig/openssl.pc" ]; then
    die "no pkgconfig for openssl@1.1 at $OPENSSL11"
  fi
  log "openssl@1.1: $("$OPENSSL11/bin/openssl" version 2>/dev/null)"
fi

# ----------------------------------------------------------------- patch ----
if [ "$NEEDS_PATCH" = "1" ]; then
  mkdir -p "$HOME/.rvm/patches"
  cp "$PATCH_SRC" "$PATCH_DST"
  log "patch ready: $PATCH_DST"
fi

# Drop stale sources so the tarball is re-extracted cleanly.
clean_src() {
  /bin/rm -rf "$HOME/.rvm/src/ruby-$VERSION"
}

# ---------------------------------------------------------------- install ---
# run_install <use_patch: 0|1> — rvm action with clean PATH and, when
# OPENSSL11 is set, PKG_CONFIG_PATH pinned to OpenSSL 1.1.
run_install() {
  if [ "$1" = "1" ]; then
    if [ -n "$OPENSSL11" ]; then
      env PATH="$CLEAN_PATH" PKG_CONFIG_PATH="$OPENSSL11/lib/pkgconfig" \
        "$RVM_BIN" "$RVM_ACTION" "$VERSION" --patch "$PATCH_DST" </dev/null
    else
      env PATH="$CLEAN_PATH" \
        "$RVM_BIN" "$RVM_ACTION" "$VERSION" --patch "$PATCH_DST" </dev/null
    fi
  else
    if [ -n "$OPENSSL11" ]; then
      env PATH="$CLEAN_PATH" PKG_CONFIG_PATH="$OPENSSL11/lib/pkgconfig" \
        "$RVM_BIN" "$RVM_ACTION" "$VERSION" </dev/null
    else
      env PATH="$CLEAN_PATH" \
        "$RVM_BIN" "$RVM_ACTION" "$VERSION" </dev/null
    fi
  fi
}

clean_src
if [ "$NEEDS_PATCH" = "1" ]; then
  log "running: rvm $RVM_ACTION $VERSION --patch (log: $LOG)"
  run_install 1 2>&1 | tee "$LOG"
  if [ "${PIPESTATUS[0]}" != "0" ]; then
    die "patched install failed, see $LOG and ~/.rvm/log/*_ruby-$VERSION/"
  fi
else
  log "running: rvm $RVM_ACTION $VERSION (log: $LOG)"
  run_install 0 2>&1 | tee "$LOG"
  if [ "${PIPESTATUS[0]}" != "0" ]; then
    die "normal install failed, see $LOG and ~/.rvm/log/*_ruby-$VERSION/ (newest: ls -td ~/.rvm/log/*_ruby-$VERSION | head -1)"
  fi
fi

# ---------------------------------------------------------------- verify ----
log "--- verification ---"
RUBY_V="$("$RVM_BIN" "$VERSION" do ruby -v 2>/dev/null)"
log "$RUBY_V"
if printf '%s\n' "$RUBY_V" | grep -q "\[${ARCH}-darwin"; then
  log "arch: ok ($ARCH)"
elif printf '%s\n' "$RUBY_V" | grep -q "\[-darwin"; then
  die "arch is broken (empty CPU): ${RUBY_V:-<empty>} — on arm64 this means the configure __arm64__ patch did not apply; see references/troubleshooting.md"
else
  die "unexpected ruby -v output: ${RUBY_V:-<empty>}"
fi
if ! "$RVM_BIN" "$VERSION" do ruby -ropenssl -e 'puts "openssl: #{OpenSSL::OPENSSL_VERSION}"'; then
  die "openssl check failed for ruby-$VERSION"
fi
if ! "$RVM_BIN" "$VERSION" do ruby -e 'require "fiddle"
cb = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INT, [Fiddle::TYPE_INT]) { |x| x * 2 }
r = cb.call(21)
if r != 42
  raise "fiddle closure broken: #{r}"
end
puts "fiddle closure: ok"'; then
  die "fiddle closure check failed for ruby-$VERSION"
fi
"$RVM_BIN" "$VERSION" do ruby -e 'puts "arch: #{RbConfig::CONFIG["arch"]} / sitearch: #{RbConfig::CONFIG["sitearch"]}"'
"$RVM_BIN" list
log "done. use it with: rvm use $VERSION"
