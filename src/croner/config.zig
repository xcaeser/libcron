//! croner.json: parsing, validation and the job specs built from it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const libcron = @import("libcron");

pub const schema_url = "https://xcaeser.github.io/croner/croner.schema.json";
const max_config_bytes = 1024 * 1024;

const EnvJson = std.json.ArrayHashMap([]const u8);

pub const CommandJson = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?EnvJson = null,
};

const ActionJson = struct {
    command: CommandJson,
};

pub const JobJson = struct {
    id: []const u8,
    schedule: []const u8,
    action: ActionJson,
    overlap: libcron.OverlapPolicy = .skip,
    time_zone: ?[]const u8 = null,
};

pub const ConfigJson = struct {
    @"$schema": ?[]const u8 = null,
    jobs: []const JobJson,
};

const EnvPair = struct { key: []const u8, value: []const u8 };

pub const JobSpec = struct {
    arena: ?std.heap.ArenaAllocator,
    id: []const u8,
    schedule: []const u8,
    expression: libcron.Expression,
    argv: []const []const u8,
    cwd: []const u8,
    env: []const EnvPair,
    overlap: libcron.OverlapPolicy,
    /// The IANA name as written; `null` means UTC.
    time_zone_name: ?[]const u8,
    /// Loaded into the spec's arena, so it lives exactly as long as the spec.
    time_zone: libcron.TimeZone,

    /// On `error.InvalidConfig`, `problem` says which job and field are wrong.
    /// `environ` may point `TZDIR` at the zone database.
    pub fn init(
        gpa: Allocator,
        io: Io,
        environ: ?*const std.process.Environ.Map,
        job: JobJson,
        config_dir: []const u8,
        problem: *Io.Writer,
    ) !JobSpec {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        if (job.id.len == 0 or std.mem.indexOfScalar(u8, job.id, 0) != null)
            return reject(problem, "every job needs a nonempty id without NUL bytes", .{});
        const schedule = try a.dupe(u8, job.schedule);
        var diagnostics: libcron.Diagnostics = .{};
        // The library's messages name the field, as in `hour values must be within 0-23`.
        const expression = libcron.Expression.parseWithDiagnostics(schedule, &diagnostics) catch
            return reject(problem, "job \"{s}\": schedule \"{s}\": {s}", .{ job.id, job.schedule, diagnostics.message });
        const command = job.action.command;
        const argv = try a.alloc([]const u8, command.argv.len);
        for (command.argv, argv) |arg, *copy| copy.* = try a.dupe(u8, arg);
        const cwd = try std.fs.path.resolve(a, &.{ config_dir, command.cwd orelse "." });

        const runnable: libcron.Command = .{ .argv = argv, .cwd = .{ .path = cwd } };
        runnable.validate() catch return reject(
            problem,
            "job \"{s}\": action.command.argv needs a nonempty first element, and argv and cwd may not contain NUL bytes",
            .{job.id},
        );

        const env_len = if (command.env) |env| env.map.count() else 0;
        const env = try a.alloc(EnvPair, env_len);
        if (command.env) |json_env| {
            var it = json_env.map.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                const key = entry.key_ptr.*;
                if (!validEnvName(key)) return reject(
                    problem,
                    "job \"{s}\": env name \"{s}\" must be letters, digits and underscores, not starting with a digit",
                    .{ job.id, key },
                );
                if (std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) != null)
                    return reject(problem, "job \"{s}\": env value of {s} contains a NUL byte", .{ job.id, key });
                env[i] = .{ .key = try a.dupe(u8, key), .value = try a.dupe(u8, entry.value_ptr.*) };
            }
        }
        std.sort.insertion(EnvPair, env, {}, struct {
            fn lessThan(_: void, lhs: EnvPair, rhs: EnvPair) bool {
                return std.mem.order(u8, lhs.key, rhs.key) == .lt;
            }
        }.lessThan);
        const time_zone_name = if (job.time_zone) |name| try a.dupe(u8, name) else null;
        const time_zone: libcron.TimeZone = if (time_zone_name) |name|
            libcron.TimeZone.load(io, a, environ, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound, error.InvalidTimeZoneName, error.IsDir, error.NotDir => {
                    if (if (environ) |map| map.get("TZDIR") else null) |tzdir| return reject(
                        problem,
                        "job \"{s}\": time_zone \"{s}\" is not in the zone database at TZDIR ({s})",
                        .{ job.id, name, tzdir },
                    );
                    return reject(
                        problem,
                        "job \"{s}\": time_zone \"{s}\" is not an IANA time zone name such as Europe/Paris",
                        .{ job.id, name },
                    );
                },
                else => return reject(problem, "job \"{s}\": time_zone \"{s}\" could not be loaded: {t}", .{ job.id, name, err }),
            }
        else
            .utc;
        const id = try a.dupe(u8, job.id);

        return .{
            .arena = arena,
            .id = id,
            .schedule = schedule,
            .expression = expression,
            .argv = argv,
            .cwd = cwd,
            .env = env,
            .overlap = job.overlap,
            .time_zone_name = time_zone_name,
            .time_zone = time_zone,
        };
    }

    pub fn deinit(self: *JobSpec) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }

    pub fn eql(lhs: *const JobSpec, rhs: *const JobSpec) bool {
        if (!std.mem.eql(u8, lhs.schedule, rhs.schedule) or
            !std.mem.eql(u8, lhs.cwd, rhs.cwd) or lhs.overlap != rhs.overlap or
            lhs.argv.len != rhs.argv.len or lhs.env.len != rhs.env.len) return false;
        if (!std.mem.eql(u8, lhs.time_zone_name orelse "", rhs.time_zone_name orelse "")) return false;
        for (lhs.argv, rhs.argv) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        for (lhs.env, rhs.env) |a, b| {
            if (!std.mem.eql(u8, a.key, b.key) or !std.mem.eql(u8, a.value, b.value)) return false;
        }
        return true;
    }

    pub fn move(self: *JobSpec) JobSpec {
        const result = self.*;
        self.arena = null;
        return result;
    }
};

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub const LoadedSpecs = struct {
    allocator: Allocator,
    items: std.ArrayList(JobSpec),

    pub fn deinit(self: *LoadedSpecs) void {
        for (self.items.items) |*item| item.deinit();
        self.items.deinit(self.allocator);
    }
};

