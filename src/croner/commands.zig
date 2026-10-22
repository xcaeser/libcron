//! The `croner` subcommands.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const zli = @import("zli");

const config = @import("config.zig");
const LoadedSpecs = config.LoadedSpecs;
const JobSpec = config.JobSpec;
const protocol = @import("protocol.zig");
const Request = protocol.Request;
const Response = protocol.Response;
const Status = protocol.Status;
const state_paths = @import("state.zig");
const StatePaths = state_paths.StatePaths;
const log = @import("log.zig");
const supervisor = @import("supervisor.zig");

pub const App = struct {
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
};

fn appFor(ctx: zli.CommandContext) *App {
    return ctx.getContextData(App);
}

/// Prints a sentence for the user; `main` then exits with status 1 without repeating it.
fn fail(ctx: zli.CommandContext, comptime format: []const u8, args: anytype) error{Reported} {
    ctx.writer.print("error: " ++ format ++ "\n", args) catch {};
    return error.Reported;
}

fn openState(ctx: zli.CommandContext, config_path: []const u8) !StatePaths {
    const app = appFor(ctx);
    return StatePaths.init(app.allocator, app.io, app.environ, config_path) catch |err| switch (err) {
        error.HomeNotFound => fail(ctx, "HOME is not set; set HOME or CRONER_HOME", .{}),
        error.CronerHomeNotAbsolute => fail(ctx, "CRONER_HOME must be an absolute path", .{}),
        error.NameTooLong => fail(ctx, "the daemon socket path would exceed {d} bytes; set CRONER_HOME to a shorter directory", .{state_paths.unix_socket_path_max}),
        else => err,
    };
}

fn loadConfigOrFail(ctx: zli.CommandContext, absolute_path: []const u8) !LoadedSpecs {
    const app = appFor(ctx);
    var problem_buffer: [1024]u8 = undefined;
    var problem: Io.Writer = .fixed(&problem_buffer);
    return config.loadConfig(app.allocator, app.io, absolute_path, &problem) catch |err| switch (err) {
        error.InvalidConfig => fail(ctx, "{s}", .{problem.buffered()}),
        else => err,
    };
}

fn sendToDaemon(ctx: zli.CommandContext, message: Request) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    var state = try openState(ctx, config_path);
    defer state.deinit();
    var response = protocol.request(app.allocator, app.io, &state, message) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return fail(ctx, "croner is not running for {s}", .{config_path}),
        else => return err,
    };
    defer response.deinit();
    try printResponse(ctx, &response);
}

fn printResponse(ctx: zli.CommandContext, parsed: *const std.json.Parsed(Response)) !void {
    switch (parsed.value) {
        .pid => return error.InvalidResponse,
        .ok => |message| try ctx.writer.print("{s}\n", .{message}),
        .@"error" => |message| return fail(ctx, "{s}", .{message}),
        .jobs => |jobs| {
            try ctx.writer.print("ID\tSTATUS\tSCHEDULE\n", .{});
            for (jobs) |job| try ctx.writer.print("{s}\t{t}\t{s}\n", .{ job.id, job.status, job.schedule });
        },
    }
}

