//! Registers a config's daemon with the user's service manager, launchd on
//! macOS or systemd on Linux, so it starts at login and restarts after a crash
//! but stays down after `croner stop`, which exits cleanly.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const manager = if (builtin.os.tag == .macos) "launchctl" else "systemctl";

/// What the service manager runs for one config.
pub const Service = struct {
    /// The launchd label or systemd unit name.
    name: []const u8,
    executable: []const u8,
    config_path: []const u8,
    working_directory: []const u8,
    /// Variables the enabling shell had, such as PATH, so the daemon and its
    /// jobs see the same programs, state directory and zone database at login.
    environment: []const EnvVar,
};

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// A config's unit name and the file that defines it.
pub const Unit = struct {
    allocator: Allocator,
    name: []const u8,
    path: []const u8,

    pub fn init(allocator: Allocator, environ: *const std.process.Environ.Map, state_key: []const u8) !Unit {
        const home = environ.get("HOME") orelse return error.HomeNotFound;
        const name = if (builtin.os.tag == .macos)
            try std.fmt.allocPrint(allocator, "com.xcaeser.croner.{s}", .{state_key})
        else
            try std.fmt.allocPrint(allocator, "croner-{s}.service", .{state_key});
        errdefer allocator.free(name);
        const path = if (builtin.os.tag == .macos)
            try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}.plist", .{ home, name })
        else if (environ.get("XDG_CONFIG_HOME")) |config_home|
            try std.fmt.allocPrint(allocator, "{s}/systemd/user/{s}", .{ config_home, name })
        else
            try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user/{s}", .{ home, name });
        return .{ .allocator = allocator, .name = name, .path = path };
    }

    pub fn deinit(self: *Unit) void {
        self.allocator.free(self.name);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn installed(self: *const Unit, io: Io) !bool {
        Io.Dir.cwd().access(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Stops a loaded instance, if any, so a new definition can take its place.
    pub fn unload(self: *const Unit, allocator: Allocator, io: Io) !void {
        if (builtin.os.tag == .macos) {
            const target = try launchdTarget(allocator, self.name);
            defer allocator.free(target);
            _ = try run(io, &.{ "launchctl", "bootout", target }, .quiet);
        } else {
            _ = try run(io, &.{ "systemctl", "--user", "stop", self.name }, .quiet);
        }
    }

    /// Writes the definition and starts the daemon under the service manager.
    pub fn install(self: *const Unit, allocator: Allocator, io: Io, text: []const u8) !void {
        var file = try Io.Dir.cwd().createFileAtomic(io, self.path, .{
            .permissions = .fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, text);
        try file.file.sync(io);
        try file.replace(io);
        if (builtin.os.tag == .macos) {
            const domain = try launchdTarget(allocator, null);
            defer allocator.free(domain);
            try runChecked(io, &.{ "launchctl", "bootstrap", domain, self.path });
        } else {
            try runChecked(io, &.{ "systemctl", "--user", "daemon-reload" });
            try runChecked(io, &.{ "systemctl", "--user", "enable", self.name });
            try runChecked(io, &.{ "systemctl", "--user", "restart", self.name });
        }
    }

    /// Stops the daemon, unregisters it and deletes the definition. A unit
    /// that was not loaded is not an error.
    pub fn remove(self: *const Unit, allocator: Allocator, io: Io) !void {
        if (builtin.os.tag == .macos) {
            try self.unload(allocator, io);
            try Io.Dir.cwd().deleteFile(io, self.path);
        } else {
            _ = try run(io, &.{ "systemctl", "--user", "disable", "--now", self.name }, .loud);
            try Io.Dir.cwd().deleteFile(io, self.path);
            _ = try run(io, &.{ "systemctl", "--user", "daemon-reload" }, .loud);
        }
    }

    pub fn start(self: *const Unit, allocator: Allocator, io: Io) !void {
        if (builtin.os.tag == .macos) {
            const target = try launchdTarget(allocator, self.name);
            defer allocator.free(target);
            try runChecked(io, &.{ "launchctl", "kickstart", target });
        } else {
            try runChecked(io, &.{ "systemctl", "--user", "start", self.name });
        }
    }
};

/// `gui/<uid>`, or `gui/<uid>/<label>` for one service.
fn launchdTarget(allocator: Allocator, label: ?[]const u8) ![]u8 {
    const uid = std.posix.system.getuid();
    return if (label) |name|
        std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, name })
    else
        std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
}

fn run(io: Io, argv: []const []const u8, output: enum { quiet, loud }) !bool {
    const stdio: std.process.SpawnOptions.StdIo = if (output == .quiet) .ignore else .inherit;
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = stdio, .stderr = stdio });
    return (try child.wait(io)).success();
}

/// Runs a service manager command whose own message explains a failure.
fn runChecked(io: Io, argv: []const []const u8) !void {
    if (!try run(io, argv, .loud)) return error.ServiceManagerFailed;
}

/// The installer's stable copy when present, so upgrades keep the unit valid.
pub fn executablePath(allocator: Allocator, io: Io, croner_home: []const u8) ![:0]u8 {
    const installed_path = try std.fs.path.joinZ(allocator, &.{ croner_home, "bin", "croner" });
    Io.Dir.cwd().access(io, installed_path, .{}) catch {
        allocator.free(installed_path);
        return std.process.executablePathAlloc(io, allocator);
    };
    return installed_path;
}

