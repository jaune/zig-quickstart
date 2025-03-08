const std = @import("std");
const builtin = @import("builtin");

const known_folders = @import("known_folders");

const fsx = @import("./fs-extra.zig");
const archive = @import("./archive.zig");

const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const project_name = "zig-quickstart";

const DownloadAndExtractOptions = struct {
    archive_root_dir: ?[]const u8 = null,
};

fn downloadAndExtract(allocator: Allocator, url: *const std.Uri, executable_path: []const u8, options: DownloadAndExtractOptions) !void {
    if (try fsx.existsAbsolute(executable_path)) {
        return;
    }

    const executable_dir = std.fs.path.dirname(executable_path) orelse {
        return error.NoExecutableDir;
    };

    try fsx.deleteTreeAbsolute(executable_dir);

    const installing_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ executable_dir, ".installing" });
    defer allocator.free(installing_dir);

    try fsx.deleteTreeAbsolute(installing_dir);
    try fsx.ensureDirAbsolute(installing_dir);

    const path = switch (url.path) {
        .raw => |r| r,
        .percent_encoded => |r| r,
    };

    const archive_basename = std.fs.path.basename(path);

    // download and extract archive
    {
        const archive_absolute = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_basename });
        defer allocator.free(archive_absolute);
        std.log.info("downloading '{}' to '{s}'", .{ url, archive_absolute });

        const file = try std.fs.createFileAbsolute(archive_absolute, .{});
        // note: important to close the file before we handle errors below
        //       since it will delete the parent directory of this file
        defer file.close();

        const dl_result = download(allocator, url, file.writer());

        switch (dl_result) {
            .ok => {},
            .err => |err| {
                std.log.err("could not download '{}': {s}", .{ url, err });
                // this removes the installing dir if the http request fails so we dont have random directories
                try fsx.deleteTreeAbsolute(installing_dir);
                return error.AlreadyReported;
            },
        }

        try archive.extract(allocator, archive_absolute, installing_dir);
        try fsx.deleteTreeAbsolute(archive_absolute);
    }

    if (options.archive_root_dir) |archive_root_dir| {
        const extracted_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_root_dir });
        defer allocator.free(extracted_dir);

        std.log.info("rename {s} => {s}", .{ extracted_dir, executable_dir });
        try std.fs.renameAbsolute(extracted_dir, executable_dir);
        try fsx.deleteTreeAbsolute(installing_dir);
    } else {
        try std.fs.renameAbsolute(installing_dir, executable_dir);
    }
}

const DownloadResult = union(enum) {
    ok: void,
    err: []u8,
    pub fn deinit(self: DownloadResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| allocator.free(e),
        }
    }
};

fn download(allocator: Allocator, uri: *const std.Uri, writer: anytype) DownloadResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to query the HTTP proxy settings with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    var header_buffer: [2 * 4096]u8 = undefined;
    var request = client.open(.GET, uri.*, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to connect to the HTTP server with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    defer request.deinit();

    request.send() catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to send the HTTP request with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };
    request.wait() catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to read the HTTP response headers with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    if (request.response.status != .ok) return .{ .err = std.fmt.allocPrint(
        allocator,
        "the HTTP server replied with unsuccessful response '{d} {s}'",
        .{ @intFromEnum(request.response.status), request.response.status.phrase() orelse "" },
    ) catch |e| oom(e) };

    // TODO: we take advantage of request.response.content_length
    var buf: [std.heap.page_size_max]u8 = undefined;
    while (true) {
        const len = request.reader().read(&buf) catch |err| return .{ .err = std.fmt.allocPrint(
            allocator,
            "failed to read the HTTP response body with {s}'",
            .{@errorName(err)},
        ) catch |e| oom(e) };
        if (len == 0)
            return .ok;
        writer.writeAll(buf[0..len]) catch |err| return .{ .err = std.fmt.allocPrint(
            allocator,
            "failed to write the HTTP response body with {s}'",
            .{@errorName(err)},
        ) catch |e| oom(e) };
    }
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .riscv64 => "riscv64",
    .powerpc64le => "powerpc64le",
    .powerpc => "powerpc",
    else => @compileError("Unsupported CPU Architecture"),
};

const os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};

const url_platform = os ++ "-" ++ arch;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

const zig_executable_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
const zls_executable_name = if (builtin.os.tag == .windows) "zls.exe" else "zls";

fn fetchCompiler(
    allocator: Allocator,
    version: std.SemanticVersion,
) ![]const u8 {
    const home_dir = try known_folders.getPath(allocator, .home) orelse {
        return error.NoHomeDirectoryFound;
    };
    defer allocator.free(home_dir);

    const version_string = try std.fmt.allocPrint(allocator, "{}", .{version});
    defer allocator.free(version_string);

    const archive_basename_no_ext = try std.fmt.allocPrint(allocator, "zig-" ++ url_platform ++ "-{s}", .{version_string});
    defer allocator.free(archive_basename_no_ext);

    const version_url = if (version.pre == null or version.build == null)
        try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/{s}.{s}", .{ version_string, archive_basename_no_ext, archive_ext })
    else
        try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/{s}.{s}", .{ archive_basename_no_ext, archive_ext });
    defer allocator.free(version_url);

    const zig_dl_zig_version_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, project_name, "zig", version_string });
    defer allocator.free(zig_dl_zig_version_dir);

    try fsx.ensureDirAbsolute(zig_dl_zig_version_dir);

    const url = try std.Uri.parse(version_url);

    const zig_executable_path = try std.fs.path.join(allocator, &[_][]const u8{ zig_dl_zig_version_dir, zig_executable_name });
    errdefer allocator.free(zig_executable_path);

    try downloadAndExtract(allocator, &url, zig_executable_path, .{
        .archive_root_dir = archive_basename_no_ext,
    });

    return zig_executable_path;
}