fn commandSetup(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    const existing = Io.Dir.cwd().openFile(app.io, config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| {
        file.close(app.io);
        return fail(ctx, "{s} already exists; edit it, or pass --config to create another", .{config_path});
    }

    const id = try prompt(ctx, "Job id: ");
    const schedule = try prompt(ctx, "Schedule: ");
    const argv_text = try prompt(ctx, "Command argv (JSON array): ");
    defer app.allocator.free(id);
    defer app.allocator.free(schedule);
    defer app.allocator.free(argv_text);
    var argv_parsed = std.json.parseFromSlice([]const []const u8, app.allocator, argv_text, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(ctx, "argv must be a JSON array of strings, for example [\"bun\", \"run\", \"sync\"]", .{}),
    };
    defer argv_parsed.deinit();
    const command = config.CommandJson{ .argv = argv_parsed.value };
    const job = config.JobJson{ .id = id, .schedule = schedule, .action = .{ .command = command } };
    const document = config.ConfigJson{ .@"$schema" = config.schema_url, .jobs = &.{job} };
    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    var problem_buffer: [1024]u8 = undefined;
    var problem: Io.Writer = .fixed(&problem_buffer);
    var checked = JobSpec.init(app.allocator, app.io, job, config_dir, &problem) catch |err| switch (err) {
        error.InvalidConfig => return fail(ctx, "{s}", .{problem.buffered()}),
        else => return err,
    };
    checked.deinit();
    const bytes = try protocol.jsonWrite(config.ConfigJson, document, app.allocator);
    defer app.allocator.free(bytes);
    try Io.Dir.cwd().writeFile(app.io, .{
        .sub_path = config_path,
        .data = bytes,
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
    });
    try ctx.writer.print("created {s}\n", .{config_path});
}

fn prompt(ctx: zli.CommandContext, text: []const u8) ![]const u8 {
    try ctx.writer.print("{s}", .{text});
    try ctx.writer.flush();
    const line = ctx.reader.takeDelimiterInclusive('\n') catch return error.InvalidInput;
    var end = line.len;
    while (end > 0 and (line[end - 1] == '\n' or line[end - 1] == '\r')) end -= 1;
    return ctx.allocator.dupe(u8, line[0..end]);
}

fn commandStart(ctx: zli.CommandContext) !void {
    if (ctx.getArg("id")) |id| return sendToDaemon(ctx, .{ .start = id });
    try startBackground(ctx);
}

fn commandStop(ctx: zli.CommandContext) !void {
    try sendToDaemon(ctx, if (ctx.getArg("id")) |id| .{ .stop = id } else .shutdown);
}

fn commandReload(ctx: zli.CommandContext) !void {
    try sendToDaemon(ctx, .reload);
}

fn commandList(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    var state = try openState(ctx, config_path);
    defer state.deinit();
    var response = protocol.request(app.allocator, app.io, &state, .list) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return printOffline(ctx, config_path),
        else => return err,
    };
    defer response.deinit();
    try printResponse(ctx, &response);
}

fn printOffline(ctx: zli.CommandContext, config_path: []const u8) !void {
    const app = appFor(ctx);
    const absolute = try config.resolveFromCwd(app.allocator, app.io, config_path);
    defer app.allocator.free(absolute);
    var specs = try loadConfigOrFail(ctx, absolute);
    defer specs.deinit();
    try ctx.writer.print("ID\tSTATUS\tSCHEDULE\n", .{});
    for (specs.items.items) |spec| try ctx.writer.print("{s}\t{t}\t{s}\n", .{ spec.id, Status.offline, spec.schedule });
}

fn commandLogs(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    var state = try openState(ctx, ctx.flag("config", []const u8));
    defer state.deinit();
    const line_count = ctx.flag("lines", i32);
    if (line_count < 0) return fail(ctx, "--lines must be zero or more", .{});
    const lines: usize = @intCast(line_count);
    var offset = try log.printLog(app.io, ctx.writer, state.log, lines);
    if (ctx.flag("follow", bool)) {
        while (true) {
            try Io.sleep(app.io, .fromMilliseconds(250), .awake);
            offset = try log.appendLog(app.io, ctx.writer, state.log, offset);
        }
    }
}

fn startBackground(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    const absolute = try config.resolveFromCwd(app.allocator, app.io, config_path);
    defer app.allocator.free(absolute);
    const dir = std.fs.path.dirname(absolute) orelse ".";
    var specs = try loadConfigOrFail(ctx, absolute);
    specs.deinit();
    var state = try openState(ctx, absolute);
    defer state.deinit();
    if (try protocol.daemonSocketAvailable(app.io, &state)) return fail(ctx, "croner is already running for {s}", .{config_path});
    var unit = try openUnit(ctx, &state);
    defer unit.deinit();
    if (try unit.installed(app.io)) {
        // The service manager stays the daemon's parent, so it can restart it after a crash.
        unit.start(app.allocator, app.io) catch |err| switch (err) {
            error.ServiceManagerFailed => return fail(ctx, "{s} could not start {s}; run `croner enable` again", .{ supervisor.manager, unit.name }),
            else => return err,
        };
        if (!try awaitDaemon(app.io, &state)) return fail(ctx, "the daemon did not answer within 5 seconds; see {s}", .{state.log});
        try ctx.writer.print("started\nlog: {s}\n", .{state.log});
        return;
    }

    const executable = try std.process.executablePathAlloc(app.io, app.allocator);
    defer app.allocator.free(executable);
    const argv = [_][]const u8{ executable, "_serve", absolute };
    var child = try std.process.spawn(app.io, .{
        .argv = &argv,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        // Failures before the daemon opens its log reach the user.
        .stderr = .inherit,
    });
    var started = false;
    var child_owned = true;
    errdefer if (!started and child_owned) child.kill(app.io);
    // The CLI is POSIX-only and this child owns no pipe handles. Waiting on a
    // copy keeps the original PID available for cleanup after cancellation.
    var wait_child = child;
    const StartEvent = union(enum) {
        ready: anyerror!void,
        child: anyerror!std.process.Child.Term,
        timeout: anyerror!void,
    };
    var events: [3]StartEvent = undefined;
    var select: Io.Select(StartEvent) = .init(app.io, &events);
    try select.concurrent(.ready, waitForDaemon, .{
        app.allocator,
        app.io,
        &state,
        @as(u64, @intCast(child.id.?)),
    });
    defer {
        if (started) {
            select.cancelDiscard();
        } else {
            while (select.cancel()) |event| switch (event) {
                .child => |result| if (result) |_| {
                    child_owned = false;
                } else |_| {},
                else => {},
            };
        }
    }
    try select.concurrent(.child, std.process.Child.wait, .{ &wait_child, app.io });
    try select.concurrent(.timeout, Io.sleep, .{ app.io, protocol.control_io_timeout.raw, protocol.control_io_timeout.clock });
    switch (try select.await()) {
        .ready => |result| {
            result catch |err| switch (err) {
                error.AlreadyRunning => return fail(ctx, "croner is already running for {s}", .{config_path}),
                else => return err,
            };
            started = true;
        },
        .child => |result| {
            _ = try result;
            child_owned = false;
            return fail(ctx, "the daemon exited while starting; see {s}", .{state.log});
        },
        .timeout => |result| {
            try result;
            return fail(ctx, "the daemon did not answer within 5 seconds; see {s}", .{state.log});
        },
    }
    try ctx.writer.print("started\nlog: {s}\n", .{state.log});
}

