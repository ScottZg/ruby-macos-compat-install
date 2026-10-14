---
name: ruby-macos-compat-install
description: Install any Ruby version with RVM on macOS, on both Apple Silicon (M-series, arm64) and Intel (x86_64) Macs, handling the known compatibility gaps automatically. For Ruby <= 2.7.1 on arm64 it applies the bundled Apple Silicon patch (configure __arm64__ branch + fiddle legacy closure API fix); for Ruby < 3.1 it resolves OpenSSL 1.1, building 1.1.1w from source when Homebrew no longer provides the EOL formula. This skill should be used when installing a Ruby version with rvm on a Mac, when `rvm install <version>` fails, when the build log shows `ffi_prep_closure` / `-Wimplicit-function-declaration` in ext/fiddle, `ERR_get_error_line_data is deprecated` in ext/openssl, or when rvm reports the installed ruby as `[ broken ]` with an empty arch like `-darwin25`.
---

# Ruby compat installer for macOS (arm64 + Intel)

Install any Ruby version with RVM on any Mac. The installer is version- and
arch-aware: it prefers the normal `rvm install` flow and only applies the
bundled Apple Silicon patch or OpenSSL 1.1 pinning when the combination is
known to need them.

## When to use

- Installing any Ruby version with RVM on macOS, especially legacy versions.
- `rvm install <version>` / `rvm reinstall <version>` fails on an arm64 Mac.
- make.log contains `error: call to undeclared function 'ffi_prep_closure'`.
- make.log contains `'ERR_get_error_line_data' is deprecated [-Werror,-Wdeprecated-declarations]`.
- `rvm list` shows the ruby as `[ broken ]`, or `ruby -v` prints `[-darwin25]`
  (empty CPU) instead of `[arm64-darwin25]`.

## Compatibility matrix

| Ruby version | Apple Silicon (arm64) | Intel (x86_64) |
|---|---|---|
| <= 2.7.1 (incl. 2.3.x - 2.6.x) | bundled patch + OpenSSL 1.1 | OpenSSL 1.1 |
| 2.7.2 - 3.0.x | OpenSSL 1.1 | OpenSSL 1.1 |
| >= 3.1 | nothing special | nothing special |

Boundaries (verified against the official tarballs):

- **2.7.2** is the first arm64-native Ruby: the `configure` `__arm64__` branch
  and the fiddle `HAVE_FFI_CLOSURE_ALLOC` detection both landed there
  (2.7.0/2.7.1 contain neither; on arm64 a stock build of anything older
  cannot succeed).
- **3.1** is the first Ruby supporting OpenSSL 3.x; older rubies must build
  against OpenSSL 1.1.
- The bundled patch applies cleanly to every release from 2.3.8 to 2.7.1
  (`patch --dry-run` verified); the full patched build is verified on 2.6.5
  (arm64, macOS 26 SDK).

## Quick path (recommended)

```bash
<skill-dir>/scripts/install_ruby.sh <version>            # e.g. 2.6.5, 2.7.1, 3.3.8
<skill-dir>/scripts/install_ruby.sh <version> --dry-run  # print the plan, build nothing
<skill-dir>/scripts/install_ruby.sh <version> --bg       # detached, poll the printed log
```

`<skill-dir>` is the directory containing this `SKILL.md`, e.g.
`~/.claude/skills/ruby-macos-compat-install` (Claude Code) or
`~/.codebuddy/skills/ruby-macos-compat-install` (CodeBuddy).

What the script decides automatically:

1. **Normal build preferred**: clean PATH (IDE-injected `rm` shims break
   autoconf), plus `PKG_CONFIG_PATH` pinned to OpenSSL 1.1 for Ruby < 3.1.
2. **arm64 + Ruby <= 2.7.1**: a stock build can never succeed (see the
   blockers below), so the script skips the doomed normal attempt and builds
   with the bundled patch directly.
3. **OpenSSL 1.1 resolution** (Ruby < 3.1): existing Homebrew install ->
   previous source build at `~/.local/openssl-1.1` -> `brew install
   openssl@1.1` -> build 1.1.1w from the official openssl.org tarball
   (sha256-verified) into `~/.local/openssl-1.1`.
4. **Verification**: arch, OpenSSL, fiddle closures.

A full build takes roughly 6-10 minutes (`#configuring` alone can take 3-5
minutes). Pass exact `X.Y.Z` versions (`2.7.1`, not `2.7` — rvm would resolve
`2.7` to 2.7.8, which must not be patched).

