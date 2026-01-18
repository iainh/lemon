# 🍋 Lemon

A command-line frontend for macOS Virtualization.framework, written in Zig.

## Features

- **Linux direct boot** - Boot kernels directly without EFI
- **EFI boot** - Install and run full Linux distributions from ISO images
- **GUI mode** - Graphical display with keyboard and mouse support
- **Directory sharing** - Share host directories via virtio-fs
- **Rosetta** - Run x86_64 Linux binaries on Apple Silicon
- **Audio** - Virtio sound device support
- **Vsock** - Fast host-guest communication without networking
- **VM configuration** - Save and manage VM configurations

## Requirements

- macOS 12.0+ (Monterey or later)
- Apple Silicon Mac (M1, M2, M3, M4, etc.)
- Nix with flakes enabled (for development)

## Installation

Build and code-sign:

```bash
nix develop
zig build
codesign -f --entitlements lemon.entitlements -s - zig-out/bin/lemon
```

## Quick Start

### Running Fedora from ISO (Graphical)

```bash
# Create a disk image for installation
lemon create-disk fedora/disk.img 20480  # 20GB

# Boot the Fedora ISO installer with GUI
lemon run --iso Fedora-Server-dvd-aarch64-42-1.1.iso \
    --disk fedora/disk.img \
    --nvram fedora/fedora.nvram \
    --gui --memory 4096 --cpus 4

# After installation, boot from the installed disk
lemon run --efi --disk fedora/disk.img \
    --nvram fedora/fedora.nvram \
    --gui --memory 4096 --cpus 4
```

### Running PuiPui Linux (Direct Boot)

```bash
# Download PuiPui Linux (designed for Virtualization.framework)
mkdir -p ~/lemon-vms/puipui && cd ~/lemon-vms/puipui
curl -L -o puipui.tar.gz "https://github.com/Code-Hex/puipui-linux/releases/download/v1.0.3/puipui_linux_v1.0.3_aarch64.tar.gz"
tar xzf puipui.tar.gz && gunzip -k Image.gz

# Run the VM
lemon run --kernel Image --initrd initramfs.cpio.gz --memory 512 --cpus 2
```

## Usage

```bash
lemon run [NAME]              # Run a VM by config name or with options
lemon create <NAME>           # Create a new VM configuration
lemon delete <NAME>           # Delete a VM configuration
lemon list                    # List configured VMs
lemon inspect <NAME>          # Show VM configuration details
lemon create-disk <PATH> <MB> # Create a raw disk image
```

### Run Options

| Option | Description |
|--------|-------------|
| `--kernel`, `-k` | Path to Linux kernel (direct boot) |
| `--initrd`, `-i` | Path to initial ramdisk |
| `--disk`, `-d` | Path to disk image |
| `--iso` | Boot from ISO image (uses EFI) |
| `--efi` | Use EFI boot mode |
| `--nvram` | Path to NVRAM file (default: nvram.bin) |
| `--memory`, `-m` | Memory in MB (default: 512) |
| `--cpus` | Number of CPUs (default: 2) |
| `--gui` | Show graphical display window |
| `--share`, `-s` | Share directory (format: `/path:tag`) |
| `--rosetta` | Enable Rosetta x86_64 emulation |
| `--audio` | Enable virtio sound device |
| `--vsock` | Enable virtio socket |

## Saving VM Configurations

```bash
# Create a named VM configuration
lemon create fedora --efi --disk fedora/disk.img --nvram fedora/fedora.nvram -m 4096 --cpus 4

# Run by name
lemon run fedora --gui
```

VMs are stored in `~/.config/lemon/vms.json`.

## Documentation

See [docs/running-linux.md](docs/running-linux.md) for a complete guide including Alpine Linux setup, kernel extraction, directory sharing, Rosetta, and troubleshooting.

## Development

```bash
nix develop       # Enter development environment
zig build         # Build
zig build run     # Build and run
zig build test    # Run tests
```

## License

MIT