fn addCommand(root: *zli.Command, init: zli.InitOptions, name: []const u8, description: []const u8, execute: anytype) !*zli.Command {
    const command = try zli.Command.init(init, .{ .name = name, .description = description }, execute);
    try root.addCommand(command);
    return command;
}

fn openUnit(ctx: zli.CommandContext, state: *const StatePaths) !supervisor.Unit {
    const app = appFor(ctx);
    return supervisor.Unit.init(app.allocator, app.environ, state.key) catch |err| switch (err) {
        error.HomeNotFound => fail(ctx, "HOME is not set", .{}),
        else => err,
    };
}

/// Waits up to 5 seconds for the daemon to accept connections.
fn awaitDaemon(io: Io, state: *const StatePaths) !bool {
    for (0..200) |_| {
        if (try protocol.daemonSocketAvailable(io, state)) return true;
        try Io.sleep(io, .fromMilliseconds(25), .awake);
    }
    return false;
}

fn commandEnable(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    const absolute = try config.resolveFromCwd(app.allocator, app.io, config_path);
    defer app.allocator.free(absolute);
    var specs = try loadConfigOrFail(ctx, absolute);
    specs.deinit();
    var state = try openState(ctx, absolute);
    defer state.deinit();
    // launchd opens the log before the daemon runs.
    try state.ensure(app.io);
    var unit = try openUnit(ctx, &state);
    defer unit.deinit();
    const executable = try supervisor.executablePath(app.allocator, app.io, state.home);
    defer app.allocator.free(executable);
    const text = try supervisor.render(app.allocator, .{
        .name = unit.name,
        .executable = executable,
        .config_path = absolute,
        .working_directory = std.fs.path.dirname(absolute) orelse "/",
        .log_path = state.log,
        .croner_home = state.home,
        .path_env = app.environ.get("PATH"),
    });
    defer app.allocator.free(text);

    unit.unload(app.allocator, app.io) catch |err| switch (err) {
        error.FileNotFound => return fail(ctx, "{s} was not found; croner enable needs it", .{supervisor.manager}),
        else => return err,
    };
    // A daemon started by `croner start` hands over to the service manager.
    if (try protocol.daemonSocketAvailable(app.io, &state)) {
        var response = try protocol.request(app.allocator, app.io, &state, .shutdown);
        response.deinit();
    }
    state_paths.waitForUnlock(app.io, &state) catch |err| switch (err) {
        error.Timeout => return fail(ctx, "the running daemon did not stop within 5 seconds", .{}),
        else => return err,
    };
    unit.install(app.allocator, app.io, text) catch |err| switch (err) {
        error.ServiceManagerFailed => return fail(ctx, "{s} could not load {s}; see its message above", .{ supervisor.manager, unit.path }),
        else => return err,
    };
    if (!try awaitDaemon(app.io, &state))
        return fail(ctx, "enabled {s}, but the daemon did not answer within 5 seconds; see {s}", .{ unit.path, state.log });
    try ctx.writer.print("enabled {s}\nlog: {s}\n", .{ unit.path, state.log });
    if (builtin.os.tag == .linux)
        try ctx.writer.print("to keep jobs running while you are logged out: loginctl enable-linger\n", .{});
}

