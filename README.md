# Lemon

Lemon is a command-line application for running Linux virtual machines (VMs)
and OCI containers as per-user `launchd` services on macOS. It provides one
declarative interface over modern native runtimes:

- [vfkit](https://github.com/crc-org/vfkit), backed by Apple's
  Virtualization.framework, for full Linux VMs.
- [Apple container](https://github.com/apple/container), backed by Apple's
  Containerization and Virtualization frameworks, for OCI containers.
- `launchd` LaunchAgents for startup, supervision, restart, and logs.

Lemon handles service definitions, startup, supervision, restart, resource
limits, and log rotation. It does not run a privileged daemon. Configuration
and logs remain in the current user's standard macOS Library directories.

## Requirements

- macOS on Apple silicon.
- Rust 1.85 or newer to build Lemon.
- `vfkit` 0.6.1 or newer for full VMs: `brew install vfkit`.
- Apple `container` and macOS 26 for containers. Install a signed release, then
  initialize it once with `container system start`.

Run `lemon doctor` to check the local tools and every VM's runtime files.

## Install

```sh
cargo install --path .
lemon doctor
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

## Usage

The usual workflow is:

1. Prepare a workload by pulling a container image or defining a VM.
2. Create a named service for the workload.
3. Start the service. Lemon installs a LaunchAgent and `launchd` supervises it.
4. Use `status`, `logs`, `stop`, and `delete` to manage its lifecycle.

Use `lemon --help` to list command groups and
`lemon <command> <subcommand> --help` to see all options.

### Run a web container

Pull and run an OCI container at login:

```sh
lemon container pull docker.io/library/nginx:latest
lemon service create container web docker.io/library/nginx:latest \
  --publish 8080:80 --memory 1G
lemon service start web
lemon service status web
lemon service logs web
```

Open [http://localhost:8080](http://localhost:8080) to reach nginx. To follow
its standard output directly, use the path reported by `service logs`:

```sh
tail -f "$HOME/Library/Application Support/dev.lemon.lemon/logs/web.log"
```

Stop the service without deleting its definition, then start it again later:

```sh
lemon service stop web
lemon service start web
```

Remove the service and its current and rotated logs:

```sh
lemon service delete web --purge-logs
```

### Run a container with environment variables and a volume

The following service mounts a local directory, passes an environment variable,
and overrides the image's default command. Arguments after `--` are sent to the
container image:

```sh
mkdir -p "$HOME/lemon-data"
lemon container pull alpine:latest

lemon service create container worker alpine:latest \
  --env QUEUE=default \
  --volume "$HOME/lemon-data:/data" \
  -- sh -c 'while true; do date | tee -a /data/worker.log; sleep 30; done'

lemon service start worker
tail -f "$HOME/lemon-data/worker.log"
```

Services restart when their workload exits unless you pass `--no-restart` to
`service create`.

### Define and run a Linux VM

Lemon supports direct kernel boot and EFI boot. This direct kernel example
expects an uncompressed Linux kernel, an initramfs, and a raw root disk image:

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

Run a command without opening an interactive shell:

```sh
lemon vm ssh dev -- sudo dnf install -y git
```

Omit `--kernel` to use EFI boot. The first disk must contain a bootable EFI
system; Lemon creates and persists the EFI variable store automatically.
Supplying `--ssh-key` creates a `lemon` guest account through cloud-init; the
guest image must include cloud-init. Use `--user` to choose another account.
`lemon vm ssh` discovers the VM's NAT address from the macOS DHCP leases and
waits for the SSH protocol and selected authentication to become ready. It uses
your SSH agent and normal key discovery, or accepts a private key with `-i`.

VMs can also run in the foreground with an interactive serial console. Stop any
service using the VM first because Lemon prevents the same writable disks from
running twice:

```sh
lemon service stop dev-service
lemon vm run dev
```

### Clone a VM

Clone a stopped VM before making experimental changes. Lemon uses copy-on-write
cloning when the file system supports it and assigns the clone a new MAC
address:

```sh
lemon service stop dev-service
lemon vm clone dev dev-experiment
lemon vm list
lemon vm run dev-experiment
```

### Use JSON output for automation

Service listings, service status, and capacity information have machine-readable
JSON output for scripts and monitoring tools:

```sh
lemon service list --json
lemon service status worker --json
lemon capacity --json
```

## Command reference

| Command | Purpose |
| --- | --- |
| `lemon doctor` | Check native runtime dependencies and configured VM files. |
| `lemon capacity` | Show VM CPU and memory limits and current allocations. |
| `lemon container pull` | Pull an OCI image into Apple's container image store. |
| `lemon vm create` | Define a direct-kernel or EFI VM. |
| `lemon vm clone` | Clone a stopped VM and its disks. |
| `lemon vm list` | List VM definitions. |
| `lemon vm run` | Run a VM in the foreground with a serial console. |
| `lemon vm wait` | Wait for a VM to obtain a DHCP lease and accept SSH. |
| `lemon vm ssh` | Open an SSH session or run a command in a VM. |
| `lemon vm delete` | Delete a VM definition. |
| `lemon service create` | Define a VM or container service. |
| `lemon service list` | List services and their `launchd` state. |
| `lemon service start` | Install and start a service, or restart a loaded service. |
| `lemon service stop` | Stop and unload a service. |
| `lemon service status` | Show process, restart, exit, and guest readiness details. |
| `lemon service logs` | Print a service's stdout, stderr, and guest log paths. |
| `lemon service delete` | Remove a service definition and LaunchAgent. |
| `lemon service reconcile` | Refresh installed agents and remove orphaned agents. |

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

You can override Lemon's defaults with these environment variables:

| Variable | Purpose |
| --- | --- |
| `LEMON_CONFIG_DIR` | Configuration directory; set with `LEMON_DATA_DIR`. |
| `LEMON_DATA_DIR` | VM state and log directory; set with `LEMON_CONFIG_DIR`. |
| `LEMON_MAX_CPUS` | Lower the host CPU allocation limit. |
| `LEMON_MAX_MEMORY_MIB` | Lower the host memory allocation limit in MiB. |
| `LEMON_LOG_MAX_BYTES` | Change the per-log rotation threshold in bytes. |

Lemon serializes VM starts and prevents installed VM services from reserving
more than the host CPU count or 80% of physical memory. Installed services
remain reserved while temporarily stopped because they start again at login.
Set `LEMON_MAX_CPUS` or `LEMON_MAX_MEMORY_MIB` to use lower deployment-specific
limits. Run
`lemon capacity` to show current allocations. `lemon service list`,
`lemon service status`, and `lemon capacity` accept `--json` for monitoring and
automation.

`lemon service reconcile` atomically refreshes persisted LaunchAgents from
service definitions and unloads/removes Lemon LaunchAgents whose definitions no
longer exist. It does not start, stop, or restart configured services.

Before starting or restarting a service, Lemon rotates logs of 10 MiB or larger
and retains three generations. Set `LEMON_LOG_MAX_BYTES` to change the size
threshold. `lemon service delete --purge-logs` removes current and rotated logs.

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

An ignored end-to-end test discovers the current Fedora Cloud Base aarch64 raw
image advertised at [fedoraproject.org/cloud/download](https://fedoraproject.org/cloud/download/),
downloads and verifies it, provisions an SSH key with cloud-init, boots an EFI
VM as a real LaunchAgent, logs in over SSH, and tears everything down:

```sh
cargo test --test fedora_vm -- --ignored --nocapture
```

The integration test requires an Apple silicon Mac, `vfkit`, internet access,
about 1.5 GB of download bandwidth, several gigabytes of temporary disk space,
and a few minutes to run. All image, VM, and HOME data is kept in a temporary
directory and removed at the end.
