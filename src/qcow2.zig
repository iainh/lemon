const std = @import("std");

/// QCOW2 magic number: 'Q', 'F', 'I', 0xfb
const qcow2_magic: u32 = 0x514649fb;

/// QCOW2 header (v2/v3 compatible)
pub const Qcow2Header = struct {
    magic: u32,
    version: u32,
    backing_file_offset: u64,
    backing_file_size: u32,
    cluster_bits: u32,
    size: u64, // virtual size in bytes
    crypt_method: u32,
    l1_size: u32,
    l1_table_offset: u64,
    refcount_table_offset: u64,
    refcount_table_clusters: u32,
    nb_snapshots: u32,
    snapshots_offset: u64,

    pub fn clusterSize(self: Qcow2Header) u64 {
        return @as(u64, 1) << @intCast(self.cluster_bits);
    }

    pub fn l2Entries(self: Qcow2Header) u64 {
        // Each L2 entry is 8 bytes, L2 table is one cluster
        return self.clusterSize() / 8;
    }
};

pub const Qcow2Error = error{
    InvalidMagic,
    UnsupportedVersion,
    Encrypted,
    HasBackingFile,
    ReadError,
    WriteError,
    SeekError,
    OutOfMemory,
};

/// Read big-endian u32 from bytes
fn readBe32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

/// Read big-endian u64 from bytes
fn readBe64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

/// Parse QCOW2 header from file
pub fn readHeader(file: std.fs.File) Qcow2Error!Qcow2Header {
    var buf: [104]u8 = undefined;
    const bytes_read = file.pread(&buf, 0) catch return Qcow2Error.ReadError;
    if (bytes_read < 72) return Qcow2Error.ReadError;

    const magic = readBe32(buf[0..4]);
    if (magic != qcow2_magic) return Qcow2Error.InvalidMagic;

    const version = readBe32(buf[4..8]);
    if (version < 2 or version > 3) return Qcow2Error.UnsupportedVersion;

    const crypt_method = readBe32(buf[32..36]);
    if (crypt_method != 0) return Qcow2Error.Encrypted;

    return .{
        .magic = magic,
        .version = version,
        .backing_file_offset = readBe64(buf[8..16]),
        .backing_file_size = readBe32(buf[16..20]),
        .cluster_bits = readBe32(buf[20..24]),
        .size = readBe64(buf[24..32]),
        .crypt_method = crypt_method,
        .l1_size = readBe32(buf[36..40]),
        .l1_table_offset = readBe64(buf[40..48]),
        .refcount_table_offset = readBe64(buf[48..56]),
        .refcount_table_clusters = readBe32(buf[56..60]),
        .nb_snapshots = readBe32(buf[60..64]),
        .snapshots_offset = readBe64(buf[64..72]),
    };
}

/// L2 entry flags
const l2_compressed: u64 = 1 << 62;
const l2_offset_mask: u64 = 0x00fffffffffffe00; // bits 9-55 for standard clusters

const flate = std.compress.flate;

/// Parse compressed cluster L2 entry to get host offset and max bytes to read
fn parseCompressedL2(l2_entry: u64, cluster_bits: u32) struct { host_offset: u64, max_bytes: u64 } {
    const x: u6 = @intCast(62 - (cluster_bits - 8));
    const host_mask: u64 = (@as(u64, 1) << x) - 1;
    const host_offset = l2_entry & host_mask;

    const addl_sectors = (l2_entry >> x) & ((@as(u64, 1) << (62 - x)) - 1);
    const sector_off = host_offset & 511;
    const max_bytes = (addl_sectors + 1) * 512 - sector_off;

    return .{ .host_offset = host_offset, .max_bytes = max_bytes };
}

/// Decompress raw deflate data into output buffer
fn inflateRawDeflateInto(dst: []u8, src: []const u8) !void {
    var in_stream: std.Io.Reader = .fixed(src);
    var window: [flate.max_window_len]u8 = undefined;

    // QCOW2 uses raw deflate without zlib headers
    var dec = flate.Decompress.init(&in_stream, .raw, &window);

    // Read exactly dst.len bytes
    dec.reader.readSliceAll(dst) catch |err| {
        return err;
    };
}



