const std = @import("std");
const Io = std.Io;

const zig_consistent_hashing = @import("zig_consistent_hashing");

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const gpa: std.mem.Allocator = init.gpa.allocator();
    const alloc = gpa.allocator();
    const max_nodes = 1000;
    var ring = try zig_consistent_hashing.ConsistentHashRing(u32, std.hash.Crc32, .{
        .max_nodes = max_nodes,
    }).init(alloc);
    var ids: [max_nodes][]const u8 = undefined;
    for (0..max_nodes) |i| {
        const node_id = try std.fmt.allocPrint(alloc, "node:{d}", .{i});
        ids[i] = node_id;
        try ring.addNode(node_id, alloc);
    }
    _ = try ring.getNode("some value ID");
}
