//! Single source of truth for the CLI surface. The help text, man page, and
//! shell completions are all generated from this data, so they cannot drift.

const std = @import("std");
const build_options = @import("build_options");
const settings = @import("settings.zig");

pub const version = build_options.version;
pub const program = "hcibridge";
pub const summary = "Attach remote ESP32 Bluetooth bridges to the local Bluetooth stack";

pub const Opt = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    /// Name of the value this option takes, null for a boolean flag.
    arg: ?[]const u8 = null,
    help: []const u8,
};

pub const Cmd = struct {
    name: []const u8,
    summary: []const u8,
    /// Positional argument spec shown in usage, e.g. "<ip|all> <file>".
    args: []const u8 = "",
    opts: []const Opt = &.{},
};

pub const global_opts = [_]Opt{
    .{ .long = "--help", .short = "-h", .help = "show help" },
};

const config_opt = Opt{ .long = "--config", .arg = "path", .help = "config file (default /etc/hcibridge/config, plus .d drop-ins)" };
const discovery_port_opt = Opt{ .long = "--discovery-port", .arg = "n", .help = "UDP discovery port (default 4445)" };

/// Run flags handled by main.zig rather than the settings schema.
pub const run_extras = [_]Opt{
    .{ .long = "--host", .arg = "addr", .help = "pin one board and disable discovery (sugar)" },
    .{ .long = "--no-discovery", .help = "disable discovery" },
    config_opt,
    .{ .long = "--once", .help = "exit after the first session of a single pinned board" },
};

pub const commands = [_]Cmd{
    .{
        .name = "run",
        .summary = "daemon: attach bridges to the local Bluetooth stack (default)",
    },
    .{
        .name = "list",
        .summary = "discover bridges and print their firmware versions",
        .opts = &.{discovery_port_opt},
    },
    .{
        .name = "status",
        .summary = "print full status of one bridge",
        .args = "<ip>",
    },
    .{
        .name = "claim",
        .summary = "pair with an unclaimed bridge: agree a key and save it to the config",
        .args = "<ip>",
        .opts = &.{config_opt},
    },
    .{
        .name = "revoke",
        .summary = "stop accepting a bridge: remove its key from the config",
        .args = "<bdaddr>",
        .opts = &.{config_opt},
    },
    .{
        .name = "reboot",
        .summary = "reboot a bridge (requires its key)",
        .args = "<ip>",
        .opts = &.{config_opt},
    },
    .{
        .name = "update",
        .summary = "push a firmware image over OTA to one bridge or all (requires keys)",
        .args = "<ip|all> <file>",
        .opts = &.{ discovery_port_opt, config_opt },
    },
    .{
        .name = "completions",
        .summary = "print a shell completion script",
        .args = "<bash|zsh|fish>",
    },
    .{ .name = "man", .summary = "print the man page (roff)" },
    .{ .name = "version", .summary = "print the version" },
    .{ .name = "help", .summary = "show help" },
};

pub const shells = [_][]const u8{ "bash", "zsh", "fish" };

/// Text for a single-quoted zsh or fish string, printed with `{f}`.
const Sq = struct {
    s: []const u8,

    pub fn format(self: Sq, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.s) |c| {
            if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
        }
    }
};

fn sq(s: []const u8) Sq {
    return .{ .s = s };
}

fn descOpt(d: settings.Desc) Opt {
    return .{ .long = d.flag, .arg = d.arg, .help = d.help };
}

// ---------------------------------------------------------------------------
// Help
// ---------------------------------------------------------------------------

pub fn writeHelp(w: *std.Io.Writer) !void {
    try w.print("{s} - {s}\n\nusage: {s} <command> [options]\n\ncommands:\n", .{ program, summary, program });
    for (commands) |c| {
        const spacer = if (c.args.len > 0) " " else "";
        try w.print("  {s}{s}{s}", .{ c.name, spacer, c.args });
        const used = c.name.len + spacer.len + c.args.len;
        var pad: usize = if (used < 24) 24 - used else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}\n", .{c.summary});
    }
    for (commands) |c| {
        if (c.opts.len == 0) continue;
        try w.print("\n{s} options:\n", .{c.name});
        for (c.opts) |o| try writeOptLine(w, o, 22);
    }
    try w.print("\nrun options:\n", .{});
    try settings.writeOptions(w);
    for (run_extras) |o| try writeOptLine(w, o, 26);
    try w.print("\nglobal:\n", .{});
    for (global_opts) |o| try writeOptLine(w, o, 22);
}

fn writeOptLine(w: *std.Io.Writer, o: Opt, width: usize) !void {
    var buf: [48]u8 = undefined;
    const head = if (o.arg) |a|
        std.fmt.bufPrint(&buf, "{s} <{s}>", .{ o.long, a }) catch o.long
    else
        o.long;
    try w.print("  {s}", .{head});
    var pad: usize = if (head.len < width) width - head.len else 1;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}\n", .{o.help});
}