/// Writes why the config was rejected and returns `error.InvalidConfig`.
fn reject(problem: *Io.Writer, comptime format: []const u8, args: anytype) error{InvalidConfig} {
    problem.print(format, args) catch {};
    return error.InvalidConfig;
}

fn jsonProblem(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownField => "unknown field",
        error.MissingField => "missing required field",
        error.DuplicateField => "duplicate field",
        error.InvalidEnumTag => "unknown value",
        error.UnexpectedToken => "value has the wrong type",
        else => "invalid JSON",
    };
}

fn parseConfig(
    allocator: Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    bytes: []const u8,
    config_dir: []const u8,
    problem: *Io.Writer,
) !LoadedSpecs {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    var parsed = std.json.parseFromTokenSource(ConfigJson, allocator, &scanner, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return reject(problem, "line {d}, column {d}: {s}", .{
            diagnostics.getLine(),
            diagnostics.getColumn(),
            jsonProblem(err),
        }),
    };
    defer parsed.deinit();

    var result: LoadedSpecs = .{ .allocator = allocator, .items = .empty };
    errdefer result.deinit();
    try result.items.ensureTotalCapacity(allocator, parsed.value.jobs.len);
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    try ids.ensureTotalCapacity(@intCast(parsed.value.jobs.len));
    for (parsed.value.jobs) |job| {
        if ((ids.getOrPutAssumeCapacity(job.id)).found_existing)
            return reject(problem, "job id \"{s}\" is used more than once", .{job.id});
        var spec = try JobSpec.init(allocator, io, environ, job, config_dir, problem);
        errdefer spec.deinit();
        result.items.appendAssumeCapacity(spec.move());
    }
    return result;
}

/// On `error.InvalidConfig`, `problem` holds a sentence naming the file and the fault.
pub fn loadConfig(
    allocator: Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    path: []const u8,
    problem: *Io.Writer,
) !LoadedSpecs {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return reject(problem, "config file {s} not found; create one with `croner setup`", .{path}),
        error.StreamTooLong => return reject(problem, "config file {s} is larger than 1 MiB", .{path}),
        else => return err,
    };
    defer allocator.free(bytes);
    problem.print("{s}: ", .{path}) catch {};
    return parseConfig(allocator, io, environ, bytes, std.fs.path.dirname(path) orelse ".", problem);
}

