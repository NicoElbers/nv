const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const utils = @import("../utils.zig");

const Allocator = std.mem.Allocator;
const File = fs.File;
const Dir = fs.Dir;
const Plugin = utils.Plugin;
const Substitution = utils.Substitution;

const Self = @This();

alloc: Allocator,
in_dir: Dir,
out_dir: Dir,
extra_init_config: []const u8,

// TODO: Change paths to dirs
pub fn init(alloc: Allocator, in_path: []const u8, out_path: []const u8, extra_init_config: []const u8) !Self {
    assert(fs.path.isAbsolute(in_path));
    assert(fs.path.isAbsolute(out_path));

    std.log.debug("Attempting to open dir '{s}'", .{in_path});
    const in_dir = try fs.openDirAbsolute(in_path, .{ .iterate = true });

    std.log.debug("Attempting to create '{s}'", .{out_path});

    // Go on if the dir already exists
    fs.accessAbsolute(out_path, .{}) catch {
        try fs.makeDirAbsolute(out_path);
    };

    std.log.debug("Attempting to open '{s}'", .{out_path});
    const out_dir = try fs.openDirAbsolute(out_path, .{});

    return Self{
        .alloc = alloc,
        .in_dir = in_dir,
        .out_dir = out_dir,
        .extra_init_config = extra_init_config,
    };
}

pub fn deinit(self: *Self) void {
    self.in_dir.close();
    self.out_dir.close();
}

/// This function creates the lua config in the specificified location.
///
/// It extracts specific substitutions from the passed in plugins and then
/// iterates over the input directory recursively. It copies non lua files
/// directly and parses lua files for substitutions before copying the parsed
/// files over.
///
// TODO:
// IDEA: Give substitutions types.
//   -> A type for github URLS which looks for
//       url = ${String of {url}}
//       ${String of {url}}
//       url = ${String of {short_url}}
//       ${String of {short_url}}
//   -> A type for normal URLs
//       url = ${String of {url}}
//       ${String of {url}}
//   -> A type for string replacement
//       ${String of {given}}
//   -> A type for general replacement
//       {given}
// Here ${String of {x}} means `"x"` `'x'` or `[[x]]`
pub fn createConfig(self: Self, plugins: []const Plugin, subs_blob: []const u8) !void {
    const subs = blk: {
        var subs_arr = std.ArrayList(Substitution).init(self.alloc);
        try appendFromBlob(self.alloc, subs_blob, &subs_arr);
        try subsFromPlugins(self.alloc, plugins, &subs_arr);
        break :blk try subs_arr.toOwnedSlice();
    };
    defer {
        for (subs) |sub| {
            sub.deinit(self.alloc);
        }
        self.alloc.free(subs);
    }

    var walker = try self.in_dir.walk(self.alloc);
    defer walker.deinit();

    std.log.info("Starting directory walk", .{});
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                // Go on if the dir already exists
                self.out_dir.access(entry.path, .{}) catch {
                    try self.out_dir.makeDir(entry.path);
                };
            },
            .file => {
                if (std.mem.eql(u8, ".lua", std.fs.path.extension(entry.basename))) {
                    std.log.info("parsing '{s}'", .{entry.path});
                    const in_file = try self.in_dir.openFile(entry.path, .{});
                    const in_buf = try utils.mmapFile(in_file, .{});
                    defer utils.unMmapFile(in_buf);

                    const out_buf = try parseLuaFile(self.alloc, in_buf, subs);
                    defer self.alloc.free(out_buf);

                    const out_file = try self.out_dir.createFile(entry.path, .{});

                    if (std.mem.eql(u8, entry.path, "init.lua")) {
                        try out_file.writeAll(self.extra_init_config);
                    }

                    try out_file.writeAll(out_buf);
                } else {
                    std.log.info("copying '{s}'", .{entry.path});
                    try self.in_dir.copyFile(
                        entry.path,
                        self.out_dir,
                        entry.path,
                        .{},
                    );
                }
            },
            else => std.log.warn("Kind {}", .{entry.kind}),
        }
    }
}

/// Memory owned by out
fn appendFromBlob(alloc: Allocator, subs_blob: []const u8, out: *std.ArrayList(Substitution)) !void {
    var iter = utils.BufIter{ .buf = subs_blob };

    // TODO: Is this ok? Ask someone with more experience
    if (subs_blob.len < 3) {
        return;
    }

    while (!iter.isDone()) {
        const from = iter.nextUntilExcluding("|").?;
        const to = iter.nextUntilExcluding(";") orelse iter.rest() orelse return error.BadSub;
        try out.append(Substitution{
            .from = try alloc.dupe(u8, from),
            .to = try alloc.dupe(u8, to),
        });
    }
}

