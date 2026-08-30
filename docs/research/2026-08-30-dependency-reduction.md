# Research: Purpose-specific dependency reduction

**Date**: 2026-08-30
**Question**: Which dependencies can Lemon safely replace with small, owned implementations or narrower platform facilities?
**Status**: Complete

## Context

Lemon has 10 direct runtime dependencies. Cargo resolves 66 packages in the
normal dependency graph and 88 packages in `Cargo.lock`. The stripped release
binary is currently about 1.71 MB. Binary size is not the main concern because
the linker already removes unused code; the stronger reasons to reduce the
graph are audit exposure, compile work, minimum supported Rust version (MSRV)
pressure, and ownership clarity.

The right boundary is purpose-specific integration. Copying a general-purpose
crate into Lemon would retain its maintenance burden while losing upstream
fixes. Small local code is justified only where Lemon uses a narrow, stable
subset that can be exhaustively tested.

## Recommendation

Remove `plist` and `directories` outright, remove `sha2` from the runtime graph
as part of inode-based disk locking, prune unused Clap features, and replace the
test-only `xz2` library with the existing `xz` tool. Keep the dependencies that
own complex grammars, public output contracts, CLI behaviour, operating-system
ABIs, error context, and randomness.

Removing `plist`, `directories`, and runtime `sha2` reduces the normal graph
from 66 to about 45 packages. Removing Clap's `wrap_help` feature would reduce
it by another four, to about 41. These counts include Lemon itself and assume
`sha2` remains available only to tests.

## Remove or narrow

### 1. Replace `plist` with one restricted launchd serializer

**Current use:** two calls to `plist::to_writer_xml`, both in `launchd.rs`.
Lemon never parses a plist. It emits only:

- a top-level dictionary;
- string keys and values;
- ordered string arrays;
- booleans;
- nonnegative decimal integers; and
- one nested dictionary for `KeepAlive.SuccessfulExit`.

**Cost:** `plist` brings 11 otherwise-unneeded normal packages: `plist`,
`base64`, `indexmap`, `equivalent`, `hashbrown`, `quick-xml`, `time`,
`deranged`, `powerfmt`, `num-conv`, and `time-core`. It also brings the three
known audit advisories recorded in the reliability audit.

**Recommended integration:** define a typed `LaunchdJob` that represents only
Lemon's launchd schema and serialize that structure directly to XML property
list 1.0. Don't recreate a generic `Value` enum or parser.

The writer must:

1. emit the UTF-8 declaration, Apple plist 1.0 doctype, and one root `<plist>`;
2. emit each dictionary key next to exactly one value;
3. preserve `ProgramArguments` order;
4. encode booleans as `<true/>` and `<false/>`;
5. write integers in decimal;
6. escape `&`, `<`, and `>` in keys and string values;
7. preserve empty strings and whitespace; and
8. reject NUL and other characters forbidden by XML 1.0.

Dictionary order does not affect launchd validity, but fixed output order makes
diffs and tests deterministic. Reject non-UTF-8 paths explicitly rather than
continuing the current lossy conversion.

Tests should inspect the typed job fields, cover escaping and invalid controls,
and pipe complete generated jobs through `/usr/bin/plutil -lint`. A probe
confirmed that `plutil` accepts the required booleans, integers, arrays, nested
dictionaries, and escaped strings.

**Alternative:** serialize the typed job to JSON with the retained `serde_json`
dependency, then invoke `/usr/bin/plutil -convert xml1`. This delegates plist
encoding to Apple and is viable because service management is macOS-only. The
local writer is preferable: it avoids a new subprocess failure boundary and the
required format is small enough to test exhaustively.

**Do not:** copy the whole `rust-plist` writer. Its MIT licence permits reuse,
but a clean implementation of Lemon's fixed schema is smaller and avoids
inheriting generic stream semantics.

### 2. Replace `directories` with the documented macOS path

**Current use:** one `ProjectDirs::from("dev", "lemon", "lemon")` call.

On macOS, `directories 6.0` computes both `config_dir()` and `data_dir()` as:

```text
$HOME/Library/Application Support/dev.lemon.lemon
```

This matches Lemon's README and Home Manager module. The crate brings
`directories`, `dirs-sys`, and `option-ext`; `libc` is already retained.

Use one local home-directory helper for both `Store::discover` and
`launchd::agent_path`. Accept a non-empty absolute `HOME`, then append the fixed
macOS path. Return a clear error for a missing, empty, or relative value. Keep
the existing paired `LEMON_CONFIG_DIR` and `LEMON_DATA_DIR` override.

This intentionally drops one obscure compatibility behaviour: `directories`
falls back to `getpwuid_r` when `HOME` is missing or empty and accepts relative
`HOME` values. Exact compatibility would require about 30 lines of unsafe passwd
lookup. It is not worthwhile because launchd agent paths already require
`HOME`, and rejecting relative roots improves path safety.

### 3. Remove `sha2` from production with inode-based locks

**Current use:** hashing canonical disk paths into safe sidecar filenames.

The reliability audit recommends locking by macOS device and inode to prevent
hard links from bypassing writable-disk exclusion. Formatting those two integer
identifiers directly into the sidecar filename removes the production need for
SHA-256 and seven exclusive normal packages: `sha2`, `digest`, `block-buffer`,
`generic-array`, `typenum`, `crypto-common`, and `cpufeatures`.

