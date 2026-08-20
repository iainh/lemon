# Lemon

Lemon runs Linux virtual machines and OCI containers as per-user `launchd`
services on macOS. It provides one declarative CLI over modern native runtimes:

- [vfkit](https://github.com/crc-org/vfkit), backed by Apple's
  Virtualization.framework, for full Linux VMs.
- [Apple container](https://github.com/apple/container), backed by Apple's
  Containerization and Virtualization frameworks, for OCI containers.
- `launchd` LaunchAgents for startup, supervision, restart, and logs.

Lemon does not run a privileged daemon. Configuration and logs stay in the
current user's standard macOS Library directories.

## Requirements

- macOS on Apple silicon.
- Rust 1.85 or newer to build Lemon.
- `vfkit` 0.6.1 or newer for full VMs: `brew install vfkit`.
- Apple `container` and macOS 26 for containers. Install a signed release, then
  initialize it once with `container system start`.

Run `lemon doctor` to check the local tools.

## Install

```sh
cargo install --path .
```

Keep the installed `lemon` binary at the same path after starting services;
LaunchAgents refer to its absolute path.

### Nix

The flake supports Apple silicon macOS and includes Lemon, Rust, vfkit, Apple
container, OpenSSH, and the integration-test tools:

```sh
nix develop
cargo test

nix build
nix run . -- doctor
```

Initialize the Apple container runtime once with `container system start` before
using container services.

## Quick start

Pull and run an OCI container at login:

```sh
lemon container pull docker.io/library/nginx:latest
lemon service create container web docker.io/library/nginx:latest \
  --publish 8080:80 --memory 1G
lemon service start web
lemon service status web
lemon service logs web
```

Pass an image command after `--`:

```sh
lemon service create container worker alpine:latest \
  --env QUEUE=default -- sh -c 'while true; do echo working; sleep 30; done'
```

Define a Linux VM using direct kernel boot:

```sh
lemon vm create dev \
  --kernel ./Image \
  --initrd ./initramfs.img \
  --disk ./rootfs.raw \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --cmdline 'console=hvc0 root=/dev/vda rw' \
  --cpus 4 --memory 4096

lemon vm run dev
lemon service create vm dev-service --vm dev
lemon service start dev-service
lemon vm wait dev
lemon vm ssh dev
```

Omit `--kernel` to use EFI boot. The first disk must contain a bootable EFI
system; Lemon creates and persists the EFI variable store automatically.
Supplying `--ssh-key` creates a `lemon` guest account through cloud-init; the
guest image must include cloud-init. Use `--user` to choose another account.
`lemon vm ssh` discovers the VM's NAT address from the macOS DHCP leases and
waits for SSH to become ready. It uses your SSH agent and normal key discovery,
or accepts a private key with `-i`.

Run a configuration command without opening an interactive shell:

```sh
lemon vm ssh dev -- sudo dnf install -y git
```

## Commands

```text
lemon vm create|clone|list|run|wait|ssh|delete
lemon container pull
lemon service create|list|start|stop|status|delete|logs
lemon capacity
lemon doctor
```

Use `lemon <command> --help` for all flags. VM deletion preserves disk images
and VM data by default; pass `lemon vm delete --purge` to remove cloned disks
and other Lemon-managed data. Service deletion unloads and removes only Lemon's
LaunchAgent and definition.

## How supervision works

`lemon service start` atomically writes
`~/Library/LaunchAgents/dev.lemon.<name>.plist` and loads it into the current
GUI domain. Starting a loaded service replaces the job so configuration changes
take effect. launchd starts Lemon's hidden
`run-service` command, which replaces itself with `vfkit` or `container` using
`exec(2)`. Signals and exit status therefore reach the real runtime directly.
Stopping a VM service lets vfkit request a graceful guest shutdown before it
falls back to a forced stop. Status output includes the process ID, run count,
last exit code reported by launchd, and guest SSH readiness. Pass
`--wait 120` to `lemon service start` to wait for VM readiness.

Configuration is stored under `~/Library/Application Support/dev.lemon.lemon`
and service logs are under Lemon's standard macOS data directory.

Lemon serializes VM starts and prevents loaded VM services from reserving more
than the host CPU count or 80% of physical memory. Set `LEMON_MAX_CPUS` or
`LEMON_MAX_MEMORY_MIB` to use lower deployment-specific limits. Run
`lemon capacity` to show current allocations.

## Status

This initial release supports per-user services, Linux direct-kernel or EFI
VMs, NAT networking, raw VM disks, OCI image pulls, and common container
resource/environment/port/volume options. It intentionally delegates runtime
and image storage to Apple-native tools rather than maintaining a second VM or
OCI implementation.

## Testing

Run the fast unit test suite with:

```sh
cargo test
```

An ignored end-to-end test discovers the current Fedora Server aarch64 raw
image advertised at [fedoraproject.org/server/download](https://fedoraproject.org/server/download/),
downloads and verifies it, provisions an SSH key with cloud-init, boots an EFI
VM as a real LaunchAgent, logs in over SSH, and tears everything down:

```sh
cargo test --test fedora_vm -- --ignored --nocapture
```

The integration test requires an Apple silicon Mac, `vfkit`, internet access,
about 1.5 GB of download bandwidth, several gigabytes of temporary disk space,
and a few minutes to run. All image, VM, and HOME data is kept in a temporary
directory and removed at the end.
