# Troubleshooting Ruby builds on macOS (arm64 + Intel)

## Version compatibility map

Which Ruby needs what on which Mac:

| Ruby | Apple Silicon (arm64) | Intel (x86_64) |
|---|---|---|
| <= 2.7.1 (2.3.x - 2.7.1) | bundled patch + OpenSSL 1.1 | OpenSSL 1.1 only |
| 2.7.2 - 3.0.x | OpenSSL 1.1 only | OpenSSL 1.1 only |
| >= 3.1 | nothing special | nothing special |

Why the boundaries are where they are (all verified against the official
tarballs):

- **2.7.2** is the first release that builds natively on arm64: the
  `configure` `__arm64__` branch and the fiddle `HAVE_FFI_CLOSURE_ALLOC`
  feature detection both landed there. 2.7.0/2.7.1 contain neither — they
  need exactly the same patches as 2.6.x.
- **3.1** is the first release supporting OpenSSL 3.x (openssl gem 3.0);
  older rubies must be built against OpenSSL 1.1.

The bundled patch (`assets/ruby-pre-2.7.2-apple-silicon.patch`) applies
cleanly (verified with `patch --dry-run`) to every release from 2.3.8 to
2.7.1. Only 2.6.5 has been fully build-tested; older lines may hit further
compiler incompatibilities unrelated to these blockers.

## Partial versions are rejected

`rvm install 2.7` would resolve to 2.7.8 — which must NOT be patched (the
configure hunk conflicts once the upstream `__arm64__` branch already
exists). The install script therefore requires exact `X.Y.Z` versions.

## Where the logs are

Each `rvm install` run creates `~/.rvm/log/<timestamp>_ruby-<version>/`
containing `configure.log`, `make.log`, `extract.log`, `update_system.log`,
`patch.apply.*.log`. Pick the newest directory:

```bash
ls -t ~/.rvm/log | head -3
```

Fast triage of a failed build:

```bash
LOG=$(ls -td ~/.rvm/log/*_ruby-2.6.5 | head -1)
grep -n "error:" "$LOG/make.log" | head
grep -n "Error [0-9]" "$LOG/make.log" | head
```

`make.log` is interleaved because of `-j10`; always grep for `error:` rather
than reading the tail. The decisive line is the *first* `error:` in the log.

## Error signatures

### `closure.c:264:14: error: call to undeclared function 'ffi_prep_closure'`

Affects Ruby <= 2.7.1 on arm64 with recent macOS SDKs. Confirm the cause
before patching:

```bash
SDK=$(xcrun --show-sdk-path)
grep -n "FFI_LEGACY_CLOSURE_API" "$SDK/usr/include/ffi/ffitarget_arm64.h"   # -> 0
grep -n "ffi_prep_closure\b" "$SDK/usr/include/ffi/ffi.h"                   # guarded by #if FFI_LEGACY_CLOSURE_API
```

Ruby <= 2.7.1 `ext/fiddle/closure.c` contains:

```c
#elif defined(__OpenBSD__) || defined(__APPLE__) || defined(__linux__)
# define USE_FFI_CLOSURE_ALLOC 0
```

Fix snippet (inserted before `#if defined(USE_FFI_CLOSURE_ALLOC)`):

```c
#if defined(__APPLE__) && defined(__arm64__)
/* macOS SDK libffi (>= macOS 26) removed the legacy ffi_prep_closure on arm64:
 * FFI_LEGACY_CLOSURE_API is 0, so use ffi_closure_alloc + ffi_prep_closure_loc. */
# define USE_FFI_CLOSURE_ALLOC 1
#endif
```

Alternative (not recommended): point ruby at Homebrew libffi 3.8, which still
exports the deprecated `ffi_prep_closure`. It compiles, but the legacy entry point
is wrong on arm64, so closures break at runtime.

Upstream fixed this in 2.7.2 by switching to feature detection
(`#elif !defined(HAVE_FFI_CLOSURE_ALLOC)`), so 2.7.2+ never needs this patch.

### `ossl.c:311:14: error: 'ERR_get_error_line_data' is deprecated`

Affects every Ruby < 3.1 when pkg-config resolves to OpenSSL 3/4. The note
lines in the error reveal which headers were used:

```
/opt/homebrew/Cellar/openssl@4/4.0.3/include/openssl/err.h:380: note: ... marked deprecated here
```

Diagnose without rebuilding:

```bash
pkg-config --modversion openssl                                                   # 3.x/4.x -> wrong for Ruby < 3.1
PKG_CONFIG_PATH=/opt/homebrew/opt/openssl@1.1/lib/pkgconfig pkg-config --modversion openssl   # 1.1.1w -> right
```