fn fetchLanguageServer(
    allocator: Allocator,
    version: std.SemanticVersion,
) ![]const u8 {
    const home_dir = try known_folders.getPath(allocator, .home) orelse {
        return error.NoHomeDirectoryFound;
    };
    defer allocator.free(home_dir);

    const version_string = try std.fmt.allocPrint(allocator, "{}", .{version});
    defer allocator.free(version_string);

    const zls_archive_ext = if (builtin.os.tag == .windows) "zip" else if (version.major == 0 and version.minor <= 11) "tar.gz" else "tar.xz";

    const version_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/zigtools/zls/releases/download/{s}/zls-" ++ arch ++ "-" ++ os ++ ".{s}",
        .{
            version_string,
            zls_archive_ext,
        },
    );
    defer allocator.free(version_url);

    const zig_dl_zig_version_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, project_name, "zls", version_string });
    defer allocator.free(zig_dl_zig_version_dir);

    try fsx.ensureDirAbsolute(zig_dl_zig_version_dir);

    const url = try std.Uri.parse(version_url);

    const zls_executable_path = try std.fs.path.join(allocator, &[_][]const u8{ zig_dl_zig_version_dir, zls_executable_name });
    errdefer allocator.free(zls_executable_path);

    try downloadAndExtract(allocator, &url, zls_executable_path, .{
        .archive_root_dir = if (version.major == 0 and version.minor <= 11) "bin" else null,
    });

    return zls_executable_path;
}

const env_path_sentinel = if (builtin.os.tag == .windows) ";${env:PATH}" else ":$PATH";

const terminal_integrated_env_key = switch (builtin.os.tag) {
    .windows => "terminal.integrated.env.windows",
    .macos => "terminal.integrated.env.osx",
    .linux => "terminal.integrated.env.linux",
    else => @compileError("Unsupported OS"),
};

const vscode_settings_path = "./.vscode/settings.json";

const WriteVscodeSettingsFileOptions = struct {
    zig_executable_path: []const u8,
    zls_executable_path: []const u8,
};

fn readJsonFileOrDefault(allocator: std.mem.Allocator, path: []const u8, default: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 4096) catch {
        return default;
    };
}

fn writeVscodeSettingsFile(allocator: std.mem.Allocator, options: WriteVscodeSettingsFileOptions) !void {
    var area = std.heap.ArenaAllocator.init(allocator);
    defer area.deinit();

    const area_allocator = area.allocator();

    const vscode_settings_dir = std.fs.path.dirname(vscode_settings_path) orelse {
        return error.NoVscodeSettingsDir;
    };

    try std.fs.cwd().makePath(vscode_settings_dir);

    const json_string = readJsonFileOrDefault(area_allocator, vscode_settings_path, "{}");

    var scanner = std.json.Scanner.initCompleteInput(area_allocator, json_string);
    defer scanner.deinit();

    var json = try std.json.Value.jsonParse(area_allocator, &scanner, .{
        .allocate = .alloc_if_needed,
        .max_value_len = 4096,
    });

    const zig_executable_dir = std.fs.path.dirname(options.zig_executable_path) orelse {
        return error.NoZigExecutableDirectory;
    };

    const envPathValue = std.json.Value{ .string = try std.fs.path.join(area_allocator, &[_][]const u8{ zig_executable_dir, env_path_sentinel }) };

    var envPathObject = std.json.ObjectMap.init(area_allocator);
    try envPathObject.put(
        "PATH",
        envPathValue,
    );

    switch (json) {
        .object => |*o| {
            try o.put("zig.path", std.json.Value{ .string = options.zig_executable_path });
            try o.put("zig.zls.path", std.json.Value{ .string = options.zls_executable_path });

            const terminal = try o.getOrPutValue(terminal_integrated_env_key, std.json.Value{ .object = envPathObject });
            if (terminal.found_existing) {
                switch (terminal.value_ptr.*) {
                    .object => |*p| {
                        try p.put(
                            "PATH",
                            envPathValue,
                        );
                    },
                    else => {},
                }
            }
        },
        else => {},
    }

    try fsx.writeJsonValueFile(&json, vscode_settings_path);
}

const version_file_paths = [_][]const u8{
    "./.zigversion",
    "./.zig-version",
};

fn findVersionFilePath() ?[]const u8 {
    for (version_file_paths) |p| {
        const e = fsx.exists(p) catch {
            continue;
        };

        if (e) {
            return p;
        }
    }

    return null;
}

fn findVersion() ?std.SemanticVersion {
    const path = findVersionFilePath() orelse {
        return null;
    };

    var buffer: [1024]u8 = undefined;

    const data = std.fs.cwd().readFile(path, &buffer) catch {
        return null;
    };

    return std.SemanticVersion.parse(std.mem.trim(u8, data, " \n\t\r")) catch {
        return null;
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const version = findVersion() orelse {
        return error.NoVersionFileFound;
    };

    const zig_executable_path = try fetchCompiler(allocator, version);
    defer allocator.free(zig_executable_path);

    const zls_executable_path = try fetchLanguageServer(allocator, version);
    defer allocator.free(zls_executable_path);

    try writeVscodeSettingsFile(allocator, .{
        .zig_executable_path = zig_executable_path,
        .zls_executable_path = zls_executable_path,
    });

    std.log.info("zig version {}", .{version});
}
