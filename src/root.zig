//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

fn VNode(HashType: type) type {
    return struct {
        const Self = @This();

        node_id: []const u8,
        hash: HashType,

        fn cmp(hash: HashType, node: Self) std.math.Order {
            return if (hash == node.hash)
                std.math.Order.eq
            else if (hash < node.hash)
                std.math.Order.lt
            else
                std.math.Order.gt;
        }
    };
}

pub const ConsistentHashRingOptions = struct {
    max_nodes: u32 = 256,
    vnodes_per_node: u32 = 128,
    max_node_id_len: u32 = 256,
};

pub const ConsistentHashRingError = error{
    MaxNodesReached,
    NodeIdTooLong,
    NodeNotFound,
    NoNodes,
    NodeAlreadyExists,
    HashCollision,
};

const hash_patterns: [6][]const u8 = .{ ":{d}", ":vnode:{d}", "_virtual_{d}", ":vnode:idx:{d}", "->{d}", "/vnode[{d}]" };

const HasherTypeCase = union(enum) {
    Value: type,
    Static: type,
};

pub fn ConsistentHashRing(HashType: type, HasherType: HasherTypeCase, opts: ConsistentHashRingOptions) type {
    if (opts.vnodes_per_node == 0) @compileError("vnodes_per_node must be >0");
    if (opts.max_nodes == 0) @compileError("max_nodes must be >0");
    if (opts.max_node_id_len == 0) @compileError("max_node_id_len must be >0");
    const HasherValueType = if (HasherType == .Static) void else HasherType.Value;

    // pad buffer to be able to hold the appended hash patterns after the nodeId when creating vnodes
    const buf_extra_len = std.math.log10(opts.vnodes_per_node) + 16;
    return struct {
        const Self = @This();
        const VNodeT = VNode(HashType);

        hasher: HasherValueType,
        nodes: std.StringHashMap(void),
        // sorted in ascending order by hash
        vnodes: std.ArrayList(VNodeT),

        buf: [opts.max_node_id_len + buf_extra_len]u8 = undefined,

        inline fn get_hasher(self: *Self) if (HasherType == .Static) type else HasherType.Value {
            return if (HasherType == .Static) HasherType.Static else self.hasher;
        }

        fn init(hasher: HasherValueType, alloc: std.mem.Allocator) Self {
            return .{
                .hasher = hasher,
                .nodes = .init(alloc),
                .vnodes = .empty,
            };
        }

        /// node_id memory is not managed
        /// O(n * m), n = # nodes, m = # vnodes per node
        fn addNode(self: *Self, node_id: []const u8, alloc: std.mem.Allocator) !void {
            if (self.nodes.unmanaged.size >= opts.max_nodes) return ConsistentHashRingError.MaxNodesReached;
            if (node_id.len > opts.max_node_id_len) return ConsistentHashRingError.NodeIdTooLong;
            const result = try self.nodes.getOrPut(node_id);
            if (result.found_existing) return ConsistentHashRingError.NodeAlreadyExists;
            _ = try std.fmt.bufPrint(&self.buf, "{s}", .{node_id});
            try self.vnodes.ensureTotalCapacity(alloc, self.vnodes.items.len + opts.vnodes_per_node);
            for (0..opts.vnodes_per_node) |i| {
                var success = false;
                inline for (hash_patterns) |p| {
                    if (!success) {
                        const appended_slice = try std.fmt.bufPrint(self.buf[node_id.len..], p, .{i});
                        const vnode_id = self.buf[0 .. node_id.len + appended_slice.len];
                        const hash = self.get_hasher().hash(vnode_id);
                        const idx = std.sort.lowerBound(VNodeT, self.vnodes.items, hash, VNodeT.cmp);
                        if (idx == self.vnodes.items.len or self.vnodes.items[idx].hash != hash) {
                            self.vnodes.insertAssumeCapacity(idx, .{
                                .node_id = node_id,
                                .hash = hash,
                            });
                            success = true;
                        }
                    }
                }
                // TODO cleanup
                if (!success) return ConsistentHashRingError.HashCollision;
            }
        }

        /// O(n * m), n = # nodes, m = # vnodes per node
        fn removeNode(self: *Self, node_id: []const u8) !void {
            if (!self.nodes.remove(node_id)) return ConsistentHashRingError.NodeNotFound;
            var vnode_idxs: [opts.vnodes_per_node]usize = undefined;
            var vnode_idxs_i: usize = 0;
            for (self.vnodes.items, 0..) |vnode, i| {
                if (std.mem.eql(u8, vnode.node_id, node_id)) {
                    vnode_idxs[vnode_idxs_i] = i;
                    vnode_idxs_i += 1;
                }
            }
            self.vnodes.orderedRemoveMany(&vnode_idxs);
        }

        /// returns the ID of the node the value should be assigned to
        /// O(log n * m), n = # nodes, m = # vnodes per node
        fn getNode(self: *Self, value_id: []const u8) ![]const u8 {
            if (self.nodes.unmanaged.size == 0) return ConsistentHashRingError.NoNodes;
            const value_hash = self.get_hasher().hash(value_id);
            // modulo connects the ends of the rings
            const idx_or_len = std.sort.lowerBound(VNodeT, self.vnodes.items, value_hash, VNodeT.cmp);
            const idx = idx_or_len % self.vnodes.items.len;
            return self.vnodes.items[idx].node_id;
        }
    };
}

