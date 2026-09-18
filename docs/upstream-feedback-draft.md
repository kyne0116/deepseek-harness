# Upstream feedback draft — Build and packaging gaps when cross-building the linux-x64 runtime from Windows

> Status: DRAFT for an umbrella GitHub issue against deepseek-ai/deepseek-harness.
> Splitting into per-issue reports can be done after triage. Internal reference numbers F1–F7
> match `DSH部署/10.218.180.41至60/DSH_构建打包指南_...md` §3.6 in our fork.
>
> Environment: Windows 10 x64 build host, pnpm 11.7.0, Node 24.19, pkg (@yao-pkg/pkg) 6.21.0
> (--sea route), target node24-linux-x64, dsh 0.1.5-rc.2 lineage + 0.1.6-alpha.2 master.
> Everything below was reproduced on 2026-09-17/18 and worked around in our fork
> (branch `fix/sea-pkg-readdir-dirent`, commits ae9198d4fd / df4f21c40f / be0e9bf613 / b83e19f881).
> The resulting wheel was deployed to an intranet server and validated end-to-end
> (session create + LLM round-trip).

## Summary

A truly clean checkout cannot produce the linux-x64 single-exe runtime. Every failure we hit
was worked around, but each one was invisible to release verification because
`verify-packed-install` drives the installed product with **plain Node** (real fs, real
Dirents), while the shipped artifact is a pkg SEA binary whose virtual filesystem and
bootstrap behave differently. We suggest an SEA-mode boot + session-create smoke test as
the single highest-leverage CI addition; the individual gaps follow.

## F1 — pkg SEA prelude: `SEAProvider.readdirSync(dirPath)` drops the options argument

`fs.promises.readdir(dir, { withFileTypes: true })` over snapshot paths returns **bare
string arrays**: `sea-vfs-setup.js`'s `SEAProvider.readdirSync(dirPath)` ignores `options`
(`entries.slice()` fast path; the `super.readdirSync(p)` fallback also drops it). Any
`withFileTypes` consumer inside the packaged runtime breaks on first call — for us, agent
preset discovery (`scanRoot`) crashed with `child.isDirectory is not a function`, failing
every session creation. 93 call sites read `withFileTypes` in the bundle; preset discovery
was merely the first.

Notes:
- The bug exists in **two copies**: `prelude/sea-vfs-setup.js` (standalone) and the copy
  inlined in `prelude/sea-bootstrap.bundle.js` — the latter is what `sea.js:630` actually
  injects. Patching only the standalone file does nothing.
- `@roberts_lando/vfs`'s own `VirtualFileSystem.readdirSync` handles `withFileTypes`
  correctly; the bug is in the pkg-side provider subclass that overrides it.
- Why CI missed it: preset discovery runs on session creation, and no SEA-mode test
  creates a session.

Fix (in our `patches/@yao-pkg__pkg@6.21.0.patch`): accept `options`, build Dirent-like
entries from the manifest (`stats`/`symlinks`), forward options on the super fallback.
Node has no public `fs.Dirent` constructor, hence a local emulation with UV_DIRENT
numbering. Also fixed for the worker-bootstrap string copy if feasible.

## F2 — Root package tsdown entries have no producer on a clean tree

`tsdown.config.ts` (root) declares host-face entries
`lib/types/{index,invariant,startup}.js` for `@deepseek-ai/dsh-root`, but the root package
has no TypeScript sources and no tsc project emits these files. A clean checkout fails
tsdown with `Cannot resolve entry module lib/types/index.js`. The brace-glob form also
resolves inconsistently under tsdown's bundled globber; spelling the three names literally
plus materializing empty `export {}` stubs is our workaround. Longer term the entries
should either have a declared producer or the root target should be skipped when absent.

## F3 — Clean-build deadlock: cross-face implicit dependencies and unstable failure points

