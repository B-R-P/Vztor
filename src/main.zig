const std = @import("std");
const testing = std.testing;

const nmslib = @import("nmslib");
const lmdbx = @import("lmdbx");
const utils = @import("utils");



const getResult = struct {
    vector: ?nmslib.DataPoint,
    data: []const u8,
};

const searchResult = struct {
    key: []const u8,
    data: ?[]const u8,
    distance: f32
};


pub const Vztor = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    env: lmdbx.Environment,
    index: nmslib.Index,
    indexPath: []const u8,
    counter: u32,
    rnd: std.Random,
    seed: u64,

    fn initOrLoadIndex(
        allocator: std.mem.Allocator,
        comptime db_path: []const u8,
        space_type: []const u8,
        vector_type: nmslib.DataType,
        dist_type: nmslib.DistType,
        hnsw_params: *nmslib.Params,
    ) !nmslib.Index {
        // Directory where we keep index artifacts: "<db_path>/IDX"
        const idx_dir = try std.fs.path.join(allocator, &.{ db_path, "IDX" });
        defer allocator.free(idx_dir);

        // Ensure the index directory exists so later saves never hit ENOENT
        const cwd = std.fs.cwd();
        try cwd.makePath(idx_dir);

        // Actual NMSLIB index base file: "<db_path>/IDX/index"
        const idx_path = try std.fs.path.join(allocator, &.{ idx_dir, "index" });
        defer allocator.free(idx_path);

        // Marker file that indicates a saved index: "<db_path>/IDX/.nmslib_saved"
        const marker_path = try std.fs.path.join(allocator, &.{ idx_dir, ".nmslib_saved" });
        defer allocator.free(marker_path);

        const have_marker = utils.fileExists(marker_path);

        if (have_marker) {
            // Try reload; if it fails, log a warning and fall back to a fresh index.
            // Vectors are only stored inside the index; a failed reload means we lose
            // searchability for old data, but LMDB payloads are still accessible.
            return nmslib.Index.load(
                allocator,
                idx_path,
                vector_type,
                dist_type,
                true,
            ) catch |err| {
                std.debug.print(
                    "warning: failed to load index from '{s}': {any}\n → creating fresh index\n",
                    .{ idx_path, err },
                );
                return nmslib.Index.init(
                    allocator,
                    space_type,
                    hnsw_params.*,
                    "hnsw",
                    vector_type,
                    dist_type,
                );
            };
        }

        // No marker — initialize from scratch
        return nmslib.Index.init(
            allocator,
            space_type,
            hnsw_params.*,
            "hnsw",
            vector_type,
            dist_type,
        );
    }






    pub fn init(
        allocator: std.mem.Allocator,
        comptime db_path: []const u8,
        space_type: []const u8,
        vector_type: nmslib.DataType,
        dist_type: nmslib.DistType,
        max_readers: u32,
    ) !Self {
        var store: Self = undefined;

        // Arena allocator for internal allocations (keys, etc.)
        store.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer store.arena.deinit();
        const arena_allocator = store.arena.allocator();

        // Ensure the DB directory exists so LMDBX and NMSLIB can create files there
        const cwd = std.fs.cwd();
        try cwd.makePath(db_path);

        // Open / create LMDBX environment
        const db_path_z = try utils.toCString(arena_allocator, db_path);

        var env = try lmdbx.Environment.init(
            db_path_z,
            .{
                .max_dbs = 4,
                .max_readers = max_readers,
            },
        );
        errdefer env.deinit() catch {};

        // Use a *local* read-write transaction to create/open DBs and metadata
        var txn = try lmdbx.Transaction.init(env, .{ .mode = .ReadWrite });
        errdefer txn.abort() catch unreachable;

        _ = try txn.database("data", .{ .create = true });
        _ = try txn.database("index_to_key", .{ .create = true});
        
        var db_metadata = try txn.database("metadata", .{ .create = true });

        // Example metadata: random seed + counter
        var seed: u64 = undefined;
        var counter: u32 = undefined;
        var rnd: std.Random = undefined;
        if (try db_metadata.get("seed")) |strSeed| {
            const strCounter = try db_metadata.get("random_counter") orelse "0";
            counter = try std.fmt.parseInt(u32, strCounter, 10);
            seed = try std.fmt.parseInt(u64, strSeed, 10);
            var prng = std.Random.DefaultPrng.init(seed);
            rnd = prng.random();
            for (0..counter) |_| {
                _ = rnd.int(u64);
            }
        } else {
            seed = std.crypto.random.int(u64);
            var prng = std.Random.DefaultPrng.init(seed);
            rnd = prng.random();
            counter = 0;
            const strSeed = try std.fmt.allocPrint(arena_allocator, "{d}", .{ seed });
            const strCounter = try std.fmt.allocPrint(arena_allocator, "{d}", .{ counter });
            try db_metadata.set("seed", strSeed, .Create);
            try db_metadata.set("random_counter", strCounter, .Create);
        }

        // HNSW / index parameters (kept on stack; index gets a copy of what it needs)
        // IMPORTANT: use the *outer* allocator here (supports alloc/free), not the arena.
        var hnsw_params = try nmslib.Params.init(allocator);
        try hnsw_params.add("M", .{ .Int = 16 });
        try hnsw_params.add("efConstruction", .{ .Int = 200 });
        try hnsw_params.add("post", .{ .Int = 0 });

        // Initialize or load NMSLIB index based on the marker
        const index = try initOrLoadIndex(
            allocator,      // use outer allocator for nmslib
            db_path,
            space_type,
            vector_type,
            dist_type,
            &hnsw_params,
        );

        // Commit setup transaction; DB and txn handles go out of scope here
        try txn.commit();

        // Store everything into Vztor
        store.env = env;
        store.rnd = rnd;
        store.counter = counter;
        store.seed = seed;
        store.index = index;

        // Full path to the index base file: "<db_path>/IDX/index"
        store.indexPath = try std.fs.path.join(arena_allocator, &.{ db_path, "IDX", "index" });

        return store;
    }




    fn deinit(self: *Self) !void {
        // Persist random counter back into LMDB metadata
        {
            const txn = try lmdbx.Transaction.init(self.env, .{ .mode = .ReadWrite });
            errdefer txn.abort() catch unreachable;

            const db_metadata = try txn.database("metadata", .{});
            const counterStr = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{ self.counter });
            try db_metadata.set("random_counter", counterStr, .Update);

            // Commit exactly once on the success path
            try txn.commit();
        }

        // Tear down index and allocators
        self.index.deinit();
        self.arena.deinit();
        try self.env.deinit();
    }



    fn getSeed(self: *Self) u64{
        self.counter += 1;
        return self.rnd.int(u64);
    }

    fn batchPut(
        self: *Self,
        vector: []const []const nmslib.SparseElem,
        data: []const []const u8,
        keys: ?[]?[]const u8,
    ) ![][]const u8 {
        // Stable allocator for values that must survive after return
        const stable_alloc = self.arena.allocator();

        const input_length = vector.len;
        std.debug.assert(input_length == data.len);
        std.debug.assert((keys == null) or (keys.?.len == input_length));

        // Allocate array-of-keys on the stable allocator (returned to caller)
        var nnkeys = try stable_alloc.alloc([]const u8, input_length);

        // Fill nnkeys:
        // - use provided keys when given
        // - otherwise generate UUIDs using the stable allocator
        if (keys) |k| {
            for (0..input_length) |i| {
                if (k[i]) |providedKey| {
                    nnkeys[i] = providedKey;
                } else {
                    nnkeys[i] = try utils.uuidV4(stable_alloc, self.getSeed());
                }
            }
        } else {
            for (0..input_length) |i| {
                nnkeys[i] = try utils.uuidV4(stable_alloc, self.getSeed());
            }
        }

        // numKeys is used by nmslib; allocate from stable allocator
        var numKeys = try stable_alloc.alloc(i32, input_length);
        for (0..input_length) |i| {
            numKeys[i] = utils.stringToId32(nnkeys[i], self.seed);
        }

        const start_idx = self.index.dataQty();
        try self.index.addSparseBatch(vector, numKeys);

        const txn = try lmdbx.Transaction.init(self.env, .{ .mode = .ReadWrite });
        errdefer txn.abort() catch unreachable;

        // Ensure DBIs exist (create on first use)
        const db_data = try txn.database("data", .{});
        const db_index_to_key = try txn.database("index_to_key", .{});

        for (0..input_length) |i| {
            // Numeric index key -> string
            var numeric_buf: [32]u8 = undefined;
            const numericSKey = try std.fmt.bufPrint(&numeric_buf, "{d}", .{ numKeys[i] });

            // Build "pos:key" using the same stable allocator.
            // LMDB copies the value, so we don't need to free key_pos manually.
            const key_pos = try utils.key_pos_gen(stable_alloc, nnkeys[i], start_idx + i);

            try db_data.set(nnkeys[i], data[i], .Create);
            try db_index_to_key.set(numericSKey, key_pos, .Create);
        }

        try txn.commit();

        // Return keys that were allocated with stable_alloc (owned by Vztor)
        return nnkeys;
    }




    fn batchGet(self: *Self, key: []const u8) !getResult {
        // Stable allocator for returned/copied values that must outlive this call
        const stable_alloc = self.arena.allocator();

        const numericKey = utils.stringToId32(key, self.seed);

        // Use a small stack buffer for printing the numeric key (no heap alloc)
        var num_buf: [32]u8 = undefined;
        const numberSkey = try std.fmt.bufPrint(&num_buf, "{d}", .{ numericKey });

        const txn = try lmdbx.Transaction.init(self.env, .{ .mode = .ReadOnly });
        defer txn.abort() catch unreachable;

        const db_data = try txn.database("data", .{});
        const db_index_to_key = try txn.database("index_to_key", .{});

        // Lookups -- handle optional/null returns explicitly
        const data_raw = try db_data.get(key) orelse return error.KeyNotFound;
        const key_pos_raw = (try db_index_to_key.get(numberSkey)) orelse return error.KeyNotFound;

        const d = try utils.key_pos_parse(key_pos_raw);
        std.debug.assert(std.mem.eql(u8, key, d.key));

        // Try to recover the vector from the index if possible.
        // If the index was recreated after a failed load, d.pos may be out of range.
        var maybe_vector: ?nmslib.DataPoint = null;

        const qty = self.index.dataQty();
        if (d.pos < qty) {
            // getDataPoint can still fail (e.g. DataNotLoaded), so be defensive.
            maybe_vector = self.index.getDataPoint(d.pos) catch |err| switch (err) {
                error.InvalidArgument, error.DataNotLoaded => null,
                else => return err,
            };
        }

        // Copy data into stable allocator so it remains valid after txn ends
        const data_copy = try stable_alloc.dupe(u8, data_raw);

        return getResult{
            .vector = maybe_vector,
            .data = data_copy,
        };
    }




    fn search(self: *Self, vector: nmslib.QueryPoint, k: usize) ![]searchResult {
        
        // Stable allocator for returned results (owned by Vztor)
        const stable_alloc = self.arena.allocator();

        const knn_result = try self.index.knnQuery(vector, k);

        // Allocate the result array from stable allocator (returned to caller)
        const final_result = try stable_alloc.alloc(searchResult, knn_result.used);

        const txn = try lmdbx.Transaction.init(self.env, .{ .mode = .ReadOnly });
        defer txn.abort() catch unreachable;

        const db_data = try txn.database("data", .{});
        const db_index_to_key = try txn.database("index_to_key", .{});

        // stack buffer for numeric key formatting (reused each iteration)
        var num_buf: [32]u8 = undefined;

        for (0..knn_result.used) |i| {
            const id = knn_result.ids[i];
            const distance = knn_result.distances[i];

            const numericKeySlice = try std.fmt.bufPrint(&num_buf, "{d}", .{ id });

            // Handle possible missing entries explicitly
            const key_pos_raw = (try db_index_to_key.get(numericKeySlice)) orelse return error.KeyNotFound;
            const d = try utils.key_pos_parse(key_pos_raw);

            const data_raw = try db_data.get(d.key) orelse return error.KeyNotFound;

            // Copy both key and data into stable allocator so they remain valid
            const key_copy = try stable_alloc.dupe(u8, d.key);
            const data_copy = try stable_alloc.dupe(u8, data_raw);

            final_result[i] = searchResult{
                .key = key_copy,
                .data = data_copy,
                .distance = distance,
            };
        }

        return final_result;
    }


    pub fn save(self: *Self) !void {
        const cwd = std.fs.cwd();

        // Ensure the *directory* containing the index exists *before* saving
        const idx_dir = std.fs.path.dirname(self.indexPath) orelse ".";
        try cwd.makePath(idx_dir);

        // Save index to disk using NMSLIB (to "<db_path>/IDX/index")
        try self.index.save(self.indexPath, true);

        // Flush LMDB environment to disk
        try self.env.sync();

        // Marker file alongside the index: "<db_path>/IDX/.nmslib_saved"
        const allocator = self.arena.allocator();
        const marker_path = try std.fs.path.join(allocator, &.{ idx_dir, ".nmslib_saved" });
        defer allocator.free(marker_path);

        var marker = try cwd.createFile(marker_path, .{ .truncate = true });
        defer marker.close();
        try marker.writeAll("ok\n");
    }


};


pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const max_readers:u32 = 1000;
    const db_path:[]const u8 = "testDB";
    const space_type:[]const u8 = "negdotprod_sparse"; 
    const vector_type = nmslib.DataType.SparseVector;
    const dist_type = nmslib.DistType.Float;
    std.debug.assert(nmslib.isValidSpaceType(space_type));

    var store = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, max_readers);
    defer store.deinit() catch unreachable;

    
    const vectors = [_][]const nmslib.SparseElem{
        &[_]nmslib.SparseElem{
            .{ .id = 1, .value = 1.0 },
            .{ .id = 5, .value = 2.0 },
        },
        &[_]nmslib.SparseElem{
            .{ .id = 2, .value = 1.0 },
            .{ .id = 10, .value = 3.0 },
        },
    };

    const data = [_][]const u8{"Vector 1", "Vector2"};

    const keys = try store.batchPut(&vectors, &data, null);
    
    std.debug.print("Key: {s}\n", .{keys[1]});
    const r = try store.batchGet(keys[1]);
    std.debug.print("Data: {s}\n", .{r.data});
}



test "Vztor: basic put/get/save and reload" {
    std.debug.print("[ ] Vztor: basic put/get/save and reload\n", .{});

    const allocator = std.heap.page_allocator;
    const db_path = "testdb_vstore_zigtest";
    const space_type = "negdotprod_sparse";
    const vector_type = nmslib.DataType.SparseVector;
    const dist_type = nmslib.DistType.Float;

    // Initialize the store
    var store = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, 16);

    // Prepare two sparse vectors and payloads
    const vectors = [_][]const nmslib.SparseElem{
        &[_]nmslib.SparseElem{
            .{ .id = 1, .value = 1.0 },
            .{ .id = 5, .value = 2.0 },
        },
        &[_]nmslib.SparseElem{
            .{ .id = 2, .value = 1.0 },
            .{ .id = 10, .value = 3.0 },
        },
    };
    const payloads = [_][]const u8{
        "Vector 1",
        "Vector 2",
    };

    // Insert and receive keys (owned by the store's arena)
    const keys = try store.batchPut(&vectors, &payloads, null);
    try std.testing.expect(keys.len == 2);

    // Copy the key we will use after store is destroyed
    const key_copy = try allocator.dupe(u8, keys[1]);

    // Verify batchGet while the store is still live
    const got = try store.batchGet(keys[1]);
    try std.testing.expect(std.mem.eql(u8, got.data, "Vector 2"));

    // Persist index + LMDB to disk explicitly
    try store.save();

    // Explicitly deinit the store so we can test reopening
    try store.deinit();

    // Re-open the store from the same path (index should be loaded from disk)
    var reopened = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, 16);

    // Re-fetch using the copied key (not owned by the arena)
    const got2 = try reopened.batchGet(key_copy);
    try std.testing.expect(std.mem.eql(u8, got2.data, "Vector 2"));

    // Close reopened store
    try reopened.deinit();

    // Cleanup copied key and DB directory
    allocator.free(key_copy);
    const cwd = std.fs.cwd();
    cwd.deleteTree(db_path) catch {};

    std.debug.print("[x] Vztor: basic put/get/save and reload\n", .{});
}