fn commandDisable(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    var state = try openState(ctx, config_path);
    defer state.deinit();
    var unit = try openUnit(ctx, &state);
    defer unit.deinit();
    if (!try unit.installed(app.io)) {
        try ctx.writer.print("croner is not enabled for {s}\n", .{config_path});
        return;
    }
    try unit.remove(app.allocator, app.io);
    try ctx.writer.print("disabled and stopped; removed {s}\n", .{unit.path});
}

pub fn buildCli(init: zli.InitOptions) !*zli.Command {
    const root = try zli.Command.init(init, .{
        .name = "croner",
        .description = "Cron jobs for Zig projects",
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    }, commandHelp);
    errdefer root.deinit();
    try root.addFlag(.{
        .name = "config",
        .description = "Configuration file",
        .type = .String,
        .default_value = .{ .String = "./croner.json" },
        .persistent = true,
    });

    _ = try addCommand(root, init, "setup", "Create a croner.json file", commandSetup);
    const start = try addCommand(root, init, "start", "Start the daemon or resume a job", commandStart);
    try start.addPositionalArg(.{ .name = "id", .description = "Job id", .required = false });
    const stop = try addCommand(root, init, "stop", "Stop the daemon or pause a job", commandStop);
    try stop.addPositionalArg(.{ .name = "id", .description = "Job id", .required = false });
    _ = try addCommand(root, init, "list", "List configured jobs", commandList);
    _ = try addCommand(root, init, "reload", "Reload the configuration", commandReload);
    _ = try addCommand(root, init, "enable", "Start the daemon at login and after a crash", commandEnable);
    _ = try addCommand(root, init, "disable", "Undo enable and stop the daemon", commandDisable);
    _ = try addCommand(root, init, "version", "Print the version", commandVersion);
    const logs = try addCommand(root, init, "logs", "Show daemon logs", commandLogs);
    try logs.addFlag(.{ .name = "lines", .description = "Number of lines", .type = .Int, .default_value = .{ .Int = 100 } });
    try logs.addFlag(.{ .name = "follow", .description = "Follow appended logs", .type = .Bool, .default_value = .{ .Bool = false } });
    return root;
}

pub fn normalizedArgVector(allocator: Allocator, args: []const [:0]const u8) ![][*:0]const u8 {
    const vector = try allocator.alloc([*:0]const u8, args.len);
    for (args, vector) |arg, *item| item.* = arg.ptr;

    // zli discovers a subcommand only before the first flag.
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--config") and args[3].len > 0 and args[3][0] != '-') {
        vector[1] = args[3].ptr;
        vector[2] = args[1].ptr;
        vector[3] = args[2].ptr;
    } else if (args.len >= 3 and std.mem.startsWith(u8, args[1], "--config=") and args[2].len > 0 and args[2][0] != '-') {
        vector[1] = args[2].ptr;
        vector[2] = args[1].ptr;
    }
    return vector;
}

fn commandHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn commandVersion(ctx: zli.CommandContext) !void {
    try ctx.root.printVersion();
}

fn waitForDaemon(allocator: Allocator, io: Io, state: *const StatePaths, child_pid: u64) !void {
    while (true) {
        var response = protocol.request(allocator, io, state, .ping) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try Io.sleep(io, .fromMilliseconds(25), .awake);
            continue;
        };
        const daemon_pid = switch (response.value) {
            .pid => |pid| pid,
            else => {
                response.deinit();
                return error.InvalidResponse;
            },
        };
        response.deinit();
        if (daemon_pid != child_pid) return error.AlreadyRunning;
        return;
    }
}

test "config flag may precede the subcommand" {
    const separate = [_][:0]const u8{ "croner", "--config", "project.json", "list" };
    const separate_vector = try normalizedArgVector(std.testing.allocator, &separate);
    defer std.testing.allocator.free(separate_vector);
    const expected_separate = [_][]const u8{ "croner", "list", "--config", "project.json" };
    for (expected_separate, separate_vector) |expected, actual|
        try std.testing.expectEqualStrings(expected, std.mem.span(actual));

    const joined = [_][:0]const u8{ "croner", "--config=project.json", "start", "sync" };
    const joined_vector = try normalizedArgVector(std.testing.allocator, &joined);
    defer std.testing.allocator.free(joined_vector);
    const expected_joined = [_][]const u8{ "croner", "start", "--config=project.json", "sync" };
    for (expected_joined, joined_vector) |expected, actual|
        try std.testing.expectEqualStrings(expected, std.mem.span(actual));
}