/// The launchd plist on macOS, the systemd unit elsewhere.
pub fn render(allocator: Allocator, service: Service) ![]u8 {
    var text = Io.Writer.Allocating.init(allocator);
    errdefer text.deinit();
    if (builtin.os.tag == .macos) try writePlist(&text.writer, service) else try writeSystemdUnit(&text.writer, service);
    return text.toOwnedSlice();
}

fn writePlist(writer: *Io.Writer, service: Service) Io.Writer.Error!void {
    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{f}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{f}</string>
        \\    <string>_serve</string>
        \\    <string>{f}</string>
        \\  </array>
        \\  <key>WorkingDirectory</key>
        \\  <string>{f}</string>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\
    , .{
        Xml{ .text = service.name },
        Xml{ .text = service.executable },
        Xml{ .text = service.config_path },
        Xml{ .text = service.working_directory },
    });
    for (service.environment) |variable| try writer.print(
        \\    <key>{f}</key>
        \\    <string>{f}</string>
        \\
    , .{ Xml{ .text = variable.name }, Xml{ .text = variable.value } });
    try writer.writeAll(
        \\  </dict>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <dict>
        \\    <key>SuccessfulExit</key>
        \\    <false/>
        \\  </dict>
        \\</dict>
        \\</plist>
        \\
    );
}

fn writeSystemdUnit(writer: *Io.Writer, service: Service) Io.Writer.Error!void {
    try writer.print(
        \\[Unit]
        \\Description=Croner jobs in {f}
        \\
        \\[Service]
        \\ExecStart="{f}" _serve "{f}"
        \\WorkingDirectory={f}
        \\
    , .{
        Systemd{ .text = service.config_path, .context = .plain },
        Systemd{ .text = service.executable, .context = .exec },
        Systemd{ .text = service.config_path, .context = .exec },
        Systemd{ .text = service.working_directory, .context = .plain },
    });
    for (service.environment) |variable| try writer.print("Environment=\"{f}={f}\"\n", .{
        Systemd{ .text = variable.name, .context = .quoted },
        Systemd{ .text = variable.value, .context = .quoted },
    });
    try writer.writeAll(
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    );
}

const Xml = struct {
    text: []const u8,

    pub fn format(self: Xml, writer: *Io.Writer) Io.Writer.Error!void {
        for (self.text) |c| switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        };
    }
};

/// Escapes text for a systemd unit: `%` starts a specifier everywhere, quoted
/// values take C escapes, and ExecStart also expands `$`.
const Systemd = struct {
    text: []const u8,
    context: enum { plain, quoted, exec },

    pub fn format(self: Systemd, writer: *Io.Writer) Io.Writer.Error!void {
        for (self.text) |c| switch (c) {
            '%' => try writer.writeAll("%%"),
            '"', '\\' => if (self.context == .plain) try writer.writeByte(c) else try writer.print("\\{c}", .{c}),
            '$' => try writer.writeAll(if (self.context == .exec) "$$" else "$"),
            else => try writer.writeByte(c),
        };
    }
};

const test_service: Service = .{
    .name = "com.xcaeser.croner.1f",
    .executable = "/Users/me/.croner/bin/croner",
    .config_path = "/Users/me/R&D/100%/croner.json",
    .working_directory = "/Users/me/R&D/100%",
    .environment = &.{
        .{ .name = "CRONER_HOME", .value = "/Users/me/.croner" },
        .{ .name = "PATH", .value = "/opt/$bin:/usr/bin" },
    },
};

test "launchd plist runs the daemon at login and restarts it only after a crash" {
    var text: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writePlist(&text.writer, test_service);
    const plist = text.written();
    const expected_parts = [_][]const u8{
        "<key>Label</key>\n  <string>com.xcaeser.croner.1f</string>",
        "<string>/Users/me/.croner/bin/croner</string>\n    <string>_serve</string>\n    <string>/Users/me/R&amp;D/100%/croner.json</string>",
        "<key>WorkingDirectory</key>\n  <string>/Users/me/R&amp;D/100%</string>",
        "<key>CRONER_HOME</key>\n    <string>/Users/me/.croner</string>",
        "<key>PATH</key>\n    <string>/opt/$bin:/usr/bin</string>",
        "<key>RunAtLoad</key>\n  <true/>",
        "<key>KeepAlive</key>\n  <dict>\n    <key>SuccessfulExit</key>\n    <false/>\n  </dict>",
    };
    for (expected_parts) |part| {
        if (std.mem.indexOf(u8, plist, part) == null) {
            std.debug.print("missing from plist:\n{s}\n--- plist:\n{s}\n", .{ part, plist });
            return error.TestExpectedEqual;
        }
    }
}

test "systemd unit escapes paths and restarts only on failure" {
    var text: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    var service = test_service;
    service.name = "croner-1f.service";
    try writeSystemdUnit(&text.writer, service);
    try std.testing.expectEqualStrings(
        \\[Unit]
        \\Description=Croner jobs in /Users/me/R&D/100%%/croner.json
        \\
        \\[Service]
        \\ExecStart="/Users/me/.croner/bin/croner" _serve "/Users/me/R&D/100%%/croner.json"
        \\WorkingDirectory=/Users/me/R&D/100%%
        \\Environment="CRONER_HOME=/Users/me/.croner"
        \\Environment="PATH=/opt/$bin:/usr/bin"
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , text.written());
}