test "Vztor: batchPut returns unique keys on repeated insert" {
    std.debug.print("[ ] Vztor: batchPut returns unique keys on repeated insert\n", .{});

    const allocator = std.heap.page_allocator;
    const db_path = "testdb_vstore_unique_keys";
    const space_type = "negdotprod_sparse";
    const vector_type = nmslib.DataType.SparseVector;
    const dist_type = nmslib.DistType.Float;

    var store = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, 16);

    const vectors = [_][]const nmslib.SparseElem{
        &[_]nmslib.SparseElem{
            .{ .id = 1, .value = 1.0 },
        },
        &[_]nmslib.SparseElem{
            .{ .id = 2, .value = 1.0 },
        },
    };

    const payloads = [_][]const u8{ "A", "B" };

    // First batch insert
    const keys1 = try store.batchPut(&vectors, &payloads, null);

    // Second batch insert with same vectors/payloads
    const keys2 = try store.batchPut(&vectors, &payloads, null);

    try std.testing.expect(keys1.len == keys2.len);
    // Expect the keys to be different (store should generate unique ids each insertion)
    try std.testing.expect(!std.mem.eql(u8, keys1[0], keys2[0]));
    try std.testing.expect(!std.mem.eql(u8, keys1[1], keys2[1]));

    // Cleanly deinit the store (this may call save internally)
    try store.deinit();

    // Then delete the DB directory
    const cwd = std.fs.cwd();
    cwd.deleteTree(db_path) catch {};

    std.debug.print("[x] Vztor: batchPut returns unique keys on repeated insert\n", .{});
}