// ---------------------------------------------------------------------------
// man page (roff, section 1)
// ---------------------------------------------------------------------------

fn writeManOpt(w: *std.Io.Writer, o: Opt) !void {
    if (o.arg) |a|
        try w.print(".TP\n.B {s} <{s}>\n{s}\n", .{ o.long, a, o.help })
    else
        try w.print(".TP\n.B {s}\n{s}\n", .{ o.long, o.help });
}

pub fn writeMan(w: *std.Io.Writer) !void {
    try w.print(".TH HCIBRIDGE 1 \"\" \"{s} {s}\" \"User Commands\"\n", .{ program, version });
    try w.print(".SH NAME\n{s} \\- {s}\n", .{ program, summary });
    try w.print(".SH SYNOPSIS\n.B {s}\n.I command\n[options]\n", .{program});
    try w.print(".SH DESCRIPTION\n" ++
        "Finds ESP32 HCI bridges on the LAN by UDP broadcast and attaches each to the local BlueZ stack as its own virtual controller, or pins one with \\fB--host\\fR. Also lists bridges, shows status, and pushes OTA firmware updates.\n", .{});
    try w.print(".SH COMMANDS\n", .{});
    for (commands) |c| {
        const spacer = if (c.args.len > 0) " " else "";
        try w.print(".TP\n.B {s}{s}{s}\n{s}\n", .{ c.name, spacer, c.args, c.summary });
        for (c.opts) |o| {
            try w.writeAll(".RS\n");
            try writeManOpt(w, o);
            try w.writeAll(".RE\n");
        }
    }
    try w.print(".SH RUN OPTIONS\n", .{});
    for (settings.descs) |d| {
        if (d.arg) |ar|
            try w.print(".TP\n.B {s} <{s}>\n{s} (env {s})\n", .{ d.flag, ar, d.help, d.env })
        else
            try w.print(".TP\n.B {s}\n{s} (env {s})\n", .{ d.flag, d.help, d.env });
    }
    for (run_extras) |o| try writeManOpt(w, o);
    try w.print(".SH EXAMPLES\n.TP\n{s} list\ndiscover bridges and show firmware versions\n.TP\n{s} update all firmware.bin\nupdate every discoverable bridge\n", .{ program, program });
    try w.print(".SH SEE ALSO\n.BR bluetoothctl (1)\n", .{});
}

// ---------------------------------------------------------------------------
// completions
// ---------------------------------------------------------------------------

pub fn writeBash(w: *std.Io.Writer) !void {
    try w.print("# bash completion for {s}\n_{s}() {{\n", .{ program, program });
    try w.print("  local cur prev words cword; _init_completion || return\n", .{});
    try w.print("  local cmds=\"", .{});
    for (commands, 0..) |c, i| try w.print("{s}{s}", .{ if (i == 0) "" else " ", c.name });
    try w.print("\"\n", .{});
    try w.print("  if [ $cword -eq 1 ]; then COMPREPLY=( $(compgen -W \"$cmds\" -- \"$cur\") ); return; fi\n", .{});
    try w.print("  case \"${{words[1]}}\" in\n", .{});
    for (commands) |c| {
        if (c.opts.len == 0) continue;
        try w.print("    {s}) COMPREPLY=( $(compgen -W \"", .{c.name});
        for (c.opts, 0..) |o, i| try w.print("{s}{s}", .{ if (i == 0) "" else " ", o.long });
        try w.print("\" -- \"$cur\") );;\n", .{});
    }
    try w.print("    run) COMPREPLY=( $(compgen -W \"", .{});
    for (settings.descs, 0..) |d, i| try w.print("{s}{s}", .{ if (i == 0) "" else " ", d.flag });
    for (run_extras) |o| try w.print(" {s}", .{o.long});
    try w.print("\" -- \"$cur\") );;\n", .{});
    try w.print("    completions) COMPREPLY=( $(compgen -W \"bash zsh fish\" -- \"$cur\") );;\n", .{});
    try w.print("  esac\n}}\ncomplete -F _{s} {s}\n", .{ program, program });
}

fn writeZshSpec(w: *std.Io.Writer, o: Opt) !void {
    if (o.arg) |a|
        try w.print("      '{s}[{f}]:{f}:' \\\n", .{ o.long, sq(o.help), sq(a) })
    else
        try w.print("      '{s}[{f}]' \\\n", .{ o.long, sq(o.help) });
}

