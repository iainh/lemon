# Research: Lemon reliability hardening

**Date**: 2026-08-30
**Question**: Which changes would most improve Lemon's safety, consistency and operational resilience?
**Status**: Complete

## Context

Lemon already uses strong basic mechanisms: atomic private-file writes, directory
syncing, VM and disk locks, serialized capacity admission, contextual errors,
bounded launchd shutdown waits, and real macOS integration tests. This audit
therefore focused on malformed persisted state, concurrent CLI operations,
partial failures across filesystem and launchd state, resource exhaustion, and
dependency health.

The threat model is a per-user tool with no privileged daemon. The path issues
below don't cross the current user's operating-system permissions, but they do
cross Lemon's promised config and data boundaries and can cause unintended data
loss.

## Findings

### 1. Confine every derived path and validate persisted identities first

This is the highest-priority change. `validate_name` is used during create and
clone operations, but lookup, run and delete commands pass names directly into
`Store` path constructors. Deserialized configs are not checked to ensure their
internal name matches their filename.

Fault probes confirmed both data-loss paths:

- `lemon vm delete ../../victim --purge` removed `victim.toml` outside both test
  roots and exited successfully.
- Deleting `services/benign.toml` with an internal `name = "../../victim"` and
  `--purge-logs` removed `victim.log` outside the log directory.

Validate at the `Store` boundary, not only in clap handlers, because the hidden
`run-service` command and Home Manager definitions also load persisted data.
Require a valid lookup name, require the loaded name to equal the filename stem,
and validate all fields used to derive paths, labels, locks, and resource
identities. Add a reasonable name-length limit to fail before `NAME_MAX` or
launchd limits produce opaque errors.

Semantic validation should also reject zero CPUs, invalid MAC addresses,
duplicate MAC addresses, empty images, invalid VM references, and clearly
malformed memory or mapping values before installing a restart-enabled job.
Failing before launchd prevents permanent five-second crash loops.

### 2. Serialize definition and lifecycle mutations

Atomic replacement prevents torn files, but it does not make read-check-write
sequences atomic. In a 20-process probe that created one VM name, seven commands
reported success. The last rename silently selected the persisted definition.

The same gap affects cross-file invariants:

- two concurrent service creates can assign one VM twice;
- VM deletion can race a service that starts referencing it;
- service start can race deletion and reinstall an orphan LaunchAgent;
- clone cleanup can race another creator of the destination; and
- reconcile can race create or delete.

Use a store-wide exclusive mutation lock for CLI definition and launchd
transitions. The existing admission lock should remain focused on capacity.
Per-resource locks alone don't protect relationships such as service-to-VM
references. Home Manager remains an external writer, so the documented rule not
to mix owners still applies.

### 3. Remove write-on-read migration and make recovery deterministic

`Store::load_vm` generates and saves a random MAC address when an old definition
has none. This mutates state before the VM lock is acquired. In a concurrent
20-process start probe, one fake runtime acquired the lock, but another process
won the config-write race. The running MAC was `7e:f6:17:23:00:35`, while the
persisted MAC was `a6:f5:23:93:93:b2`; DHCP-based status and SSH discovery would
then look for the wrong guest.

Make reads side-effect free. For legacy definitions, either derive the same MAC
deterministically from the VM name, as the Home Manager module already does, or
perform an explicit migration while holding the store/VM mutation lock.

### 4. Make destructive operations idempotent after partial failure

`vm delete --purge` removes the definition before managed data. A permissions
fault in the data directory left the definition absent and the data present.
Repeating the command failed immediately because the definition no longer
existed, so Lemon could not finish its own requested cleanup.

Use a two-phase deletion marker or otherwise allow a validated purge to resume
when the definition is absent but the exact managed directory remains. Prefer a
recoverable orphan over a config that refers to deleted disks.

There is a related ambiguous-commit edge in `atomic_write`: after `rename`
succeeds, parent-directory `sync_all` can fail. The function then returns an
error even though the new path is visible. Clone treats any save error as proof
that the config was not committed and deletes the cloned data, which can leave
a visible definition referring to removed files. Callers must treat errors after
a possible rename as an unknown commit state and must not destructively roll
back dependencies without checking the durable target. Leaking staged data is
safer than creating a dangling definition.

### 5. Lock writable disks by file identity, not only canonical path

Disk sidecar locks hash each canonical path. Canonicalization resolves symlinks
but not hard links. A probe created two hard links to one inode; both VM runs
acquired different sidecar locks and exited successfully after running
concurrently. A real pair of vfkit processes could corrupt the shared disk.

Build the sidecar identity from the disk's device and inode on macOS, then sort
and deduplicate those identities before locking. Keep sidecars in Lemon's data
directory so lock support does not depend on the disk's filesystem. Add a hard
link regression test.

### 6. Bound logs while services are running

Lemon rotates logs only during `service start`, after the old job has stopped.
A long-running workload or a restart loop can therefore grow launchd's stdout
and stderr files until the filesystem fills. The 10 MiB threshold bounds only
logs present at a later manual restart, not active logs.

Choose an explicit bounded logging design. A Lemon-owned pipe/log sink can
rotate while preserving signal and exit-status semantics, but it is a larger
change. An operating-system logging facility is another option if it supports
per-user retention. Periodically renaming an actively opened file is not enough:
the runtime can continue writing the old inode, and disk space is not reclaimed
until it closes.

### 7. Upgrade or isolate the vulnerable plist dependency chain

