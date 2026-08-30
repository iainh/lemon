# Research: Container runtime startup after reboot

**Date**: 2026-08-30
**Question**: How should Lemon ensure Apple container services start automatically and robustly when the container apiserver is not running after reboot?
**Status**: Implemented

## Context

Lemon installs per-user LaunchAgents for workloads. Each agent runs Lemon's hidden
`run-service` command, which directly replaces itself with `vfkit` or `container`.
Apple's container apiserver must be registered again after reboot by running
`container system start`; its generated plist is under application data rather
than `~/Library/LaunchAgents`, so launchd does not discover it automatically.

## Findings

### The reported failure is a missing prerequisite, not just a race

- `src/runtime.rs::exec_service` executes `container run` without checking or
  starting the container system.
- Both Lemon-generated and Home Manager-generated LaunchAgents use `RunAtLoad`.
  Restart-enabled services use `KeepAlive` with a five-second throttle.
- Lemon's README currently says users only need to initialize the runtime once.
  That is insufficient after a reboot: Apple container's apiserver must be
  bootstrapped again after login.
- Apple container issue #1321 independently documents this exact failure:
  container LaunchAgents run after reboot, receive an invalid XPC connection,
  and recover once `container system start` is run.

`KeepAlive` retries the workload, but it cannot make progress while the runtime
prerequisite remains down. Services with restart disabled get only one attempt.

### Concurrent `container system start` calls should be avoided

Apple container's current implementation always rewrites its apiserver plist
and calls `launchctl bootstrap`. It does not lock concurrent starts and ignores
the bootstrap command's non-zero status before checking API health. Launchd's
fixed label usually causes concurrent callers to converge on one apiserver, but
this is not a safe synchronization contract. Lemon should serialize startup.

### Runtime readiness has an authoritative probe

`container system status` sends an API health check and fails if the apiserver
is unavailable. `container system start --timeout N` also waits for API health.
A robust flow should check status, serialize repair, start only when needed, and
verify status again before launching the workload.

## Options Considered

| Option | Pros | Cons | Effort |
| --- | --- | --- | --- |
| A. Ensure the runtime in `run-service` | Covers CLI and Home Manager services, reboot, manual starts, and later runtime failure; naturally gates each workload on readiness; keeps launchd process/exit semantics after `exec` | Lemon takes responsibility for an external shared prerequisite; must serialize starts and choose non-interactive startup flags | Medium |
| B. Add one runtime-bootstrap LaunchAgent and make workloads wait for readiness | Clear separation between runtime and workload; launchd serializes and retries one shared bootstrap job; one normal startup invocation per login | launchd has no reliable readiness dependency between arbitrary jobs, so Lemon still needs a wait gate; imperative install/delete lifecycle for the shared agent adds complexity | Medium-high |
| C. Home Manager activation/login workaround | Small Nix-only change; can run `container system start` at login | Does not fix imperative Lemon services; activation is not reboot/login; a separate agent still races workload agents unless they wait | Low, incomplete |
| D. Preflight only in `lemon service start` | Improves errors and manual startup | Login LaunchAgents bypass this command, so it does not fix the reported reboot failure | Low, incomplete |
| E. Rely on `KeepAlive`, delays, or launchd ordering hints | Very small change | Cannot restore a runtime that is never started; fixed sleeps are timing-dependent; `OtherJobEnabled` is not a readiness dependency | Low, incorrect alone |
| F. Wait for Apple container to add native auto-start | Best long-term ownership | Upstream auto-start remains an open request; no immediate fix and Lemon still needs compatibility with current releases | Unknown |

## Recommendation

Use option B because launchd ownership is an explicit design goal. Lemon now
installs a shared `dev.lemon._container-system` job whose one-shot program runs
`container system start`. `RunAtLoad`, a five-second `ThrottleInterval`, and
`KeepAlive.SuccessfulExit = false` make launchd retry failed bootstraps without
looping after success.

Each workload polls `container system status` before `exec`. If the system is
unhealthy, it asks launchd to run the loaded bootstrap job with `launchctl
kickstart` (without `-k`) and waits for health. The shared job gives launchd the
serialization role instead of requiring a Lemon file lock. Home Manager creates
the same shared agent for declarative services.

Do not use `OtherJobEnabled` or a fixed sleep as the dependency. Enabled state
does not mean the one-shot bootstrap has completed or that its apiserver is
healthy. This option is more infrastructure than option A, but it is the most
robust launchd-centred design.

The integration test uses a fake runtime with real LaunchAgents. It verifies a
failed bootstrap retry, readiness gating for two workloads, serialized system
startup, recovery through `kickstart`, workload restart, and shared-agent
cleanup.

## Open Questions

- Decide whether explicit `container system stop` means “remain stopped.” The
  recommendation treats it as recoverable whenever an enabled Lemon container
  service needs the runtime, analogous to a service dependency.

## References

- `src/runtime.rs`, `exec_service`
- `src/launchd.rs`, `job_dictionary`
- `nix/home-manager.nix`, generated LaunchAgents
- Apple container command reference: <https://github.com/apple/container/blob/main/docs/command-reference.md#container-system-start>
- Apple container technical overview: <https://github.com/apple/container/blob/main/docs/technical-overview.md>
- Apple container reboot startup report: <https://github.com/apple/container/issues/1321>
- Apple container auto-start request: <https://github.com/apple/container/issues/158>
