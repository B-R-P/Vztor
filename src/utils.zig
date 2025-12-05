const std = @import("std");
const builtin = @import("builtin");

inline fn rotl64(x: u64, r: u32) u64 {
    return std.math.rotl(u64, x, r);
}

inline fn readLE64(src: []const u8, i: usize) u64 {
    const p: *const [8]u8 = @ptrCast(src.ptr + i);
    return std.mem.readInt(u64, p, .little);
}

inline fn readLE32(src: []const u8, i: usize) u32 {
    const p: *const [4]u8 = @ptrCast(src.ptr + i);
    return std.mem.readInt(u32, p, .little);
}

inline fn finalMix64(n: u64) u64 {
    var v = n;
    v ^= v >> 33;
    v = v *% 0xFF51AFD7ED558CCD; // prime-like
    v ^= v >> 33;
    v = v *% 0xC4CEB9FE1A85EC53;
    v ^= v >> 33;
    return v;
}

pub fn stringToId32(data: []const u8, seed64: u64) i32 {
    // XXH64-like primes (well-tested)
    const PRIME1: u64 = 0x9E3779B185EBCA87;
    const PRIME2: u64 = 0xC2B2AE3D27D4EB4F;
    const PRIME3: u64 = 0x165667B19E3779F9;
    const PRIME4: u64 = 0x85EBCA77C2B2AE63;
    const PRIME5: u64 = 0x27D4EB2F165667C5;

    var h64: u64 = 0;
    var i: usize = 0;
    const len: usize = data.len;

    // initialize accumulator
    h64 = seed64 +% PRIME5 +% @as(u64, len);
    
    // process 8-byte blocks
    while (i + 8 <= len) : (i += 8) {
        var k = readLE64(data, i);
        k = k *% PRIME2;
        k = rotl64(k, 31) *% PRIME1;
        h64 ^= k;
        h64 = rotl64(h64, 27) *% PRIME1 +% PRIME4;
    }

    // remaining 4-byte chunk
    if (i + 4 <= len) {
        var k32 = @as(u64, readLE32(data, i));
        i += 4;
        k32 = k32 *% PRIME1;
        k32 = rotl64(k32, 23) *% PRIME2;
        h64 ^= k32;
        h64 = h64 *% PRIME1 +% PRIME3;
    }

    // remaining tail bytes (0..3)
    while (i < len) : (i += 1) {
        var kb = @as(u64, data[i]);
        kb = kb *% PRIME5;
        kb = rotl64(kb, 11) *% PRIME1;
        h64 ^= kb;
        h64 = h64 *% PRIME1;
    }

    // final avalanche / mix
    h64 = finalMix64(h64);

    // fold 64-bit hash down to 31-bit uniformly:
    // multiply-shift folding: (h64 * M) >> (64 - 31)
    // choose M = golden ratio 64-bit constant to mix bits.
    const GOLD64: u64 = 0x9E3779B97F4A7C15; // splitmix constant
    const folded: u64 = (h64 *% GOLD64) >> (64 - 31);

    const out_u32: u32 = @intCast(folded); // 31 bits fit in u32
    return @as(i32, @bitCast(out_u32));
}


fn writeByte(out: *[36]u8, o_ptr: *usize, b: u8) void {
    const hex = "0123456789abcdef";
    const idx = o_ptr.*;
    out[idx]     = hex[(b >> 4) & 0xF];
    out[idx + 1] = hex[b & 0xF];
    o_ptr.* += 2;
}

// uuidV4 but deterministic using a seed for PRNG.
pub fn uuidV4(allocator: std.mem.Allocator,seed: u64) ![]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var bytes: [16]u8 = undefined;
    rand.bytes(&bytes);

    // RFC 4122 bits
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant

    var out_arr: [36]u8 = undefined;
    var o: usize = 0;

    // 8-4-4-4-12 layout
    writeByte(&out_arr, &o, bytes[0]);
    writeByte(&out_arr, &o, bytes[1]);
    writeByte(&out_arr, &o, bytes[2]);
    writeByte(&out_arr, &o, bytes[3]);
    out_arr[o] = '-'; o += 1;

    writeByte(&out_arr, &o, bytes[4]);
    writeByte(&out_arr, &o, bytes[5]);
    out_arr[o] = '-'; o += 1;

    writeByte(&out_arr, &o, bytes[6]);
    writeByte(&out_arr, &o, bytes[7]);
    out_arr[o] = '-'; o += 1;

    writeByte(&out_arr, &o, bytes[8]);
    writeByte(&out_arr, &o, bytes[9]);
    out_arr[o] = '-'; o += 1;

    writeByte(&out_arr, &o, bytes[10]);
    writeByte(&out_arr, &o, bytes[11]);
    writeByte(&out_arr, &o, bytes[12]);
    writeByte(&out_arr, &o, bytes[13]);
    writeByte(&out_arr, &o, bytes[14]);
    writeByte(&out_arr, &o, bytes[15]);

    var buf = try allocator.alloc(u8, 36);
    @memcpy(buf[0..], out_arr[0..]);

    return buf;
}

pub fn toCString(allocator: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    // Allocate length + 1
    var buf_ptr = try allocator.alloc(u8, s.len + 1);
    // Copy the slice’s bytes
    std.mem.copyBackwards(u8, buf_ptr[0..s.len], s);
    // Append null terminator
    buf_ptr[s.len] = 0;
    // Cast to pointer-to-sentinel type
    return @ptrCast(buf_ptr);
}


pub fn key_pos_gen(
    allocator: std.mem.Allocator,
    key: []const u8,
    pos: usize,
) ![]u8 {
    // 1) Format pos into a small stack buffer.
    var num_buf: [32]u8 = undefined;
    const num_slice = try std.fmt.bufPrint(&num_buf, "{d}", .{ pos });

    // 2) Compute exact total length: "<pos>:<key>"
    const total_len = num_slice.len + 1 + key.len;

    // 3) Allocate output buffer from the provided allocator.
    var out = try allocator.alloc(u8, total_len);

    // 4) Copy "<pos>"
    @memmove(out[0..num_slice.len], num_slice);

    // 5) Add ':'
    out[num_slice.len] = ':';

    // 6) Copy "<key>"
    @memmove(out[num_slice.len + 1 ..], key);

    return out;
}

pub fn key_pos_parse(input: []const u8) !struct {
    pos: usize,
    key: []const u8,
} {
    // find delimiter ':' (could be any byte you choose)
    const idx = std.mem.indexOf(u8, input, ":") orelse return error.InvalidKeyPosFormat;

    // parse integer from the prefix slice. parseInt expects a concrete integer type.
    // Parse into u64 then cast to usize for portability.
    const num_slice = input[0..idx];
    const parsed_u64 = try std.fmt.parseInt(u64, num_slice, 10);
    const pos_val: usize = @intCast(parsed_u64);

    // remainder is the key (slice into input — ensure caller keeps `input` alive)
    const key_slice = input[idx + 1 ..];

    return .{ .pos = pos_val, .key = key_slice };
}

pub fn fileExists(path: []const u8) bool {
    const cwd = std.fs.cwd();
    // statFile returns an error union; catch FileNotFound and return false
    _ = cwd.statFile(path) catch |err|{
        if(err==error.FileNotFound){
            return false;
        }
    };
    return true;
}