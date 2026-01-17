# Lemon Development Guide

## Commands

- **Build**: `zig build`
- **Run**: `zig build run`
- **Test**: `zig build test`
- **Enter dev shell**: `nix develop`
- **Code sign**: `codesign -f --entitlements lemon.entitlements -s - zig-out/bin/lemon`

## Project Structure

- `src/main.zig` - CLI entry point
- `src/vz/vz.zig` - Zig bindings for Virtualization.framework using zig-objc

## Dependencies

- `zig-objc` - Objective-C runtime bindings for Zig (mitchellh/zig-objc)

## Integration Notes

- Virtualization.framework requires macOS 12.0+
- Binary must be code-signed with entitlements to use virtualization
- Uses zig-objc for direct Objective-C runtime calls (inspired by Ghostty's approach)
- Pattern: wrap ObjC classes in Zig structs with `objc.Object` field, use `msgSend` for method calls
