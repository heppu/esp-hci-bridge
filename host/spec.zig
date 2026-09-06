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

pub const commands = [_]Cmd{
    .{
        .name = "run",
        .summary = "daemon: attach bridges to the local Bluetooth stack (default)",
    },
    .{
        .name = "list",
        .summary = "discover bridges and print their firmware versions",
        .opts = &.{
            .{ .long = "--discovery-port", .arg = "n", .help = "UDP discovery port (default 4445)" },
        },
    },
    .{
        .name = "status",
        .summary = "print one bridge's full status",
        .args = "<ip>",
    },
    .{
        .name = "update",
        .summary = "push a firmware image over OTA to one bridge or all",
        .args = "<ip|all> <file>",
        .opts = &.{
            .{ .long = "--discovery-port", .arg = "n", .help = "UDP discovery port (default 4445)" },
        },
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
        for (c.opts) |o| try writeOptLine(w, o);
    }
    try w.print("\nrun options:\n", .{});
    try settings.writeOptions(w);
    try w.print("\nglobal:\n", .{});
    for (global_opts) |o| try writeOptLine(w, o);
}

fn writeOptLine(w: *std.Io.Writer, o: Opt) !void {
    var buf: [48]u8 = undefined;
    const head = if (o.arg) |a|
        std.fmt.bufPrint(&buf, "{s} <{s}>", .{ o.long, a }) catch o.long
    else
        o.long;
    try w.print("  {s}", .{head});
    var pad: usize = if (head.len < 22) 22 - head.len else 1;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}\n", .{o.help});
}

// ---------------------------------------------------------------------------
// man page (roff, section 1)
// ---------------------------------------------------------------------------

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
            if (o.arg) |a|
                try w.print(".RS\n.TP\n.B {s} <{s}>\n{s}\n.RE\n", .{ o.long, a, o.help })
            else
                try w.print(".RS\n.TP\n.B {s}\n{s}\n.RE\n", .{ o.long, o.help });
        }
    }
    try w.print(".SH RUN OPTIONS\n", .{});
    for (settings.descs) |d| {
        if (d.arg) |ar|
            try w.print(".TP\n.B {s} <{s}>\n{s} (env {s})\n", .{ d.flag, ar, d.help, d.env })
        else
            try w.print(".TP\n.B {s}\n{s} (env {s})\n", .{ d.flag, d.help, d.env });
    }
    try w.print(".TP\n.B --host <addr>\npin one board and disable discovery\n.TP\n.B --config <path>\nconfig file (default /etc/hcibridge/config; .d drop-ins)\n", .{});
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
    try w.print(" --host --no-discovery --config --once\" -- \"$cur\") );;\n", .{});
    try w.print("    completions) COMPREPLY=( $(compgen -W \"bash zsh fish\" -- \"$cur\") );;\n", .{});
    try w.print("  esac\n}}\ncomplete -F _{s} {s}\n", .{ program, program });
}

pub fn writeZsh(w: *std.Io.Writer) !void {
    try w.print("#compdef {s}\n", .{program});
    try w.print("_{s}() {{\n  local -a cmds\n  cmds=(\n", .{program});
    for (commands) |c| try w.print("    '{s}:{s}'\n", .{ c.name, c.summary });
    try w.print("  )\n  if (( CURRENT == 2 )); then _describe 'command' cmds; return; fi\n", .{});
    try w.print("  case $words[2] in\n", .{});
    for (commands) |c| {
        if (c.opts.len == 0) continue;
        try w.print("    {s}) _arguments \\\n", .{c.name});
        for (c.opts) |o| {
            if (o.arg) |a|
                try w.print("      '{s}[{s}]:{s}:' \\\n", .{ o.long, o.help, a })
            else
                try w.print("      '{s}[{s}]' \\\n", .{ o.long, o.help });
        }
        try w.print("      ;;\n", .{});
    }
    try w.print("    run) _arguments \\\n", .{});
    for (settings.descs) |d| {
        if (d.arg) |ar|
            try w.print("      '{s}[{s}]:{s}:' \\\n", .{ d.flag, d.help, ar })
        else
            try w.print("      '{s}[{s}]' \\\n", .{ d.flag, d.help });
    }
    try w.print("      '--host[pin one board]:addr:' '--no-discovery[disable discovery]' '--config[config file]:path:' '--once[exit after first session]' ;;\n", .{});
    try w.print("    completions) _values shell bash zsh fish;;\n", .{});
    try w.print("  esac\n}}\n_{s} \"$@\"\n", .{program});
}

pub fn writeFish(w: *std.Io.Writer) !void {
    try w.print("# fish completion for {s}\n", .{program});
    try w.print("complete -c {s} -f\n", .{program});
    for (commands) |c| {
        try w.print("complete -c {s} -n '__fish_use_subcommand' -a {s} -d '{s}'\n", .{ program, c.name, c.summary });
    }
    for (commands) |c| {
        for (c.opts) |o| {
            const long = o.long[2..]; // strip --
            if (o.arg != null)
                try w.print("complete -c {s} -n '__fish_seen_subcommand_from {s}' -l {s} -r -d '{s}'\n", .{ program, c.name, long, o.help })
            else
                try w.print("complete -c {s} -n '__fish_seen_subcommand_from {s}' -l {s} -d '{s}'\n", .{ program, c.name, long, o.help });
        }
    }
    for (settings.descs) |d| {
        const long = d.flag[2..];
        if (d.arg != null)
            try w.print("complete -c {s} -n '__fish_seen_subcommand_from run' -l {s} -r -d '{s}'\n", .{ program, long, d.help })
        else
            try w.print("complete -c {s} -n '__fish_seen_subcommand_from run' -l {s} -d '{s}'\n", .{ program, long, d.help });
    }
    try w.print("complete -c {s} -n '__fish_seen_subcommand_from run' -l host -r -d 'pin one board'\n", .{program});
    try w.print("complete -c {s} -n '__fish_seen_subcommand_from run' -l no-discovery -d 'disable discovery'\n", .{program});
    try w.print("complete -c {s} -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'\n", .{program});
}

pub fn writeCompletion(w: *std.Io.Writer, shell: []const u8) !void {
    if (std.mem.eql(u8, shell, "bash")) return writeBash(w);
    if (std.mem.eql(u8, shell, "zsh")) return writeZsh(w);
    if (std.mem.eql(u8, shell, "fish")) return writeFish(w);
    return error.UnknownShell;
}

const testing = std.testing;

test "generators produce non-empty output" {
    var buf: [8192]u8 = undefined;
    inline for (.{ writeHelp, writeMan, writeBash, writeZsh, writeFish }) |gen| {
        var w = std.Io.Writer.fixed(&buf);
        try gen(&w);
        try testing.expect(w.end > 50);
    }
}

test "every command appears in bash completion" {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeBash(&w);
    const out = buf[0..w.end];
    for (commands) |c| try testing.expect(std.mem.indexOf(u8, out, c.name) != null);
}
