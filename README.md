# 🍋 Lemon

A command-line frontend for macOS Virtualization.framework, written in Zig.

## Requirements

- macOS 12.0+ (Monterey or later)
- Nix with flakes enabled

## Development

Enter the development environment:

```bash
nix develop
```

Build:

```bash
zig build
```

Run:

```bash
zig build run
```

Test:

```bash
zig build test
```

## Running Linux

See [docs/running-linux.md](docs/running-linux.md) for a complete guide to downloading and running Linux VMs with Lemon.

Quick start with PuiPui Linux:

```bash
# Download PuiPui Linux (designed for Virtualization.framework)
mkdir -p ~/lemon-vms/puipui && cd ~/lemon-vms/puipui
curl -L -o puipui.tar.gz "https://github.com/Code-Hex/puipui-linux/releases/download/v1.0.3/puipui_linux_v1.0.3_aarch64.tar.gz"
tar xzf puipui.tar.gz && gunzip -k Image.gz

# Run the VM
lemon run --kernel Image --initrd initramfs.cpio.gz --memory 512 --cpus 2
```

## License

MIT
