const std = @import("std");
const zon: struct {
    name: enum { multask },
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
    dependencies: struct {
        flute: struct {
            url: []const u8,
            hash: []const u8
        }
    }
} = @import("build_zon");

const log = @import("../lib/log.zig");
const Errors = @import("../lib/error.zig").Errors;

pub fn run() Errors!void {
    try log.printinfo("Multask version: v{s}", .{zon.version});
}