test "Vztor: batchGet returns KeyNotFound for missing key" {
    std.debug.print("[ ] Vztor: batchGet returns KeyNotFound for missing key\n", .{});
    const allocator = std.heap.page_allocator;
    const db_path = "testdb_vstore_missing_key";
    const space_type = "negdotprod_sparse";
    const vector_type = nmslib.DataType.SparseVector;
    const dist_type = nmslib.DistType.Float;

    {
        var store = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, 8);

        // Attempt to get a key that does not exist
        const res = store.batchGet("no-such-key");
        try std.testing.expectError(error.KeyNotFound, res);

        // Cleanly deinit the store before deleting files
        try store.deinit();
    }

    const cwd = std.fs.cwd();
    cwd.deleteTree(db_path) catch {};
    std.debug.print("[x] Vztor: batchGet returns KeyNotFound for missing key\n", .{});
}


test "Vztor: bulk 10 insert and retrieve" {
    std.debug.print("[ ] Vztor: bulk 10 insert and retrieve\n", .{});
    const allocator = std.heap.page_allocator;
    const db_path = "testdb_vstore_bulk10";
    const space_type = "negdotprod_sparse";
    const vector_type = nmslib.DataType.SparseVector;
    const dist_type = nmslib.DistType.Float;

    var store = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, 16);
    defer store.deinit() catch unreachable;

    const vectors = [_][]const nmslib.SparseElem{
        &[_]nmslib.SparseElem{ .{ .id = 1, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 2, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 3, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 4, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 5, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 6, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 7, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 8, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 9, .value = 1.0 } },
        &[_]nmslib.SparseElem{ .{ .id = 10, .value = 1.0 } },
    };
    const payloads = [_][]const u8{
        "p1","p2","p3","p4","p5","p6","p7","p8","p9","p10"
    };

    const keys = try store.batchPut(&vectors, &payloads, null);
    try std.testing.expect(keys.len == 10);

    // Copy keys externally and verify retrieval
    var external_keys = try allocator.alloc([]const u8, keys.len);
    for (0..keys.len) |i| {
        external_keys[i] = try allocator.dupe(u8, keys[i]);
    }

    for (0..keys.len) |i| {
        const got = try store.batchGet(external_keys[i]);
        try std.testing.expect(std.mem.eql(u8, got.data, payloads[i]));
    }

    // Cleanup external keys and DB dir
    for (0..external_keys.len) |i| {
        allocator.free(external_keys[i]);
    }
    allocator.free(external_keys);

    const cwd = std.fs.cwd();
    cwd.deleteTree(db_path) catch {};
    std.debug.print("[x] Vztor: bulk 10 insert and retrieve\n", .{});
}

