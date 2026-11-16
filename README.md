# sqlite32kcolumns

Multi-platform build of **SQLite** and **CPython** with `SQLITE_MAX_COLUMN=32767`
(the hard upper bound SQLite permits; default is 2000).

The default releases are **SQLite 3.54.1** (`3540100`, release year `2026`)
and **CPython 3.15.2**.

## Why rebuild Python?

Short answer: **you don't strictly have to, but it's the cleanest path for
redistribution.** `SQLITE_MAX_COLUMN` is a compile-time constant in SQLite
itself, not in Python. Python's `sqlite3` module is a thin C wrapper around
whichever `libsqlite3` it's linked against, so the limit is inherited from
that library.

Two valid strategies:

| Strategy | Pros | Cons |
|---|---|---|
| **Swap the library only.** Build a patched `libsqlite3.so` / `sqlite3.dll` and drop it next to an existing Python (via `LD_PRELOAD`, rpath, or replacing `DLLs/sqlite3.dll` on Windows). | Fast; no Python rebuild. | Fragile — depends on the host Python's linkage; breaks if Python statically links SQLite (e.g. official macOS installers sometimes do). |
| **Rebuild CPython from source** against the patched SQLite amalgamation. | Self-contained, redistributable, guaranteed. | Slow CI; bigger artifacts. |

This repo does **both**: it produces standalone SQLite artifacts *and* a
rebuilt CPython that statically embeds the correct limit.

## Artifacts produced

Per platform (`linux-x64`, `linux-arm64`, `macos-arm64`, `windows-x64`):

- `sqlite-<target>/` — `libsqlite3.*` / `sqlite3.dll`, `sqlite3` CLI, headers, amalgamation source
- `python-<target>/` — full CPython install tree linked against the patched SQLite

Every successful CI run on `main` (including manual runs) publishes a GitHub
Release tagged `ci-<run-number>-<run-attempt>`, with all platform artifacts as
`.tar.gz` assets. Releases target the exact commit built. Pushing a `v*` tag
continues to publish a release using that tag.

## Platforms

| Target | Runner | Notes |
|---|---|---|
| linux-x64 | `ubuntu-latest` | glibc, gcc |
| linux-arm64 | `ubuntu-24.04-arm` | native ARM GitHub runner |
| macos-arm64 | `macos-15` | Apple Silicon, `-mmacosx-version-min=11.0` |
| windows-x64 | `windows-latest` | MSVC, CPython's `PCbuild` |
| windows-arm64 | `windows-11-arm` | native ARM64 MSVC, `PCbuild -p arm64` |

No Intel-mac, no 32-bit by default — add them to the matrix if you need
them. macOS universal2 is doable but inflates build time significantly.

## Running locally

```bash
# Linux / macOS
./scripts/build_sqlite_unix.sh linux-x64
./scripts/build_python_unix.sh linux-x64
./scripts/test_32k_unix.sh   linux-x64
```

```powershell
# Windows
./scripts/build_sqlite_windows.ps1
./scripts/build_python_windows.ps1
./scripts/test_32k_windows.ps1
```

## Tuning

Workflow inputs (`workflow_dispatch`):

- `sqlite_version` — amalgamation version id, e.g. `3540100` for 3.54.1
- `sqlite_year` — release year folder in the download URL
- `python_version` — CPython source release, e.g. `3.15.2`
- `max_column` — the value to pass as `-DSQLITE_MAX_COLUMN`

## How the limit is injected

- **SQLite build (both OSes):** `-DSQLITE_MAX_COLUMN=32767` is passed to the
  compiler when building the amalgamation. Verified via
  `pragma_compile_options` and by actually creating a 20k-column table.
- **CPython on Linux/macOS:** `CPPFLAGS`/`LDFLAGS` point `configure` at the
  patched SQLite sysroot; rpath is set so `_sqlite3.*.so` resolves our
  `libsqlite3` first. The patched `libsqlite3` is copied into
  `dist/python-<target>/lib/`.
- **CPython on Windows:** the selected SQLite amalgamation is downloaded
  separately and selected via the `sqlite3Dir` environment variable, which
  MSBuild imports as a property, overriding CPython's bundled SQLite.
  Setting `CL=/DSQLITE_MAX_COLUMN=32767`
  before invoking the build propagates the define into every `cl.exe`
  invocation, including the sqlite3 project. `PC/layout/main.py` then produces
  a redistributable tree.

## Caveats

- The SQLite download URL encodes a year (`/2026/`). When bumping
  `sqlite_version`, bump `sqlite_year` to match.
- `--enable-optimizations` makes CPython's configure slow; drop it if you
  need faster CI iteration.
- `SQLITE_MAX_COLUMN` is capped at **32767** by SQLite itself. Values above
  that are silently clamped.
- The smoke test creates a 20,000-column table, which is above the stock
  default (2000) and well below the new ceiling — enough to prove the limit
  was raised. It also checks the SQLite version and configured column limit.
