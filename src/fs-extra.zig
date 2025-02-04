const std = @import("std");
const builtin = @import("builtin");

//
// TODO: we should fix std library to address these issues
//
pub fn deleteTree(dir: std.fs.Dir, sub_path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return dir.deleteTree(sub_path);
    }

    // workaround issue on windows where it just doesn't delete things
    const MAX_ATTEMPTS = 10;
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        if (dir.deleteTree(sub_path)) {
            return;
        } else |err| {
            if (attempt == MAX_ATTEMPTS) return err;
            switch (err) {
                error.FileBusy => {
                    std.log.warn("path '{s}' is busy (attempt {}), will retry", .{ sub_path, attempt });
                    std.time.sleep(std.time.ns_per_ms * 100); // sleep for 100 ms
                },
                else => |e| return e,
            }
        }
    }
}
pub fn deleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return std.fs.deleteTreeAbsolute(dir_absolute);
    }
    std.debug.assert(std.fs.path.isAbsolute(dir_absolute));
    return deleteTree(std.fs.cwd(), dir_absolute);
}

pub fn ensureDirAbsolute(dir_absolute: []const u8) !void {
    if (!try existsAbsolute(dir_absolute)) {
        try std.fs.cwd().makePath(dir_absolute);
    }
}

pub fn existsAbsolute(absolutePath: []const u8) !bool {
    if (!std.fs.path.isAbsolute(absolutePath)) {
        return error.NotAbsolute;
    }
    return exists(absolutePath);
}

// TODO: this should be in std lib somewhere
pub fn exists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        error.PermissionDenied => return e,
        error.InputOutput => return e,
        error.SystemResources => return e,
        error.SymLinkLoop => return e,
        error.FileBusy => return e,
        error.Unexpected => unreachable,
        error.InvalidUtf8 => return e,
        error.InvalidWtf8 => return e,
        error.ReadOnlyFileSystem => unreachable,
        error.NameTooLong => unreachable,
        error.BadPathName => unreachable,
    };
    return true;
}

pub fn writeJsonValueFile(json: *const std.json.Value, path: []const u8) !void {
    const output = try std.fs.cwd().createFile(path, .{});
    defer output.close();

    const writer = output.writer();

    try std.json.stringify(json, .{ .whitespace = .indent_2 }, writer);
}