test "Vztor: init tolerates empty IDX directory" {
    std.debug.print("[ ] Vztor: init tolerates empty IDX directory\n", .{});
    const allocator = std.heap.page_allocator;
    const db_path = "testdb_vstore_empty_idx";
    const space_type = "negdotprod_sparse";
    const vector_type = nmslib.DataType.SparseVector;
    const dist_type = nmslib.DistType.Float;

    const cwd = std.fs.cwd();

    // Clean any previous leftovers
    cwd.deleteTree(db_path) catch {};

    // Create the DB directory and an empty IDX directory (no index files yet)
    try cwd.makePath(db_path ++ "/IDX");

    // This call used to fail when IDX existed but had no index.
    var store = try Vztor.init(allocator, db_path, space_type, vector_type, dist_type, 16);
    defer store.deinit() catch unreachable;

    // Store should be usable: do a simple put/get round-trip
    const vec0 = [_]nmslib.SparseElem{ .{ .id = 1, .value = 1.0 } };
    const vectors = [_][]const nmslib.SparseElem{ &vec0 };
    const payloads = [_][]const u8{ "hello" };

    const keys = try store.batchPut(&vectors, &payloads, null);
    try std.testing.expect(keys.len == 1);

    const got = try store.batchGet(keys[0]);
    try std.testing.expect(std.mem.eql(u8, got.data, "hello"));

    // Cleanup
    cwd.deleteTree(db_path) catch {};
    std.debug.print("[x] Vztor: init tolerates empty IDX directory\n", .{});
}