pub fn writeZsh(w: *std.Io.Writer) !void {
    try w.print("#compdef {s}\n", .{program});
    try w.print("_{s}() {{\n  local -a cmds\n  cmds=(\n", .{program});
    for (commands) |c| try w.print("    '{s}:{f}'\n", .{ c.name, sq(c.summary) });
    try w.print("  )\n  if (( CURRENT == 2 )); then _describe 'command' cmds; return; fi\n", .{});
    try w.print("  case $words[2] in\n", .{});
    for (commands) |c| {
        if (c.opts.len == 0) continue;
        try w.print("    {s}) _arguments \\\n", .{c.name});
        for (c.opts) |o| try writeZshSpec(w, o);
        try w.print("      ;;\n", .{});
    }
    try w.print("    run) _arguments \\\n", .{});
    for (settings.descs) |d| try writeZshSpec(w, descOpt(d));
    for (run_extras) |o| try writeZshSpec(w, o);
    try w.print("      ;;\n", .{});
    try w.print("    completions) _values shell bash zsh fish;;\n", .{});
    try w.print("  esac\n}}\n_{s} \"$@\"\n", .{program});
}

fn writeFishOpt(w: *std.Io.Writer, cmd: []const u8, o: Opt) !void {
    const long = o.long[2..];
    const req: []const u8 = if (o.arg != null) " -r" else "";
    try w.print("complete -c {s} -n '__fish_seen_subcommand_from {s}' -l {s}{s} -d '{f}'\n", .{ program, cmd, long, req, sq(o.help) });
}

pub fn writeFish(w: *std.Io.Writer) !void {
    try w.print("# fish completion for {s}\n", .{program});
    try w.print("complete -c {s} -f\n", .{program});
    for (commands) |c| {
        try w.print("complete -c {s} -n '__fish_use_subcommand' -a {s} -d '{f}'\n", .{ program, c.name, sq(c.summary) });
    }
    for (commands) |c| {
        for (c.opts) |o| try writeFishOpt(w, c.name, o);
    }
    for (settings.descs) |d| try writeFishOpt(w, "run", descOpt(d));
    for (run_extras) |o| try writeFishOpt(w, "run", o);
    try w.print("complete -c {s} -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'\n", .{program});
}

pub fn writeCompletion(w: *std.Io.Writer, shell: []const u8) !void {
    if (std.mem.eql(u8, shell, "bash")) return writeBash(w);
    if (std.mem.eql(u8, shell, "zsh")) return writeZsh(w);
    if (std.mem.eql(u8, shell, "fish")) return writeFish(w);
    return error.UnknownShell;
}

const testing = std.testing;

const generators = .{ writeHelp, writeMan, writeBash, writeZsh, writeFish };

test "generators produce non-empty output" {
    var buf: [16384]u8 = undefined;
    inline for (generators) |gen| {
        var w = std.Io.Writer.fixed(&buf);
        try gen(&w);
        try testing.expect(w.end > 50);
    }
}

test "every command appears in bash completion" {
    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeBash(&w);
    const out = buf[0..w.end];
    for (commands) |c| try testing.expect(std.mem.indexOf(u8, out, c.name) != null);
}

test "run extras appear in every generator" {
    var buf: [16384]u8 = undefined;
    const cases = .{
        .{ writeHelp, "--once", "--config" },
        .{ writeMan, "--once", "--config" },
        .{ writeBash, "--once", "--config" },
        .{ writeZsh, "--once[", "--config[" },
        .{ writeFish, "-l once", "-l config" },
    };
    inline for (cases) |case| {
        var w = std.Io.Writer.fixed(&buf);
        try case[0](&w);
        const out = buf[0..w.end];
        try testing.expect(std.mem.indexOf(u8, out, case[1]) != null);
        try testing.expect(std.mem.indexOf(u8, out, case[2]) != null);
    }
}

test "single quote escaping" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("'{f}'", .{sq("it's")});
    try testing.expectEqualStrings("'it'\\''s'", buf[0..w.end]);
}

test "help strings carry no apostrophes" {
    for (commands) |c| {
        try testing.expect(std.mem.indexOfScalar(u8, c.summary, '\'') == null);
        for (c.opts) |o| try testing.expect(std.mem.indexOfScalar(u8, o.help, '\'') == null);
    }
    for (settings.descs) |d| try testing.expect(std.mem.indexOfScalar(u8, d.help, '\'') == null);
    for (run_extras) |o| try testing.expect(std.mem.indexOfScalar(u8, o.help, '\'') == null);
}

fn syntaxCheck(shell: []const u8, gen: *const fn (*std.Io.Writer) anyerror!void, name: []const u8) !void {
    const io = testing.io;
    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try gen(&w);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = buf[0..w.end] });
    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, name, &pbuf);
    const res = std.process.run(testing.allocator, io, .{ .argv = &.{ shell, "-n", pbuf[0..n] } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("{s} -n {s} failed:\n{s}\n", .{ shell, name, res.stderr });
    return error.SyntaxCheckFailed;
}

test "bash accepts the generated completion" {
    try syntaxCheck("bash", writeBash, "hcibridge.bash");
}

test "zsh accepts the generated completion" {
    try syntaxCheck("zsh", writeZsh, "_hcibridge");
}

test "fish accepts the generated completion" {
    try syntaxCheck("fish", writeFish, "hcibridge.fish");
}
