# Lemon Development Guide

## Commands
- **Build**: `zig build`
- **Run**: `zig build run -- [args]`
- **Test all**: `zig build test`
- **Lint**: `zig build lint`
- **Code sign**: `codesign -f --entitlements lemon.entitlements -s - zig-out/bin/lemon`
- **Dev shell**: `nix develop`

## Project Structure
- `src/main.zig` - CLI entry point, VM lifecycle
- `src/cli.zig` - Argument parsing with custom ParseError enum
- `src/config.zig` - VM configuration persistence (~/.config/lemon/config.json)
- `src/disk.zig` - Raw disk image creation
- `src/signal.zig` - SIGINT/SIGTERM handling
- `src/vz/` - Zig bindings for macOS Virtualization.framework via zig-objc

## Pre-commit
- Run `zig build lint` before all commits to catch issues early

## Code Style
- Wrap ObjC classes in Zig structs with `obj: objc.Object` field, use `msgSend` for method calls
- Use `?T` for nullable returns, return `null` on failure (not errors) for ObjC wrappers
- Define domain-specific error enums (e.g., `ParseError`, `DiskError`, `ConfigError`)
- Use `[:0]const u8` for null-terminated strings (ObjC interop)
- Prefer `defer` for cleanup (deinit, release, allocator.free)
- Tests go in the same file using `test "name" { }` blocks