## The three blockers (arm64, Ruby <= 2.7.1)

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | `closure.c:264: error: call to undeclared function 'ffi_prep_closure'` | Ruby <= 2.7.1 hard-codes `USE_FFI_CLOSURE_ALLOC 0` on Apple; the macOS SDK arm64 libffi sets `FFI_LEGACY_CLOSURE_API 0`, so the legacy closure API is gone | Patch `ext/fiddle/closure.c` to use `ffi_closure_alloc` + `ffi_prep_closure_loc` on `__APPLE__ && __arm64__` (bundled; fixed upstream in 2.7.2) |
| 2 | `ossl.c:311: error: 'ERR_get_error_line_data' is deprecated` | `ext/openssl/extconf.rb` calls `pkg_config("openssl")` first, which resolves to Homebrew `openssl` (3.x/4.x); Ruby < 3.1 only supports OpenSSL 1.1 | Build with `PKG_CONFIG_PATH` pinned to an OpenSSL 1.1 install (script resolves or builds it) |
| 3 | `ruby -v` shows `[-darwin25]`, `rvm list` shows `[ broken ]`, `sitearch` is the literal `${arch}` | Ruby <= 2.7.1 `configure` detects Apple CPU only for `x86_64/i386/ppc/ppc64` (no `__arm64__` branch, added in 2.7.2), so `target_cpu` ends up empty | Patch `configure` to add the `__arm64__` branch (bundled) |

Blocker 1 is also a **runtime** correctness fix, not just a build fix: on arm64
the legacy path stores the closure struct pointer as the entry point, which is
not executable code. The patch makes fiddle closures actually work.

Blockers 1 and 3 are arm64-only; Intel Macs only ever hit blocker 2.

## Environment requirements

- RVM (`~/.rvm/bin/rvm`).
- OpenSSL 1.1 for Ruby < 3.1 (Ruby cannot build against OpenSSL 3/4).
  OpenSSL 1.1 is EOL (2024-09-30) and is being removed from Homebrew; the
  script resolves it as described above and builds 1.1.1w from source when
  needed.
- Xcode command line tools / Xcode with an SDK matching the running macOS.
- Never run the build with an IDE-injected `rm` shim on PATH; symptom is
  `configure: error: failed to create .ext/include/<arch>/ruby/config.h`.

## Manual path

1. For arm64 + Ruby <= 2.7.1, copy the patch and clean stale sources:

```bash
cp <skill-dir>/assets/ruby-pre-2.7.2-apple-silicon.patch ~/.rvm/patches/
/bin/rm -rf ~/.rvm/src/ruby-<version>
```

2. Install with a **clean PATH** (IDE-injected `rm` shims break autoconf) and,
   for Ruby < 3.1, `PKG_CONFIG_PATH` pinned to OpenSSL 1.1:

```bash
cd ~ && nohup env \
  PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.rvm/bin" \
  PKG_CONFIG_PATH=/opt/homebrew/opt/openssl@1.1/lib/pkgconfig \
  ~/.rvm/bin/rvm install <version> \
  --patch ~/.rvm/patches/ruby-pre-2.7.2-apple-silicon.patch \
  </dev/null > /tmp/rvm-<version>.log 2>&1 &
```

Drop `--patch` for Ruby >= 2.7.2 or on Intel; drop `PKG_CONFIG_PATH` for
Ruby >= 3.1. If your OpenSSL 1.1 is not a Homebrew install (e.g. built to
`~/.local/openssl-1.1` by the script's fallback), point `PKG_CONFIG_PATH` at
`~/.local/openssl-1.1/lib/pkgconfig` instead. Use `rvm reinstall` instead of
`rvm install` when a (broken) ruby already exists. Poll with
`tail -f /tmp/rvm-<version>.log`.

3. Verify:

```bash
rvm <version> do ruby -v                                   # ruby ... [<arch>-darwinXX]
rvm <version> do ruby -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION'
rvm <version> do ruby -e 'require "fiddle"; c = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INT,[Fiddle::TYPE_INT]) { |x| x * 2 }; puts c.call(21)'  # 42
rvm <version> do ruby -e 'puts RbConfig::CONFIG["sitearch"]'
rvm list
```

## Reusing the patch for other rubies

The bundled patch is generated against `ruby-2.6.5` and verified to apply
cleanly to every release from 2.3.8 to 2.7.1. For anything else, regenerate
it: extract the pristine files from the tarball, apply the two edits (see
`references/troubleshooting.md` for the exact snippets), and produce a
unified diff with `a/` `b/` prefixes so RVM can apply it with `-p1`.

## References

- `references/troubleshooting.md` — version compatibility map, error
  signatures, how to read the rvm logs, how to regenerate/adapt the patch,
  and recovery from partial states.
