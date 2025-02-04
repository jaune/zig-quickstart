const std = @import("std");
const builtin = @import("builtin");

pub fn extract(allocator: std.mem.Allocator, archive_path: []const u8, destination_dir: []const u8) !void {
    if (!std.fs.path.isAbsolute(archive_path)) {
        return error.ArchivePathShouldBeAbsolute;
    }
    if (!std.fs.path.isAbsolute(destination_dir)) {
        return error.DestinationDirShouldBeAbsolute;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
        _ = try run(allocator, &[_][]const u8{ "tar", "xf", archive_path, "-C", destination_dir });
    } else {
        var recognized = false;
        if (builtin.os.tag == .windows) {
            if (std.mem.endsWith(u8, archive_path, ".zip")) {
                recognized = true;

                var installing_dir_opened = try std.fs.openDirAbsolute(destination_dir, .{});
                defer installing_dir_opened.close();
                var timer = try std.time.Timer.start();
                var archive_file = try std.fs.openFileAbsolute(archive_path, .{});
                defer archive_file.close();
                try std.zip.extract(installing_dir_opened, archive_file.seekableStream(), .{});
                const time = timer.read();
                std.log.info("extracted archive in {d:.2} s", .{@as(f32, @floatFromInt(time)) / @as(f32, @floatFromInt(std.time.ns_per_s))});
            }
        }

        if (!recognized) {
            std.log.err("unknown archive extension '{s}'", .{archive_path});
            return error.UnknownArchiveExtension;
        }
    }
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.Term {
    try logRun(allocator, argv);
    var proc = std.process.Child.init(argv, allocator);
    return proc.spawnAndWait();
}

fn logRun(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var buffer = try allocator.alloc(u8, getCommandStringLength(argv));
    defer allocator.free(buffer);

    var prefix = false;
    var offset: usize = 0;
    for (argv) |arg| {
        if (prefix) {
            buffer[offset] = ' ';
            offset += 1;
        } else {
            prefix = true;
        }
        @memcpy(buffer[offset .. offset + arg.len], arg);
        offset += arg.len;
    }
    std.debug.assert(offset == buffer.len);
}

pub fn getCommandStringLength(argv: []const []const u8) usize {
    var len: usize = 0;
    var prefix_length: u8 = 0;
    for (argv) |arg| {
        len += prefix_length + arg.len;
        prefix_length = 1;
    }
    return len;
}