`cargo audit` reports three advisories through the exact `plist = "=1.8.0"`
pin:

- `RUSTSEC-2026-0194`, high severity, quadratic XML attribute processing;
- `RUSTSEC-2026-0195`, high severity, unbounded XML namespace allocation; and
- `RUSTSEC-2026-0009`, medium severity, `time` stack exhaustion.

Lemon only calls `plist::to_writer_xml`, so the vulnerable parser paths do not
appear reachable today. The lockfile is still known-vulnerable, and future plist
reads could expose them silently. `plist 1.10.0` uses fixed `quick-xml 0.41` and
`time 0.3.47`, but raises its minimum supported Rust version (MSRV) from Lemon's
1.85 to 1.88. Decide explicitly between raising the MSRV and upgrading, or
retaining 1.85 with a replacement/backport. Add `cargo audit` to continuous
integration so new advisories cannot go unnoticed.

### 8. Preserve unknown launchd states

`launchd::status` and `loaded_program` treat every non-zero `launchctl print` as
“not loaded”. That includes permission, domain, and transient launchd failures,
not just the observed not-found status 113. This can undercount capacity, skip a
required stop, remove a plist while its job remains loaded, or attempt a
conflicting bootstrap.

Recognize the specific not-found result and return other failures with stderr
context. Make stop/delete idempotent around a concurrent not-found transition,
but don't convert unknown state into stopped state.

### 9. Reject timeout overflow instead of panicking

User-provided `u64` timeouts are added directly to `Instant`. The probe
`vm wait dev --timeout 18446744073709551615` panicked at `network.rs:13` with
“overflow when adding duration to instant” and exited 101. The SSH wait path has
the same pattern.

Set a practical clap range or use `Instant::checked_add` and return a normal
validation error. Library code should still use checked arithmetic even if clap
adds a bound.

### 10. Turn diagnostics and tests into release gates

`lemon doctor` exits zero when every required executable is missing; a probe
confirmed that result. It also checks only whether most paths are files, not
whether they are executable. Track failures, return non-zero when required
checks fail, and consider JSON output for automation. Check config semantics,
supported macOS/architecture, runtime versions, data-directory access, and
container-system initialization while continuing far enough to report all
problems.

The repository has no continuous-integration configuration. Default checks are
healthy, but the two highest-value macOS integration tests are ignored and run
only manually. Add CI for formatting, Clippy, unit tests, MSRV, Nix evaluation,
and dependency audit. Add fault-focused tests for malformed configs, concurrent
mutations, hard links, partial deletion, huge timeouts, and launchctl error
classification. A lightweight fake command boundary can cover most state
transitions without loading real LaunchAgents on every run.

## Options considered

| Area | Smallest useful change | Stronger design | Trade-off |
| --- | --- | --- | --- |
| Path safety | Validate every name before path construction | Validated config/domain types at the `Store` boundary | Boundary validation is enough if no unchecked constructors remain |
| Mutation races | One store-wide `flock` | Transaction journal with per-resource locks | A global lock is simpler and fits a small per-user CLI |
| Deletion | Permit safe, idempotent orphan cleanup | Tombstone and resumable two-phase deletion | Tombstones give clearer crash recovery but add state |
| Legacy MACs | Deterministic derivation | Explicit versioned migration command | Deterministic fallback is simpler; explicit migration scales better later |
| Logs | Document and monitor growth | Owned log sink or bounded system facility | True active rotation changes the process/logging architecture |
| plist audit | Raise MSRV to 1.88 and upgrade | Replace or backport serializer dependencies | Preserving Rust 1.85 requires more maintenance |

## Recommended order

1. **Safety patch:** confine names and loaded identities, make timeout arithmetic
   checked, lock disks by device/inode, and add regression tests for each proven
   failure.
2. **State consistency:** add the mutation lock, remove write-on-read MAC
   migration, and make deletion/ambiguous commits recoverable.
3. **Operational resilience:** implement bounded active logging, distinguish
   launchd errors, validate workload fields before bootstrap, and make `doctor`
   fail usefully.
4. **Release discipline:** resolve the plist advisories and add CI/MSRV/audit
   gates, then automate a safe fake-runtime integration tier.

## Verification performed

- `cargo fmt -- --check`: passed.
- `cargo clippy --all-targets -- -D warnings`: passed.
- `cargo test --all-targets`: 22 passed; two side-effecting integration tests
  remained ignored.
- `nix flake check --no-build`: passed evaluation.
- `cargo audit`: failed with the three advisories listed above.
- Focused temporary-directory fault probes reproduced path escape, concurrent
  create, legacy MAC divergence, hard-link lock bypass, non-resumable purge,
  timeout panic, and zero-exit doctor behaviour.

The ignored real-launchd container test and 1.3 GB Fedora VM test were not run
because they mutate the current GUI launchd domain or download and boot a full
guest.

## References

- `src/config.rs`: store paths, config loading, MAC migration and clone cleanup
- `src/cli.rs`: command validation, lifecycle ordering and doctor
- `src/fsutil.rs`: atomic replacement and directory sync
- `src/launchd.rs`: launchd state classification and log paths
- `src/logs.rs`: start-time-only log rotation
- `src/network.rs`: timeout deadline construction
- `src/runtime.rs`: disk sidecar identities and SSH timeout
- `Cargo.toml` and `Cargo.lock`: pinned plist dependency chain
- `tests/container_service.rs` and `tests/fedora_vm.rs`: ignored macOS integration coverage
