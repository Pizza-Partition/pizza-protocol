const std = @import("std");
pub const wire = @import("generated.zig");

pub const api_version = wire.api_version;
pub const Plan = wire.Plan;
pub const Event = wire.Event;
pub const JournalPhase = wire.JournalPhase;

test "journal header size is stable" {
    try std.testing.expectEqual(@as(usize, 64), wire.journal_header_bytes);
    try std.testing.expectEqual(@as(u32, 0x505a4a31), wire.journal_magic);
}

pub fn validatePlan(plan: Plan) !void {
    if (plan.version != api_version or plan.id.len == 0 or plan.id.len > 64 or plan.steps.len > 16384) return error.InvalidPlan;
    for (plan.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidPlan;
    if (plan.request) |request| try validateRequest(request);
    for (plan.steps, 0..) |step, index| {
        if ((plan.request != null and step.simulated) or step.id == 0 or step.label.len == 0 or step.label.len > 256 or !std.unicode.utf8ValidateSlice(step.label)) return error.InvalidPlan;
        for (plan.steps[0..index]) |previous| if (step.id == previous.id) return error.InvalidPlan;
    }
}

pub fn hexDigest(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidDeviceIdentity;
    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        var value: u8 = 0;
        for (text[i * 2 ..][0..2]) |ch| {
            const digit: u8 = if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10 else return error.InvalidDeviceIdentity;
            value = value * 16 + digit;
        }
        byte.* = value;
    }
    return bytes;
}
pub fn byteCount(text: []const u8) !u64 {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidByteCount;
    for (text) |ch| if (ch < '0' or ch > '9') return error.InvalidByteCount;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidByteCount;
}
fn validateDevice(ref: wire.DeviceRef) !void {
    if (!std.fs.path.isAbsolute(ref.path) or ref.path.len > 4096 or std.mem.indexOfScalar(u8, ref.path, 0) != null) return error.InvalidDevicePath;
    _ = try hexDigest(ref.identity);
    if (ref.sector_size < 512 or ref.sector_size > 65536 or !std.math.isPowerOfTwo(ref.sector_size)) return error.InvalidSectorSize;
}
pub fn validateRequest(request: wire.OperationRequest) !void {
    try validateDevice(request.target);
    if (request.source) |source| try validateDevice(source);
    if (request.partition_id) |id| _ = try hexDigest(id);
    if (request.target_bytes) |bytes| if (try byteCount(bytes) == 0) return error.InvalidByteCount;
    if ((request.operation == .create) != (request.filesystem != null)) return error.InvalidFilesystemSelection;
    if ((request.operation == .copy) != (request.source != null)) return error.InvalidCloneRequest;
    if ((request.operation == .grow or request.operation == .shrink) != (request.target_bytes != null)) return error.InvalidResizeRequest;
    if ((request.operation == .layout) != (request.partitions.len != 0) or request.partitions.len > 4096) return error.InvalidPartitionChanges;
    if (request.operation == .layout or request.operation == .recover) if (request.partition_id != null) return error.InvalidPartitionChanges;
    for (request.partitions, 0..) |change, i| {
        _ = try hexDigest(change.partition_id);
        const offset = try byteCount(change.offset);
        const length = try byteCount(change.length);
        if (length == 0 or offset % request.target.sector_size != 0 or length % request.target.sector_size != 0) return error.InvalidPartitionChanges;
        _ = std.math.add(u64, offset, length) catch return error.InvalidPartitionChanges;
        for (request.partitions[0..i]) |previous| if (std.mem.eql(u8, previous.partition_id, change.partition_id)) return error.InvalidPartitionChanges;
    }
}

pub const javascript_binding = @embedFile("generated/contract.js");
pub const typescript_binding = @embedFile("generated/contract.d.ts");

/// These identifiers must come from the host's root-owned pending session,
/// never from the receipt being checked. Parsing does not authenticate an ESP
/// file: its device/allocation binding is verified by the platform importer.
pub const ReceiptIdentity = struct {
    id: []const u8,
    plan_digest: []const u8,
    program_digest: []const u8,
    disk_identity: []const u8,
    image_digest: []const u8,
};
pub fn parseCompletion(a: std.mem.Allocator, bytes: []const u8, expected: ReceiptIdentity) !wire.CompletionReceipt {
    if (bytes.len == 0 or bytes.len > 65536) return error.CompletionReceiptTooLarge;
    const value = try std.json.parseFromSliceLeaky(wire.CompletionReceipt, a, bytes, .{});
    if (value.version != api_version) return error.IncompatibleCompletionReceipt;
    if (value.message.len > 4096 or !std.unicode.utf8ValidateSlice(value.message) or std.mem.indexOfScalar(u8, value.message, 0) != null) return error.InvalidCompletionReceipt;
    inline for (comptime std.meta.fieldNames(ReceiptIdentity)) |field| {
        const actual = @field(value, field);
        _ = try hexDigest(actual);
        _ = try hexDigest(@field(expected, field));
        if (!std.mem.eql(u8, actual, @field(expected, field))) return error.CompletionReceiptIdentityMismatch;
    }
    return value;
}
test "completion receipts bind every identifier and reject incompatible or extra data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "1111111111111111111111111111111111111111111111111111111111111111";
    const other = "2222222222222222222222222222222222222222222222222222222222222222";
    const expected: ReceiptIdentity = .{ .id = id, .plan_digest = id, .program_digest = id, .disk_identity = id, .image_digest = id };
    var receipt: wire.CompletionReceipt = .{ .version = api_version, .id = id, .plan_digest = id, .program_digest = id, .disk_identity = id, .image_digest = id, .outcome = .completed, .message = "Verified maintenance complete" };
    const bytes = try std.json.Stringify.valueAlloc(a, receipt, .{});
    _ = try parseCompletion(a, bytes, expected);
    inline for (comptime std.meta.fieldNames(ReceiptIdentity)) |field| {
        var changed = receipt;
        @field(changed, field) = other;
        try std.testing.expectError(error.CompletionReceiptIdentityMismatch, parseCompletion(a, try std.json.Stringify.valueAlloc(a, changed, .{}), expected));
    }
    receipt.version = 3;
    try std.testing.expectError(error.IncompatibleCompletionReceipt, parseCompletion(a, try std.json.Stringify.valueAlloc(a, receipt, .{}), expected));
    const extra = try std.mem.concat(a, u8, &.{ bytes[0 .. bytes.len - 1], ",\"command\":\"arbitrary\"}" });
    try std.testing.expectError(error.UnknownField, parseCompletion(a, extra, expected));
    try std.testing.expectError(error.CompletionReceiptTooLarge, parseCompletion(a, try a.alloc(u8, 65537), expected));
}