pub fn ConsistentHashRingStaticHasher(
    HashType: type,
    Hasher: type,
    comptime opts: ConsistentHashRingOptions,
    alloc: std.mem.Allocator,
) ConsistentHashRing(HashType, HasherTypeCase{ .Static = Hasher }, opts) {
    return .init({}, alloc);
}

pub fn ConsistentHashRingCrc32(
    comptime opts: ConsistentHashRingOptions,
    alloc: std.mem.Allocator,
) ConsistentHashRing(u32, HasherTypeCase{ .Static = std.hash.Crc32 }, opts) {
    return .init({}, alloc);
}

test ConsistentHashRing {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingCrc32(.{}, alloc);
    const test_node = "hello";
    try ring.addNode(test_node, alloc);
    const test_node2 = "hello2";
    try ring.addNode(test_node2, alloc);
    try std.testing.expect(ring.nodes.unmanaged.size == 2);
    try std.testing.expect(ring.vnodes.items.len == 256);
    try ring.removeNode(test_node2);
    try std.testing.expect(ring.nodes.unmanaged.size == 1);
    try std.testing.expect(ring.vnodes.items.len == 128);
    const node = try ring.getNode("some value ID");
    try std.testing.expectEqualSlices(u8, test_node, node);
}

test "ConsistentHashRing works with 64 bit hash" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingStaticHasher(u64, std.hash.CityHash64, .{}, alloc);
    const test_node = "hello";
    try ring.addNode(test_node, alloc);
    const test_node2 = "hello2";
    try ring.addNode(test_node2, alloc);
    try std.testing.expect(ring.nodes.unmanaged.size == 2);
    try std.testing.expect(ring.vnodes.items.len == 256);
    try ring.removeNode(test_node2);
    try std.testing.expect(ring.nodes.unmanaged.size == 1);
    try std.testing.expect(ring.vnodes.items.len == 128);
    const node = try ring.getNode("some value ID");
    try std.testing.expectEqualSlices(u8, test_node, node);
}

test "ConsistentHashRing works with large amounts of nodes" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    const max_nodes = 1000;
    var ring = ConsistentHashRingCrc32(.{
        .max_nodes = max_nodes,
    }, alloc);
    var ids: [max_nodes][]const u8 = undefined;
    for (0..max_nodes) |i| {
        const node_id = try std.fmt.allocPrint(alloc, "node:{d}", .{i});
        ids[i] = node_id;
        try ring.addNode(node_id, alloc);
    }
    _ = try ring.getNode("some value ID");
}

test "ConsistentHashRing errors when trying to add a node beyond the maximum" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingCrc32(.{ .max_nodes = 1 }, alloc);
    const test_node = "hello";
    try ring.addNode(test_node, alloc);
    const test_node2 = "hello2";

    try std.testing.expectError(ConsistentHashRingError.MaxNodesReached, ring.addNode(test_node2, alloc));
}

