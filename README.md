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
- `vfkit` for full VMs: `brew install vfkit`.
- Apple `container` and macOS 26 for containers. Install a signed release, then
  initialize it once with `container system start`.

Run `lemon doctor` to check the local tools.

## Install

```sh
cargo install --path .
```

Keep the installed `lemon` binary at the same path after starting services;
LaunchAgents refer to its absolute path.

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
  --cmdline 'console=hvc0 root=/dev/vda rw' \
  --cpus 4 --memory 4096

lemon vm run dev
lemon service create vm dev-service --vm dev
lemon service start dev-service
```

Omit `--kernel` to use EFI boot. The first disk must contain a bootable EFI
system; Lemon creates and persists the EFI variable store automatically.

## Commands

```text
lemon vm create|list|run|delete
lemon container pull
lemon service create|list|start|stop|status|delete|logs
lemon doctor
```

Use `lemon <command> --help` for all flags. VM deletion preserves disk images.
Service deletion unloads and removes only Lemon's LaunchAgent and definition.

## How supervision works

`lemon service start` writes `~/Library/LaunchAgents/dev.lemon.<name>.plist` and
loads it into the current GUI domain. launchd starts Lemon's hidden
`run-service` command, which replaces itself with `vfkit` or `container` using
`exec(2)`. Signals and exit status therefore reach the real runtime directly.

Configuration is stored under `~/Library/Application Support/dev.lemon.lemon`
and service logs are under Lemon's standard macOS data directory.

## Status

This initial release supports per-user services, Linux direct-kernel or EFI
VMs, NAT networking, raw VM disks, OCI image pulls, and common container
resource/environment/port/volume options. It intentionally delegates runtime
and image storage to Apple-native tools rather than maintaining a second VM or
OCI implementation.