/// Convert a QCOW2 image to raw format
pub fn convertToRaw(
    allocator: std.mem.Allocator,
    qcow2_path: []const u8,
    raw_path: []const u8,
    progress_callback: ?*const fn (current: u64, total: u64) void,
) !void {
    const qcow2_file = std.fs.cwd().openFile(qcow2_path, .{}) catch |err| {
        std.debug.print("Error opening qcow2 file: {}\n", .{err});
        return Qcow2Error.ReadError;
    };
    defer qcow2_file.close();

    const header = try readHeader(qcow2_file);

    if (header.backing_file_offset != 0) {
        std.debug.print("Error: Images with backing files are not supported.\n", .{});
        return Qcow2Error.HasBackingFile;
    }

    const cluster_size = header.clusterSize();
    const l2_entries = header.l2Entries();
    const virtual_size = header.size;

    std.debug.print("QCOW2 Info:\n", .{});
    std.debug.print("  Version: {}\n", .{header.version});
    std.debug.print("  Virtual size: {} bytes ({} MB)\n", .{ virtual_size, virtual_size / (1024 * 1024) });
    std.debug.print("  Cluster size: {} bytes\n", .{cluster_size});
    std.debug.print("  L1 entries: {}\n", .{header.l1_size});
    std.debug.print("  L2 entries per table: {}\n", .{l2_entries});

    // Read L1 table
    const l1_table = allocator.alloc(u64, header.l1_size) catch return Qcow2Error.OutOfMemory;
    defer allocator.free(l1_table);

    const l1_bytes = std.mem.sliceAsBytes(l1_table);
    const l1_read = qcow2_file.pread(l1_bytes, header.l1_table_offset) catch return Qcow2Error.ReadError;
    if (l1_read != l1_bytes.len) return Qcow2Error.ReadError;

    // Convert L1 entries from big-endian
    for (l1_table) |*entry| {
        entry.* = std.mem.bigToNative(u64, entry.*);
    }

    // Create output raw file
    const raw_file = std.fs.cwd().createFile(raw_path, .{}) catch |err| {
        std.debug.print("Error creating raw file: {}\n", .{err});
        return Qcow2Error.WriteError;
    };
    defer raw_file.close();

    // Pre-allocate the raw file
    raw_file.setEndPos(virtual_size) catch |err| {
        std.debug.print("Error pre-allocating raw file: {}\n", .{err});
        return Qcow2Error.WriteError;
    };

    // Allocate buffers
    const cluster_buf = allocator.alloc(u8, cluster_size) catch return Qcow2Error.OutOfMemory;
    defer allocator.free(cluster_buf);

    const l2_table = allocator.alloc(u64, l2_entries) catch return Qcow2Error.OutOfMemory;
    defer allocator.free(l2_table);

    const zero_cluster = allocator.alloc(u8, cluster_size) catch return Qcow2Error.OutOfMemory;
    defer allocator.free(zero_cluster);
    @memset(zero_cluster, 0);

    const total_clusters = (virtual_size + cluster_size - 1) / cluster_size;
    var clusters_written: u64 = 0;
    var compressed_skipped: u64 = 0;

    // Process each guest cluster
    var guest_offset: u64 = 0;
    while (guest_offset < virtual_size) : (guest_offset += cluster_size) {
        const l1_index = guest_offset / (cluster_size * l2_entries);
        const l2_index = (guest_offset / cluster_size) % l2_entries;

        if (l1_index >= header.l1_size) {
            // Beyond L1 table, write zeros
            const write_size = @min(cluster_size, virtual_size - guest_offset);
            _ = raw_file.pwrite(zero_cluster[0..write_size], guest_offset) catch return Qcow2Error.WriteError;
            clusters_written += 1;
            continue;
        }

        const l1_entry = l1_table[l1_index];
        const l2_offset = l1_entry & l2_offset_mask;

        if (l2_offset == 0) {
            // L2 table not allocated, guest cluster is zeros
            // Raw file is already zero-filled from setEndPos, so skip writing
            clusters_written += 1;
            if (progress_callback) |cb| cb(clusters_written, total_clusters);
            continue;
        }

        // Read L2 table
        const l2_bytes = std.mem.sliceAsBytes(l2_table);
        const l2_read = qcow2_file.pread(l2_bytes, l2_offset) catch return Qcow2Error.ReadError;
        if (l2_read != l2_bytes.len) return Qcow2Error.ReadError;

        // Convert L2 entry from big-endian
        const l2_entry_be = l2_table[l2_index];
        const l2_entry = std.mem.bigToNative(u64, l2_entry_be);

        if (l2_entry & l2_compressed != 0) {
            // Decompress compressed cluster
            const info = parseCompressedL2(l2_entry, header.cluster_bits);

            const comp_buf = allocator.alloc(u8, info.max_bytes) catch return Qcow2Error.OutOfMemory;
            defer allocator.free(comp_buf);

            const got = qcow2_file.pread(comp_buf, info.host_offset) catch return Qcow2Error.ReadError;
            if (got != comp_buf.len) return Qcow2Error.ReadError;

            const write_size = @min(cluster_size, virtual_size - guest_offset);
            inflateRawDeflateInto(cluster_buf[0..write_size], comp_buf) catch {
                // If decompression fails, write zeros
                @memset(cluster_buf[0..write_size], 0);
                compressed_skipped += 1;
            };

            _ = raw_file.pwrite(cluster_buf[0..write_size], guest_offset) catch return Qcow2Error.WriteError;
            clusters_written += 1;
            if (progress_callback) |cb| cb(clusters_written, total_clusters);
            continue;
        }

        const host_offset = l2_entry & l2_offset_mask;

        if (host_offset == 0) {
            // Cluster not allocated, already zero in raw file
            clusters_written += 1;
            if (progress_callback) |cb| cb(clusters_written, total_clusters);
            continue;
        }

        // Read cluster from qcow2
        const write_size = @min(cluster_size, virtual_size - guest_offset);
        const data_read = qcow2_file.pread(cluster_buf[0..write_size], host_offset) catch return Qcow2Error.ReadError;
        if (data_read != write_size) return Qcow2Error.ReadError;

        // Write to raw file
        _ = raw_file.pwrite(cluster_buf[0..write_size], guest_offset) catch return Qcow2Error.WriteError;

        clusters_written += 1;
        if (progress_callback) |cb| cb(clusters_written, total_clusters);
    }

    std.debug.print("\nConversion complete!\n", .{});
    std.debug.print("  Clusters processed: {}\n", .{clusters_written});
    if (compressed_skipped > 0) {
        std.debug.print("  Warning: {} compressed clusters written as zeros\n", .{compressed_skipped});
    }
}

test "readBe32" {
    const bytes = [_]u8{ 0x51, 0x46, 0x49, 0xfb };
    try std.testing.expectEqual(@as(u32, qcow2_magic), readBe32(&bytes));
}

test "readBe64" {
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u64, 65536), readBe64(&bytes));
}