test "ConsistentHashRing errors when trying to pass a node ID that is too long" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingCrc32(.{ .max_node_id_len = 1 }, alloc);
    const test_node = "hello";

    try std.testing.expectError(ConsistentHashRingError.NodeIdTooLong, ring.addNode(test_node, alloc));
}

test "ConsistentHashRing errors when trying to remove a non-existent node" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingCrc32(.{}, alloc);
    const test_node = "hello";

    try std.testing.expectError(ConsistentHashRingError.NodeNotFound, ring.removeNode(test_node));
}

test "ConsistentHashRing errors when getNode called while the ring is empty" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingCrc32(.{}, alloc);

    try std.testing.expectError(ConsistentHashRingError.NoNodes, ring.getNode("some value ID"));
}

test "ConsistentHashRing errors when trying to re-add the same node" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRingCrc32(.{}, alloc);
    const test_node = "hello";
    try ring.addNode(test_node, alloc);

    try std.testing.expectError(ConsistentHashRingError.NodeAlreadyExists, ring.addNode(test_node, alloc));
}

test "ConsistentHashRing selects node properly" {
    const MockHasher = struct {
        fn hash(data: []const u8) u32 {
            if (std.mem.eql(u8, data, "hello:0")) {
                return 2;
            } else if (std.mem.eql(u8, data, "hello2:0")) {
                return 4;
            } else if (std.mem.eql(u8, data, "data ID")) {
                return 1; // should map to the hash value of 2
            } else if (std.mem.eql(u8, data, "data ID 2")) {
                return 2; // should map to the hash value of 2
            } else if (std.mem.eql(u8, data, "data ID 3")) {
                return 3; // should map to the hash value of 4
            } else if (std.mem.eql(u8, data, "data ID 4")) {
                return 10; // test wrap around, should map to hash value of 1 if only 2 nodes
            } else @panic("bug in test");
        }
    };

    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRing(u32, HasherTypeCase{ .Static = MockHasher }, .{ .vnodes_per_node = 1 }).init({}, alloc);
    const test_node = "hello";
    const test_node2 = "hello2";
    try ring.addNode(test_node, alloc);
    try ring.addNode(test_node2, alloc);

    try std.testing.expectEqualStrings(test_node, try ring.getNode("data ID"));
    try std.testing.expectEqualStrings(test_node, try ring.getNode("data ID 2"));
    try std.testing.expectEqualStrings(test_node2, try ring.getNode("data ID 3"));
    try std.testing.expectEqualStrings(test_node, try ring.getNode("data ID 4"));
}

test "ConsistentHashRing handles node IDs with the same hash" {
    const MockHasher = struct {
        count: u32 = 0,

        fn hash(self: *@This(), _: []const u8) u32 {
            const val = switch (self.count) {
                0, 1 => 0,
                else => self.count,
            };
            self.count += 1;
            return val;
        }
    };
    var mock_hasher = MockHasher{};

    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRing(u32, HasherTypeCase{ .Value = *MockHasher }, .{ .vnodes_per_node = 1 }).init(&mock_hasher, alloc);
    const test_node = "hello";
    const test_node2 = "hello2";
    try ring.addNode(test_node, alloc);
    try ring.addNode(test_node2, alloc);
    // if we encounter a hash collision, we expect addNode to try hashing again with a different string variant
    try std.testing.expectEqual(3, mock_hasher.count);
}

test "ConsistentHashRing errors when encountering too many hash collisions" {
    // TODO test that the ring is cleaned up
    const MockHasher = struct {
        count: u32 = 0,
        fn hash(self: *@This(), _: []const u8) u32 {
            self.count += 1;
            return 0;
        }
    };
    var mock_hasher = MockHasher{};

    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    var ring = ConsistentHashRing(u32, HasherTypeCase{ .Value = *MockHasher }, .{ .vnodes_per_node = 2 }).init(&mock_hasher, alloc);
    try std.testing.expectError(ConsistentHashRingError.HashCollision, ring.addNode("hello", alloc));
    // if we encounter a hash collision, we expect addNode to try hashing again with a different string variant
    try std.testing.expectEqual(1 + hash_patterns[0..].len, mock_hasher.count);
}
