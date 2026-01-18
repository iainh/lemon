# Running Linux with Lemon

This guide walks you through running a Linux virtual machine using Lemon on Apple Silicon Macs.

## Prerequisites

- macOS 12.0+ (Monterey or later)
- Apple Silicon Mac (M1, M2, M3, M4, etc.)
- Lemon built and code-signed (see main README)

## Quick Start with PuiPui Linux

[PuiPui Linux](https://github.com/Code-Hex/puipui-linux) is a minimal Linux distribution specifically designed for Apple's Virtualization.framework. It's the easiest way to test Lemon.

### 1. Create a directory for VM files

```bash
mkdir -p ~/lemon-vms/puipui
cd ~/lemon-vms/puipui
```

### 2. Download PuiPui Linux

```bash
curl -L -o puipui.tar.gz "https://github.com/Code-Hex/puipui-linux/releases/download/v1.0.3/puipui_linux_v1.0.3_aarch64.tar.gz"
tar xzf puipui.tar.gz
gunzip -k Image.gz
```

This provides:
- `Image` - Uncompressed ARM64 Linux kernel
- `initramfs.cpio.gz` - Initial RAM filesystem

### 3. Run the VM

```bash
lemon run --kernel Image --initrd initramfs.cpio.gz --memory 512 --cpus 2
```

You should see Linux boot messages, and then a login prompt:

```
Login with root and no password.

localhost login:
```

Type `root` and press Enter to log in. Press `Ctrl+C` to stop the VM.

## Running Alpine Linux

Alpine Linux is lightweight and works well with Virtualization.framework, but requires extracting the uncompressed kernel.

### 1. Download Alpine netboot files

```bash
mkdir -p ~/lemon-vms/alpine
cd ~/lemon-vms/alpine

# Download kernel and initramfs
curl -L -o vmlinuz-virt "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot-3.21.5/vmlinuz-virt"
curl -L -o initramfs-virt "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot-3.21.5/initramfs-virt"
```

### 2. Extract the uncompressed kernel

The Alpine kernel is gzip-compressed inside a PE wrapper. Apple's Virtualization.framework requires an uncompressed ARM64 Image:

```bash
# Find and extract the gzip payload (offset at 0xcbb8 for Alpine 3.21)
dd if=vmlinuz-virt bs=1 skip=$((0xcbb8)) of=vmlinux.gz 2>/dev/null
gunzip vmlinux.gz
mv vmlinux Image
```

Verify the kernel format:
```bash
file Image
# Should show: Linux kernel ARM64 boot executable Image, little-endian, 4K pages
```

### 3. Run Alpine Linux

```bash
lemon run --kernel Image --initrd initramfs-virt --memory 1024 --cpus 2
```

## Using a Persistent Disk Image

> **Note:** Disk attachment is currently experiencing stability issues on macOS 15. This feature is under active development.

For a persistent installation, create a disk image:

### 1. Create a disk image

```bash
lemon create-disk disk.img 8192  # 8GB disk
```

### 2. Run with the disk attached

```bash
lemon run --kernel Image --initrd initramfs-virt --disk disk.img --memory 2048 --cpus 4
```

### 3. Inside the VM, set up the disk

Once booted into Alpine:

```bash
# Partition the disk
fdisk /dev/vda
# Create a single Linux partition (type 'n', then defaults, then 'w')

# Format
mkfs.ext4 /dev/vda1

# Mount
mount /dev/vda1 /mnt
```

## Sharing Host Directories

Lemon supports sharing directories from the host to the guest using virtio-fs:

```bash
lemon run --kernel Image --initrd initramfs-virt \
    --share /Users/me/projects:projects \
    --memory 1024 --cpus 2
```

Inside the VM, mount the shared directory:

```bash
mkdir /mnt/projects
mount -t virtiofs projects /mnt/projects
```

## Using Virtio Socket (vsock)

Virtio socket provides fast, low-overhead communication between host and guest without network configuration:

```bash
lemon run --kernel Image --initrd initramfs-virt --vsock --memory 1024 --cpus 2
```

The guest is assigned CID 3 (host is CID 2). Inside the VM, you can use vsock for:

- Port forwarding
- File transfer
- Guest agent communication

Example: Listen on port 9999 in the guest:
```bash
# In guest (requires socat with vsock support)
socat VSOCK-LISTEN:9999,fork -
```

## Enabling Rosetta (x86_64 Emulation)

On Apple Silicon, you can run x86_64 Linux binaries using Rosetta:

```bash
lemon run --kernel Image --initrd initramfs-virt --rosetta --memory 2048 --cpus 4
```

Inside the VM, set up Rosetta:

```bash
# Mount the Rosetta share
mkdir /mnt/rosetta
mount -t virtiofs rosetta /mnt/rosetta

# Register Rosetta with binfmt_misc
echo ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:F' > /proc/sys/fs/binfmt_misc/register
```

Now you can run x86_64 Linux binaries.

## Using Configuration Files

Instead of passing arguments every time, define VMs in `~/.config/lemon/vms.json`:

```json
{
    "vms": [
        {
            "name": "puipui",
            "kernel": "/Users/me/lemon-vms/puipui/Image",
            "initrd": "/Users/me/lemon-vms/puipui/initramfs.cpio.gz",
            "cpus": 2,
            "memory_mb": 512,
            "cmdline": "console=hvc0"
        },
        {
            "name": "alpine",
            "kernel": "/Users/me/lemon-vms/alpine/Image",
            "initrd": "/Users/me/lemon-vms/alpine/initramfs-virt",
            "disk": "/Users/me/lemon-vms/alpine/disk.img",
            "cpus": 4,
            "memory_mb": 2048,
            "cmdline": "console=hvc0",
            "rosetta": true
        }
    ]
}
```

Then run by name:

```bash
lemon run puipui
lemon run alpine
```

List configured VMs:

```bash
lemon list
```

## Troubleshooting

### "Internal Virtualization error. The virtual machine failed to start."

This usually means the kernel format is incompatible. Ensure you're using an **uncompressed** ARM64 Linux kernel Image. Check with:

```bash
file your-kernel
# Must show: Linux kernel ARM64 boot executable Image
```

If your kernel shows as "gzip compressed" or "PE32+ executable", you need to extract the uncompressed Image first.

### VM boots but hangs

Try adding more verbose kernel options:

```bash
lemon run --kernel Image --initrd initramfs --cmdline "console=hvc0 earlyprintk=vt0"
```

### No network in the VM

Lemon configures NAT networking automatically. In the guest, ensure you have a DHCP client running:

```bash
udhcpc -i eth0
# or
dhclient eth0
```

## Kernel Requirements

Apple's Virtualization.framework requires:

1. **Uncompressed ARM64 Image format** - Not vmlinuz (gzip/PE wrapped)
2. **Console support** - `CONFIG_VIRTIO_CONSOLE=y`
3. **Virtio drivers** - Block, network, entropy, filesystem support
4. **No incompatible kernel features** - Some distributions have kernel configs that don't work with VZ

Known working kernels:
- [PuiPui Linux](https://github.com/Code-Hex/puipui-linux) - Specifically designed for VZ
- Extracted Image from Alpine, Fedora, or Ubuntu ARM64 netboot