pub fn resolveFromCwd(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn expectProblem(expected: []const u8, config: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var problem: Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.InvalidConfig, parseConfig(std.testing.allocator, std.testing.io, null, config, "/tmp", &problem));
    try std.testing.expectEqualStrings(expected, problem.buffered());
}

test "config parsing applies defaults and rejects invalid jobs" {
    var discard_buffer: [512]u8 = undefined;
    var discard: Io.Writer = .fixed(&discard_buffer);
    const valid = "{\"$schema\":\"./croner.schema.json\",\"jobs\":[{\"id\":\"sync\",\"schedule\":\"*/5 * * * *\",\"action\":{\"command\":{\"argv\":[\"echo\",\"\"],\"env\":{\"MODE\":\"test\"}}}}]}";
    var parsed = try parseConfig(std.testing.allocator, std.testing.io, null, valid, "/tmp", &discard);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.items.items.len);
    try std.testing.expectEqual(libcron.OverlapPolicy.skip, parsed.items.items[0].overlap);
    try std.testing.expectEqualStrings("/tmp", parsed.items.items[0].cwd);
    try std.testing.expectEqualStrings("test", parsed.items.items[0].env[0].value);

    const duplicate = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"]}}},{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"y\"]}}}]}";
    try expectProblem("job id \"x\" is used more than once", duplicate);

    const bad_env = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"],\"env\":{\"BAD-NAME\":\"x\"}}}}]}";
    try expectProblem("job \"x\": env name \"BAD-NAME\" must be letters, digits and underscores, not starting with a digit", bad_env);

    const explicit = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"],\"cwd\":\"work\"}},\"overlap\":\"concurrent\"}]}";
    var explicit_parsed = try parseConfig(std.testing.allocator, std.testing.io, null, explicit, "/tmp", &discard);
    defer explicit_parsed.deinit();
    try std.testing.expectEqual(libcron.OverlapPolicy.concurrent, explicit_parsed.items.items[0].overlap);
    try std.testing.expectEqualStrings("/tmp/work", explicit_parsed.items.items[0].cwd);
}

test "config parser rejects unknown fields and invalid schedules" {
    try expectProblem("line 2, column 8: unknown field", "{\"jobs\":[],\n\"extra\":true}");
    const invalid_schedule = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"not cron\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}";
    try expectProblem("job \"x\": schedule \"not cron\": expected five fields: minute hour day-of-month month day-of-week", invalid_schedule);
    const out_of_range = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"0 25 * * *\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}";
    try expectProblem("job \"x\": schedule \"0 25 * * *\": hour values must be within 0-23", out_of_range);
    const empty_argv = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[]}}}]}";
    try expectProblem("job \"x\": action.command.argv needs a nonempty first element, and argv and cwd may not contain NUL bytes", empty_argv);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const one_job = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}";
    var discard_buffer: [512]u8 = undefined;
    var discard: Io.Writer = .fixed(&discard_buffer);
    try std.testing.expectError(error.OutOfMemory, parseConfig(failing.allocator(), std.testing.io, null, one_job, "/tmp", &discard));
}

test "time zones load by IANA name and unknown names are rejected" {
    var discard_buffer: [512]u8 = undefined;
    var discard: Io.Writer = .fixed(&discard_buffer);
    const paris = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"0 9 * * *\",\"time_zone\":\"Europe/Paris\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}";
    var parsed = try parseConfig(std.testing.allocator, std.testing.io, null, paris, "/tmp", &discard);
    defer parsed.deinit();
    // 2026-07-01T07:00:00Z is 09:00 in Paris summer time.
    const local = try parsed.items.items[0].time_zone.toLocal(1782889200);
    try std.testing.expectEqual(@as(u8, 9), local.hour);

    try expectProblem(
        "job \"x\": time_zone \"Mars/Olympus\" is not an IANA time zone name such as Europe/Paris",
        "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"time_zone\":\"Mars/Olympus\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}",
    );
}

test "job spec owns allocations made while it is initialized" {
    var discard_buffer: [512]u8 = undefined;
    var discard: Io.Writer = .fixed(&discard_buffer);
    var long_id: [8192]u8 = @splat('x');
    var spec = try JobSpec.init(std.testing.allocator, std.testing.io, null, .{
        .id = &long_id,
        .schedule = "* * * * *",
        .action = .{ .command = .{ .argv = &.{"true"} } },
    }, "/tmp", &discard);
    defer spec.deinit();
    try std.testing.expectEqualStrings(&long_id, spec.id);
}
