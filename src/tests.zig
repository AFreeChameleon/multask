const std = @import("std");
const Errors = @import("lib/error.zig").Errors;
const expect = std.testing.expect;

test "lib/args/getopt.zig" {
    const getopt = @import("lib/args/getopt.zig");
    {
        std.debug.print("Parsing 2 args 1 option 1 alone arg.", .{});
        var argv = [7][*:0]const u8{
            "getopt",
            "-a",
            "fing",
            "-b",
            "ting",
            "-c",
            "alonearg"
        };
        var opts = getopt.getoptArgv(&argv, "a:b:c");
        var next_val = try opts.next();
        while (!opts.optbreak) {
            if (next_val == null) {
                next_val = try opts.next();
                continue;
            }
            const opt = next_val.?;
            switch (opt.opt) {
                'a' => {
                    const arg: []const u8 = opt.arg.?;
                    try expect(std.mem.eql(u8, arg, "fing"));
                },
                'b' => {
                    const arg: []const u8 = opt.arg.?;
                    try expect(std.mem.eql(u8, arg, "ting"));
                },
                'c' => {
                    try expect(opt.arg == null);
                },
                else => {}
            }
            next_val = try opts.next();
        }
    }
}

test "lib/util.zig" {
    const util = @import("./lib/util.zig");
    std.debug.print("get_readable_memory\n", .{});
    {
        std.debug.print("Parse 1 to 1 B\n", .{});
        const res = try util.get_readable_memory(1);
        try expect(std.mem.eql(u8, res, "1 B"));
    }
    {
        std.debug.print("Parse 1024 to 1 KiB\n", .{});
        const res = try util.get_readable_memory(1024);
        try expect(std.mem.eql(u8, res, "1 KiB"));
    }
    {
        std.debug.print("Parse 1500 to 1.5 KiB\n", .{});
        const res = try util.get_readable_memory(1500);
        try expect(std.mem.eql(u8, res, "1.5 KiB"));
    }
}
