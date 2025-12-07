# Vztor

A key-value based vector database written in Zig.

## Overview

Vztor combines the power of [NMSLIB](https://github.com/nmslib/nmslib) for efficient approximate nearest neighbor search with [libmdbx](https://libmdbx.dqdkfa.ru/) for persistent key-value storage. It provides a simple API for storing, retrieving, and searching vectors with associated metadata.

## Features

* **Key-Value Storage**: Store vectors with associated data payloads
* **Vector Search**: Fast approximate nearest neighbor search using HNSW algorithm
* **Persistence**: Automatic persistence of both vectors and metadata to disk
* **Sparse Vectors**: Support for sparse vector representations
* **Auto-generated Keys**: Optional UUID generation for vector keys
* **Batch Operations**: Efficient batch insert and retrieval operations

## Requirements

* Zig 0.15.2 or later

Dependencies are managed via Zig's package manager:

* [lmdbx-zig](https://github.com/B-R-P/lmdbx-zig) - LMDBX wrapper for Zig
* [nmslib-zig](https://github.com/B-R-P/nmslib-zig) - NMSLIB wrapper for Zig

## Installation

Add Vztor as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .vztor = .{
        .url = "https://github.com/B-R-P/Vztor/archive/refs/tags/0.0.1.tar.gz",
        .hash = "...",
    },
},
```

After declaring the dependency in `build.zig.zon`, wire it into your `build.zig` so the module becomes available to your executable:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const vztor_dep = b.dependency("vztor", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vztor", vztor_dep.module("vztor"));

    b.installArtifact(exe);
}
```

Once added, the module can be imported anywhere in the code using:

```zig
const Vztor = @import("vztor").Vztor;
```

## Usage

### Initialize the Store

```zig
const std = @import("std");
const Vztor = @import("vztor").Vztor;
const nmslib = @import("nmslib");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    var store = try Vztor.init(
        allocator,
        "my_database",           // Database path
        "negdotprod_sparse",     // Space type
        nmslib.DataType.SparseVector,
        nmslib.DistType.Float,
        1000,                    // Max readers
    );
    defer store.deinit() catch unreachable;
}
```

### Insert Vectors

```zig
// Define sparse vectors
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

// Associated data payloads
const data = [_][]const u8{ "Vector 1", "Vector 2" };

// Insert vectors (keys are auto-generated if null)
const keys = try store.batchPut(&vectors, &data, null);
```

### Retrieve Vectors

```zig
// Get vector and data by key
const result = try store.batchGet(keys[0]);
std.debug.print("Data: {s}\n", .{result.data});
```

### Search Similar Vectors

```zig
// Search for k nearest neighbors
const search_results = try store.search(query_vector, k);

for (search_results) |result| {
    std.debug.print("Key: {s}, Distance: {d}\n", .{ result.key, result.distance });
}
```

### Persist to Disk

```zig
try store.save();
```

## API Reference

### Vztor

#### `init(allocator, comptime db_path, space_type, vector_type, dist_type, max_readers)`

Initializes a new Vztor instance or loads an existing one from disk.

* `allocator`: Memory allocator
* `db_path`: Path to the database directory (comptime string)
* `space_type`: Vector space type (e.g., "negdotprod_sparse")
* `vector_type`: Type of vectors (e.g., `SparseVector`)
* `dist_type`: Distance type (e.g., `Float`)
* `max_readers`: Maximum number of concurrent readers

#### `batchPut(vectors, data, keys)`

Inserts multiple vectors with associated data.

* `vectors`: Array of sparse vectors
* `data`: Array of data payloads
* `keys`: Optional array of keys (auto-generated if null)

Returns: Array of keys for the inserted vectors

#### `batchGet(key)`

Retrieves a vector and its associated data by key.

Returns: `GetResult` struct with `vector` and `data` fields

#### `search(vector, k)`

Searches for the k nearest neighbors to the given vector.

Returns: Array of `SearchResult` structs with `key`, `data`, and `distance` fields

#### `save()`

Persists the index and flushes LMDBX to disk.

#### `deinit()`

Cleans up resources and closes the store. Returns an error union (`!void`).

Note: Copy `SearchResult` and `GetResult` before deinit for later use.

## Architecture

Vztor uses a dual-storage architecture:

1. **NMSLIB Index**: Stores vectors for fast approximate nearest neighbor search using the HNSW algorithm
2. **LMDBX Database**: Stores key-value mappings and metadata for persistence

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```