`build:lib` runs host tsdown before client tsc/tsdown, yet host-phase bundling consumes
client-face products (e.g. `client/hmr`'s `lib/types/invariant.js` companion), and
`pnpm deploy` output completeness depends on earlier phases. A failure mid-pipeline leaves
a differently-broken tree each time: retrying a single step on the half-built tree fails
at a *different* point than the original failure, so the failure set drifts across retries
(we observed four distinct failure signatures across four runs of the same inputs).
Recommendation: make each face self-contained, or declare and enforce the full ordering.
Until then the only reliable mode is "always run the whole pipeline from scratch", which
is what our fork's build guide now mandates.

## F4 — tsdown parallel clean race deletes entry files

Entry files live inside their own `outDir` (e.g. entry `lib/types/invariant.js`,
outDir `lib`). With 200+ workspace targets building in parallel, one target's clean can
delete another target's just-produced or about-to-be-read entry file. `--no-clean` for
both faces makes the run deterministic. (Related to F3; listed separately because the
fix differs.)

## F5 — `pnpm install` can leave per-package node_modules partially linked

After a `pnpm install` (notably following a `pnpm patch-commit`), full-workspace tsc
reported 100+ `Cannot find module 'zod' / '@xterm/headless' / 'clsx'` errors — the
per-package links were missing while root-level resolution worked. Re-running
`pnpm install` healed it. Not reliably reproducible; adding a post-install link
self-check (or diagnosing the pruning condition) would save people a very confusing hour.

## F6 — linux native binaries have no provisioning path for cross-builds

`native/system/packages/linux-x64` ships `bin/landlock-run`,
`bin/glibc/system.node` (flock Node-API addon) and `bin/musl/system.node` as **build
artifacts that are not in git**; the Windows host cannot build them. `pnpm deploy`
therefore stages the package metadata without `bin/`, and the packaged runtime fails at
session persistence (`Cannot find module .../bin/glibc/system.node` from
`node-addon-system/lib/flock.js`). We extracted `bin/` from the published npm tarball
(`@deepseek-ai/node-addon-system-linux-x64@0.1.2`, same version) back into the workspace
package before deploying. If the published tarball is the sanctioned source, a build step
that fetches it automatically (mirroring the supportedArchitectures treatment the other
optional platform packages get) would close the gap. Note: `landlock-run` has no file
extension and is not matched by the packaging ASSET_GLOBS (`**/*.node` etc.), so the
Landlock launcher still does not reach the snapshot — sandbox features remain limited in
exe deployments.

## F7 — The browser UI hard-depends on the client face, which has no CI protection

`lib/client.js` per package (browser-side service modules) is produced by the client-face
tsdown pass. If the client face fails (it is gated by a full client tsc of the workspace),
every package's `lib/client.js` goes missing and the browser boot reports
`Failed to load plugins — 22 entries did not activate — waiting for services: sessions`
with the whole UI inert while the gateway itself still answers RPCs. Same CI blind spot
as F1: nothing exercises the browser boot against a freshly built artifact. Our build
guide now marks the client face as a hard, must-succeed step.

## Test blind spot (cross-cutting)

`scripts/release/verify-packed-install.ts` states it drives the installed product "with
plain Node". For the single-exe artifact this verifies packaging completeness but none of
the in-snapshot runtime behavior: virtual-fsDirents, bootstrap module resolution, native
addon loading from the snapshot, and profile/plugin-tree loading are all invisible to it.
Suggest: an SEA-mode smoke that boots `web`, creates a session against a fixture
workspace, and asserts the client boot graph is non-empty. That single test would have
caught F1, F6, and F7 before they reached a user.

## Patches we can share

- `patches/@yao-pkg__pkg@6.21.0.patch`: F1 fix (both copies) — applies via pnpm
  patchedDependencies; happy to upstream into @yao-pkg/pkg / platformatic vfs.
- `tsdown.config.ts` literal-entry change + companion stub policy: F2.
- `packages/preset/agent-presets/src/discovery.ts`: Dirent-shim-proof stat fallback
  (defense in depth for F1-class shims).
- `scripts/build-python-release.py` / `hatch_build.py`: POSIX exec-bit handling on
  Windows hosts (already in our branch; see also the existing
  `supportedArchitectures`/node-pty prebuild enablers).