The ignored Fedora test still uses SHA-256 to verify a downloaded image. The
lowest-risk first step is to move `sha2` to `dev-dependencies`, which removes it
from release builds without weakening checksum verification. If eliminating it
from the lockfile is important, invoke the already-available macOS `shasum -a
256` tool and validate its output and exit status. That test already depends on
external `curl`, `xz`, `ssh-keygen`, and vfkit tools, so another explicit test
prerequisite is acceptable.

### 4. Prune Clap features, but keep Clap

**Current use:** 44 derive/argument declarations across a nested command tree.
Replacing Clap would recreate parsing, help, validation, error diagnostics,
`--` handling, and shell-safe argument semantics in Lemon. Keep it.

The `env` feature is enabled but no argument uses `#[arg(env = ...)]`; remove it.
This strips unused Clap code but does not remove a package.

The `wrap_help` feature pulls in `terminal_size`, `rustix`, `bitflags`, and
`errno`. Removing it would save four normal packages. First capture help output
for the root and each command group at narrow and wide terminal sizes. Remove
the feature only if unwrapped output remains readable or source descriptions
can be wrapped clearly. Coloured diagnostics and typo suggestions should stay;
they improve CLI usability and failure recovery.

### 5. Replace test-only `xz2` with `xz`

**Current use:** one ignored integration test expands a Fedora `.raw.xz` image.
The Nix development shell already includes `xz` in `testPackages`, and the test
already checks for several external tools.

Run `xz --decompress --stdout`, stream its stdout into the destination file,
check both process and I/O results, then sync the file. This removes `xz2` and
its native `lzma-sys` build chain. It should also allow the Nix package's
compile-time `buildInputs = [ pkgs.xz ]` to be removed while retaining `xz` in
the development/test tool set.

## Keep

| Dependency | Why it should remain |
| --- | --- |
| `anyhow` | Lemon uses 68 context attachments and 31 `bail!` sites. Replacing it would add pervasive custom error plumbing with worse diagnostics. |
| `clap` | It owns a large CLI grammar and user-facing parsing/error contract. Prune features instead. |
| `serde` + `toml` | TOML is Lemon's persisted and Home Manager-generated configuration contract. A local parser/serializer would be a major correctness and compatibility risk. |
| `serde_json` | JSON output is a public automation contract. Correct escaping and schema serialization are worth the small retained graph; the Fedora test also parses external JSON. |
| `libc` | Lemon uses platform constants and ABIs for `clonefile`, `flock`, `fcntl`, and `getuid`. Hand-written declarations would be brittle and unsafe. |
| `getrandom` | Two calls cover MAC generation and collision-resistant temporary names. Its two-package graph is smaller and safer than owning cross-platform entropy FFI. |
| `tempfile` | Twelve test sites rely on reliable unique creation and recursive cleanup under parallel tests. A local test helper would save little and is easy to get wrong. |

## Options considered

| Option | Benefits | Costs | Recommendation |
| --- | --- | --- | --- |
| Upgrade to `plist 1.10` | Small code change; resolves current advisories | Keeps generic graph; raises MSRV to 1.88 | Fallback only if local serialization is not desired |
| Vendor selected crate source | No crates.io dependency at build time | Lemon owns copied generic code and licence notices; upstream fixes become manual | Avoid |
| Use `/usr/bin/plutil` for every job | Apple owns plist conversion; reuses `serde_json` | Adds process spawning and error handling to every agent write | Viable second choice |
| Write a generic local plist library | No external dependency | Recreates unnecessary parser/value complexity | Avoid |
| Write only Lemon's launchd schema | Small fixed surface; exhaustive tests; no parser chain | Lemon owns XML escaping and validation | Preferred |
| Replace Clap or TOML/JSON | Large package-count reduction | High bug risk in public grammars and automation contracts | Reject |
| Replace `getrandom` with `arc4random_buf` | Removes two packages | Adds unsafe platform FFI and complicates non-macOS compilation | Reject while `getrandom` remains this small |

## Implementation order

1. Add the typed launchd job and restricted XML serializer, validate with
   `plutil`, then remove `plist`. This immediately resolves all current audit
   findings.
2. Introduce the shared absolute-home helper and remove `directories`.
3. Change disk locks to device/inode identity and move `sha2` to development
   scope.
4. Remove Clap's `env` feature; assess `wrap_help` with help snapshots before
   removing it.
5. Replace `xz2` in the ignored Fedora test and simplify Nix build inputs.
6. Re-run formatting, Clippy, unit tests, `cargo audit`, Nix checks, generated
   plist validation, and both manual macOS integration tests.

Keep these as separate reviewable changes. The plist change alters file
generation, home discovery changes state location selection, and inode locking
changes concurrency identity; combining them would make regressions harder to
isolate.

## Verification performed

- Confirmed every direct dependency use with repository-wide symbol searches.
- Counted 66 packages in the normal Cargo graph and 88 lockfile packages.
- Built a release binary; it was 2,179,352 bytes before stripping and 1,707,928
  bytes after standard macOS symbol stripping.
- Traced `directories 6.0` macOS path and fallback behaviour to its source.
- Traced `plist 1.8` XML framing, value encoding, order, and escaping to its
  source and tests.
- Confirmed `/usr/bin/plutil` accepts and validates Lemon's required plist value
  forms.

No source or manifest changes were made as part of this research.

## References

- `Cargo.toml` and `Cargo.lock`
- `src/launchd.rs`: `plist` use and launchd job schema
- `src/config.rs`: `ProjectDirs` use
- `src/runtime.rs`: SHA-256 disk sidecar names
- `tests/fedora_vm.rs`: SHA-256 and XZ test-only uses
- `nix/flake.nix`: XZ build and test inputs
- `docs/research/2026-08-30-reliability-hardening.md`