/// Memory owned by caller
fn subsFromPlugins(alloc: Allocator, plugins: []const Plugin, out: *std.ArrayList(Substitution)) !void {
    for (plugins) |plugin| {
        switch (plugin.tag) {
            .UrlNotFound => continue,
            .GitUrl => {
                try out.append(try Substitution.initUrlSub(
                    alloc,
                    plugin.url,
                    plugin.path,
                    plugin.pname,
                ));
            },
            .GithubUrl => {
                try out.append(try Substitution.initUrlSub(
                    alloc,
                    plugin.url,
                    plugin.path,
                    plugin.pname,
                ));

                var url_splitter = std.mem.splitSequence(u8, plugin.url, "://github.com/");
                _ = url_splitter.next().?;
                const short_url = url_splitter.rest();

                try out.append(try Substitution.initUrlSub(
                    alloc,
                    short_url,
                    plugin.path,
                    plugin.pname,
                ));
            },
        }
    }
}

// Good example of url usage:
// https://sourcegraph.com/github.com/Amar1729/dotfiles/-/blob/dot_config/nvim/lua/plugins/treesitter.lua

/// Returns a _new_ buffer, owned by the caller
fn parseLuaFile(alloc: Allocator, input_buf: []const u8, subs: []const Substitution) ![]const u8 {
    var iter = utils.BufIter{ .buf = input_buf };

    var out_arr = std.ArrayList(u8).init(alloc);

    while (!iter.isDone()) {
        var chosen_sub: ?Substitution = null;
        var chosen_skipped: ?[]const u8 = null;
        inner: for (subs) |sub| {
            const skip_str = iter.peekUntilBefore(sub.from) orelse continue :inner;
            if (chosen_skipped == null or skip_str.len < chosen_skipped.?.len) {
                chosen_skipped = skip_str;
                chosen_sub = sub;
            }
        }

        if (chosen_sub) |sub| {
            assert(chosen_skipped != null);

            std.log.debug("Sub '{s}' -> '{s}'", .{ sub.from, sub.to });
            try out_arr.appendSlice(chosen_skipped.?);
            try out_arr.appendSlice(sub.to);
            iter.ptr += chosen_skipped.?.len;
            iter.ptr += sub.from.len;
        } else {
            std.log.debug("No more subs in this file...", .{});
            try out_arr.appendSlice(iter.rest() orelse "");
        }
    }

    return out_arr.toOwnedSlice();
}

test "parseLuaFile copy" {
    const alloc = std.testing.allocator;
    const input_buf = "Hello world";
    const expected = "Hello world";

    const subs = &.{
        Substitution{
            .from = "asdf",
            .to = "fdsa",
        },
    };

    const out_buf = try parseLuaFile(alloc, input_buf, subs);
    defer alloc.free(out_buf);

    try std.testing.expectEqualStrings(expected, out_buf);
}

test "parseLuaFile simple sub" {
    const alloc = std.testing.allocator;
    const input_buf = "Hello world";
    const expected = "hi world";

    const subs = &.{
        Substitution{
            .from = "Hello",
            .to = "hi",
        },
    };

    const out_buf = try parseLuaFile(alloc, input_buf, subs);
    defer alloc.free(out_buf);

    try std.testing.expectEqualStrings(expected, out_buf);
}

test "parseLuaFile multiple subs" {
    const alloc = std.testing.allocator;
    const input_buf = "Hello world";
    const expected = "world Hello";

    const subs = &.{
        Substitution{
            .from = "Hello",
            .to = "world",
        },
        Substitution{
            .from = "world",
            .to = "Hello",
        },
    };

    const out_buf = try parseLuaFile(alloc, input_buf, subs);
    defer alloc.free(out_buf);

    try std.testing.expectEqualStrings(expected, out_buf);
}

test "test plugin" {
    const alloc = std.testing.allocator;
    const input_buf =
        \\"short/url"
    ;
    const expected =
        \\dir = [[local/path]],
        \\name = [[pname]]
    ;

    const subs: []const Substitution = &.{
        try Substitution.initUrlSub(
            alloc,
            "short/url",
            "local/path",
            "pname",
        ),
    };
    defer {
        for (subs) |sub| {
            sub.deinit(alloc);
        }
    }

    const out_buf = try parseLuaFile(alloc, input_buf, subs);
    defer alloc.free(out_buf);

    try std.testing.expectEqualStrings(expected, out_buf);
}