`ext/openssl/extconf.rb` runs `pkg_config("openssl")` first, so the pkg-config
result beats `--with-opt-dir`. Always pass the env var; do not rely on
`--with-openssl-dir` alone for Ruby < 3.1.

Ruby < 3.1 supports only OpenSSL 1.1.x — with 3.x/4.x headers it fails on
many more deprecations, so never try to force 3.x.

OpenSSL 1.1 is EOL (2024-09-30) and Homebrew is removing the `openssl@1.1`
formula, so `brew install openssl@1.1` may fail on a fresh machine. The install
script then builds 1.1.1w from the official openssl.org tarball (sha256-verified)
into `~/.local/openssl-1.1`; point `PKG_CONFIG_PATH` at
`~/.local/openssl-1.1/lib/pkgconfig` in that case:

```bash
PKG_CONFIG_PATH=~/.local/openssl-1.1/lib/pkgconfig pkg-config --modversion openssl   # 1.1.1w
```

### `configure: error: failed to create .ext/include/-darwin25/ruby/config.h`

Two different problems can produce this message.

1. An IDE-injected `rm` shim on PATH (some IDEs wrap `rm` with a safe-delete
   confirmation layer). Symptom: the log is full of safe-delete confirmation
   lines (e.g. `[safe-delete]...`) and configure is extremely slow. Fix: run
   with a clean PATH (see SKILL.md) and use `/bin/rm`.
2. The `-darwin25` arch itself (empty CPU) — see next section.

### `ruby -v` prints `[-darwin25]`, `rvm list` shows `[ broken ]`

Affects Ruby <= 2.7.1 on arm64. Ruby's `configure` computes the real Apple
CPU by preprocessing:

```sh
target_cpu=`$CC -E - 2>/dev/null <<EOF |
#ifdef __x86_64__
"processor-name=x86_64"
#endif
...
#ifdef __ppc64__
"processor-name=powerpc64"
#endif
EOF
```

There is no `__arm64__` branch (Ruby 2.7.2 added one), so on Apple Silicon
`target_cpu` becomes empty and `arch` becomes `-darwin25`, leaving
`RbConfig::CONFIG['sitearch']` as the literal string `${arch}`.
Fix by adding before the closing `EOF`:

```c
#ifdef __arm64__
"processor-name=arm64"
#endif
```

Verify after install: `ruby -v` must print `[arm64-darwin25]` and
`RbConfig::CONFIG["sitearch"]` must print `arm64-darwin25`.

## Regenerating the patch

The bundled `assets/ruby-pre-2.7.2-apple-silicon.patch` is a unified diff
with `a/` and `b/` prefixes, applied by RVM with `-p1`. It is generated
against `ruby-2.6.5` and verified to apply cleanly to 2.3.8 - 2.7.1. To
rebuild it for a different ruby:

```bash
SRC=~/.rvm/src/ruby-2.6.5
PRI=/tmp/pristine
mkdir -p $PRI
tar -xjf ~/.rvm/archives/ruby-2.6.5.tar.bz2 -C $PRI ruby-2.6.5/configure ruby-2.6.5/ext/fiddle/closure.c
# edit $SRC/configure and $SRC/ext/fiddle/closure.c, then:
cd $SRC
diff -u --label a/configure --label b/configure $PRI/ruby-2.6.5/configure configure > /tmp/p1.diff || true
diff -u --label a/ext/fiddle/closure.c --label b/ext/fiddle/closure.c \
     $PRI/ruby-2.6.5/ext/fiddle/closure.c ext/fiddle/closure.c > /tmp/p2.diff || true
cat /tmp/p1.diff /tmp/p2.diff > ~/.rvm/patches/ruby-pre-2.7.2-apple-silicon.patch
```

`diff` exits 1 when files differ, so guard it with `|| true`.

RVM resolves `--patch` values against `/`, `$PWD`, `~/.rvm/patches/<ruby>/...`;
an absolute path works and shows up in the log as `//Users/...`.

## Recovery from partial states

- Stop a running install: `pkill -f "rvm install"` then
  `/bin/rm -rf ~/.rvm/src/ruby-<version>`.
- `rvm install` skips work when the ruby already exists; use `rvm reinstall`
  (or `rvm remove <version>` first) when iterating on the build.
- Existing gemsets survive a `reinstall`; rvm runs `gemset pristine` at the end.
  Non-default gems are usually gone and must be reinstalled with `bundle install`.
- If `rvm list` still shows `[ broken ]` while `ruby -v` works, the arch is
  wrong (blocker 3) — rebuild with the `configure` patch.
