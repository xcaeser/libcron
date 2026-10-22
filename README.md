### ⏱️ croner - cron scheduling for Zig.

[Croner reference docs](https://xcaeser.github.io/libcron)

[![Tests](https://github.com/xcaeser/libcron/actions/workflows/main.yml/badge.svg)](https://github.com/xcaeser/libcron/actions/workflows/main.yml)
[![Zig Version](https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig)](build.zig.zon)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)
[![Version](https://img.shields.io/badge/croner-v0.2.0-green)](https://github.com/xcaeser/libcron/releases)

- [Library usage](#library-usage)

```sh
   zig fetch --save=libcron https://github.com/xcaeser/libcron/archive/v0.2.0.tar.gz
```

- [CLI usage](#cli-usage)

```sh
   curl -fsSL https://raw.githubusercontent.com/xcaeser/libcron/main/install.sh | sh
```

## Features

- `minute hour day-of-month month day-of-week` expressions with month and
  weekday names, Sunday as `0` or `7`, and `@daily`-style macros
- Wildcards, lists, ranges, and steps, with POSIX day-of-month/day-of-week
  behavior
- Field-level parse diagnostics
- Matching, next-occurrence, and DST-aware next-instant calculation
- In-memory callbacks and direct child-process scheduling through `std.Io`,
  with jobs added, removed, paused, and unpaused while running
- UTC, fixed-offset, and TZif timezones loaded from the system database,
  with defined behavior across DST changes and clock steps
- A JSON-configured background daemon with per-job time zones that can run
  at login
- No runtime dependencies for `libcron`

## Library usage

### Add `libcron` to a project

```sh
zig fetch --save=libcron https://github.com/xcaeser/libcron/archive/v0.2.0.tar.gz
```

Add the public `libcron` module to an executable or library:

```zig
const libcron_dep = b.dependency("libcron", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("libcron", libcron_dep.module("libcron"));
```

The archive contains the repository's CLI source as well. A consumer build
only compiles `libcron`; Zig does not download individual files from a package.

### Schedule a callback

```zig
const std = @import("std");
const libcron = @import("libcron");

const Backup = struct {
    target: []const u8,

    fn run(context: ?*anyopaque, io: std.Io, invocation: libcron.Invocation) !void {
        _ = io;
        const self: *Backup = @ptrCast(@alignCast(context.?));
        // `local_time` is the wall-clock minute the run is for.
        std.log.info("backing up {s} for {f}", .{ self.target, invocation.local_time });
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var scheduler = libcron.Scheduler.init(init.gpa);
    defer scheduler.deinit();

    // Parsing a literal at comptime fails the build on a typo.
    const nightly = comptime libcron.Expression.parse("30 2 * * *") catch unreachable;
    var backup: Backup = .{ .target = "/srv/data" };
    // The scheduler keeps the context pointer, so `backup` must outlive the job.
    _ = try scheduler.add(io, nightly, .{
        .callback = .{ .context = &backup, .run = Backup.run },
    }, .{}); // UTC, `.skip` overlap

    // Blocks until canceled; outcomes go to an observer (none here).
    try scheduler.run(io, null);
}
```

### Run a command

```zig
const std = @import("std");
const libcron = @import("libcron");

const Log = struct {
    fn record(_: *Log, invocation: libcron.Invocation, outcome: libcron.Outcome) void {
        // Prints e.g. `job 0: exited with code 0 after 1.5s`.
        std.log.info("job {d}: {f}", .{ @backingInt(invocation.job_id), outcome });
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var scheduler = libcron.Scheduler.init(init.gpa);
    defer scheduler.deinit();

    // argv runs directly, without a shell, and inherits stdout and stderr.
    // `add` copies argv, cwd, and env, so they can be freed once it returns.
    _ = try scheduler.add(io, try .parse("@weekly"), .{
        .command = .{
            .argv = &.{ "/usr/bin/env", "rotate-logs" },
            .cwd = .{ .path = "/var/log" }, // default: inherit
            .environ_map = init.environ_map, // default: inherit
        },
    }, .{
        // Start every due run, even while the previous one is still going.
        .overlap = .concurrent,
        // On cancel: SIGTERM to the process group, SIGKILL 30s later.
        .termination_grace = .fromSeconds(30),
    });

    // `Observer.init` keeps the context typed, so `record` needs no casts.
    var log: Log = .{};
    try scheduler.run(io, .init(&log, Log.record));
}
```

Commands ignore stdin and run in their own process group, so a command that
traps SIGTERM and its background children do not outlive the scheduler. The
default grace is 10 seconds. With the default `.skip` overlap, a run that is
due while the previous one is still active is reported as `skipped_overlap`.

### Change jobs while running

```zig
const std = @import("std");
const libcron = @import("libcron");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var scheduler = libcron.Scheduler.init(init.gpa);
    defer scheduler.deinit();

    // `run` blocks, so give it its own task and keep this one.
    var running = try io.concurrent(libcron.Scheduler.run, .{ &scheduler, io, null });
    // Cancel ends the loop; running commands get SIGTERM, then SIGKILL.
    defer _ = running.cancel(io) catch {};

    // A job added while running first fires at its next matching minute.
    const sync = try scheduler.add(io, try .parse("*/5 * * * *"), .{
        .command = .{ .argv = &.{"sync"} },
    }, .{});

    // A paused job skips its minutes and catches none of them up.
    _ = scheduler.pause(io, sync);
    _ = scheduler.unpause(io, sync);

    // `replace` keeps the id and the pause; a run in progress finishes with the old task.
    _ = try scheduler.replace(io, sync, try .parse("*/10 * * * *"), .{
        .command = .{ .argv = &.{ "sync", "--quick" } },
    }, .{});

    // `.paused` adds a job that waits for `unpause`.
    const report = try scheduler.add(io, try .parse("@hourly"), .{
        .command = .{ .argv = &.{"report"} },
    }, .{ .paused = true });
    _ = scheduler.unpause(io, report);

    // A removed job's run in progress finishes and reports; nothing new starts.
    _ = scheduler.remove(io, sync);

    // ... the rest of the program; the defer above stops the scheduler.
    try io.sleep(.fromSeconds(60), .awake);
}
```

`add`, `replace`, `remove`, `pause`, and `unpause` work from any task, also
from the observer, which is called from the scheduler's and the jobs' tasks
and so must be thread-safe. A callback's context must stay valid until the
job is removed and its last outcome reported, or the scheduler is
deinitialized.

### Check an expression

```zig
const std = @import("std");
const libcron = @import("libcron");

/// Parses text a user typed and logs why it was rejected.
fn parseSchedule(text: []const u8) !libcron.Expression {
    var diagnostics: libcron.Diagnostics = .{};
    return libcron.Expression.parseWithDiagnostics(text, &diagnostics) catch |err| {
        // e.g. `ValueOutOfRange: hour values must be within 0-23`
        std.log.err("{t}: {s}", .{ err, diagnostics.message });
        return err;
    };
}

pub fn main() !void {
    const nightly = try parseSchedule("30 2 * * *");

    // Minutes are timezone-neutral `DateTime`s and format as `2026-10-25 02:30`.
    const at = try libcron.DateTime.init(2026, .oct, 25, 2, 30);
    std.debug.assert(try nightly.matches(at));

    // `next` is exclusive: the first match strictly after `at`.
    if (try nightly.next(at)) |following| {
        std.log.info("after {f} comes {f}", .{ at, following }); // 2026-10-26 02:30
    }
}
```

`Diagnostics.field` is `0` (minute) through `4` (day of week), or `null`
when the expression as a whole is malformed.

### Time zones and clock changes

```zig
const std = @import("std");
const libcron = @import("libcron");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Read from `$TZDIR`, else `/usr/share/zoneinfo`; must outlive its jobs.
    var paris = try libcron.TimeZone.load(io, init.gpa, init.environ_map, "Europe/Paris");
    defer paris.deinit();
    // Fixed offsets and `.utc` (the default) need no cleanup.
    const tokyo = try libcron.TimeZone.fixedOffset(9 * 60 * 60);

    // When a scheduler running all along fires next, DST changes included.
    const nightly = comptime libcron.Expression.parse("30 2 * * *") catch unreachable;
    const now = std.Io.Clock.real.now(io).toSeconds();
    const fire = nightly.nextInstant(now, paris) orelse return error.NeverFires;
    std.log.info("next at {f} in Paris, {f} UTC", .{
        try paris.toLocal(fire),
        try libcron.TimeZone.utc.toLocal(fire),
    });

    // Each job reads the schedule on its own wall clock.
    var scheduler = libcron.Scheduler.init(init.gpa);
    defer scheduler.deinit();
    _ = try scheduler.add(io, nightly, .{ .command = .{ .argv = &.{"backup"} } }, .{ .time_zone = paris });
    _ = try scheduler.add(io, nightly, .{ .command = .{ .argv = &.{"backup"} } }, .{ .time_zone = tokyo });
    try scheduler.run(io, null);
}
```

`run` dispatches every minute that starts on the real clock, including
minutes repeated after the clock is set back, and each job reads it on the
wall clock of its `TimeZone`:

| Clock                                                           | `*` in the minute or hour field  | Fixed time, as in `30 2 * * *`                                                                      |
| --------------------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------- |
| Set back, or a repeated fall-back hour                          | Reruns on every matching minute  | Waits until the wall clock passes the latest minute it handled; never runs twice                    |
| Ahead by up to 3 hours (spring-forward, a late wake, set ahead) | Runs for the current minute only | Each skipped match runs once, with that minute as `Invocation.local_time`, under the overlap policy |
| More than 3 hours either way                                    | Taken as the new time            | Taken as the new time; nothing is caught up or held back                                            |

A paused job keeps up with the clock, so unpausing it catches nothing up.
`Expression.nextInstant` follows the same rules.

### API

- `Expression.parse(source) ParseError!Expression`
- `Expression.parseWithDiagnostics(source, *Diagnostics) ParseError!Expression`
- `expression.matches(date_time) !bool`
- `expression.next(after) !?DateTime`
- `expression.nextInstant(after_unix_seconds, time_zone) ?i64`
- `DateTime.init(year, month, day, hour, minute) !DateTime`
- `TimeZone.utc`, `TimeZone.fixedOffset(seconds) !TimeZone`
- `TimeZone.load(io, allocator, environ_map, name) !TimeZone` / `time_zone.deinit()`
- `TimeZone.fromTz(tz) !TimeZone`
- `time_zone.toLocal(unix_seconds) !DateTime`
- `time_zone.nextTransition(unix_seconds) !?i64`
- `Scheduler.init(allocator)` / `scheduler.deinit()`
- `scheduler.add(io, expression, task, options) !JobId`, paused when
  `options.paused`
- `scheduler.replace(io, id, expression, task, options) !bool`
- `scheduler.remove(io, id) bool`
- `scheduler.pause(io, id) bool` / `scheduler.unpause(io, id) bool`
- `scheduler.run(io, observer) RunError!void`
- `Observer.init(context, notify)`
- `command.validate() !void` — the checks `scheduler.add` runs on a command
- `outcome.format`, `date_time.format` (use `{f}`)

## CLI usage

### Install croner

```sh
curl -fsSL https://raw.githubusercontent.com/xcaeser/libcron/main/install.sh | sh
```

The installer verifies the release checksum, stores the executable at
`~/.croner/bin/croner`, and links `~/.local/bin/croner`. Make sure
`~/.local/bin` is in your `PATH`.

To build from source, run `zig build`; the executable is written to
`zig-out/bin/croner`. All commands use `./croner.json` unless
`--config <path>` is supplied.

| Command             | Behavior                                                 |
| ------------------- | -------------------------------------------------------- |
| `croner setup`      | Interactively create a config; refuses to overwrite one. |
| `croner start`      | Validate the config and start its background daemon.     |
| `croner start <id>` | Resume a paused job.                                     |
| `croner stop <id>`  | Pause future runs; a run in progress finishes.           |
| `croner stop`       | Shut down the daemon and all jobs.                       |
| `croner list`       | Show jobs as `active`, `paused`, or `offline`.           |
| `croner next [id]`  | Show each job's next 5 fire times in its time zone.      |
| `croner reload`     | Validate and reconcile the config by stable job ID.      |
| `croner logs`       | Show the latest 100 combined log lines.                  |
| `croner enable`     | Start the daemon at login and restart it after a crash.  |
| `croner disable`    | Undo `enable` and stop the daemon.                       |
| `croner version`    | Print the installed Croner version.                      |

Each config gets its own daemon. Its socket, lock, log, and pause state live in
`~/.croner/run/<hash>/` (or `$CRONER_HOME/run/<hash>/`), where the hash is of
the config file's real path, so `--config` reaches the same daemon from any
directory or through any symlink, and the project directory stays clean.

`next` accepts `--count <n>` and works from the config alone; with the daemon
running it also marks paused jobs. It shows scheduled times across DST changes
and does not predict runs skipped by `overlap` or catch-up runs after a clock
jump. `logs` accepts `--lines <n>` and `--follow`.

A reload leaves the daemon untouched when validation fails. Otherwise it
compares jobs by ID: an unchanged job is left alone, a changed job is replaced
in place, a removed job is no longer scheduled (a run in progress finishes),
and a new job starts active. A pause belongs to the ID, so a changed job that
was paused stays paused. Paused IDs are saved in the state directory, so they
stay paused across daemon restarts, crashes, and reboots. If the config is
invalid when the daemon starts, at login for example, it runs no jobs and
`croner list` shows the error until a `croner reload` succeeds.

### Run at login

`croner enable` validates the config and registers its daemon with the user's
service manager, never system-wide: a LaunchAgent in `~/Library/LaunchAgents`
on macOS, a user unit in `~/.config/systemd/user` on Linux. The daemon then
starts at login and is restarted after a crash, while `croner stop` still keeps
it down until `croner start` or the next login; `croner start` goes through the
service manager once a config is enabled. The unit records the config path,
`CRONER_HOME`, and the current `PATH` and `TZDIR`, so jobs find the same
programs and time zones; run `croner enable` again after changing them. On
Linux, jobs stop when you log out unless you run `loginctl enable-linger`.
Runs missed while the machine was off are not caught up.

### Configuration

The editor schema is published at
<https://xcaeser.github.io/libcron/croner.schema.json>.

```json
{
  "$schema": "https://xcaeser.github.io/libcron/croner.schema.json",
  "jobs": [
    {
      "id": "sync",
      "schedule": "*/5 * * * *",
      "action": {
        "command": {
          "argv": ["bun", "run", "sync"],
          "cwd": ".",
          "env": {
            "MODE": "production"
          }
        }
      },
      "overlap": "skip",
      "time_zone": "Europe/Paris"
    }
  ]
}
```

Each job requires a nonempty unique `id`, a `schedule` (see
[Syntax](#syntax)), and an `action`. `action.command.argv` is a nonempty
direct argv array; it never gets an implicit shell. Use an executable shebang
or an explicit argv such as `["bash", "script.sh"]` for shell scripts. `cwd`
defaults to the config directory, and relative paths resolve from there. `env`
overlays the daemon's inherited environment. `overlap` is `skip` or
`concurrent` and defaults to `skip`. `time_zone` is the IANA zone, such as
`Europe/Paris`, the schedule is read in, with the DST rules described under
[Library usage](#library-usage); it defaults to UTC. Unknown fields, malformed
environment names, invalid schedules, unknown time zones, and invalid commands
are rejected before startup or reload, with a message that names the job and
the field. `$schema` is editor metadata and may point anywhere.

## Syntax

| Field        | Values                                        |
| ------------ | --------------------------------------------- |
| Minute       | `0-59`                                        |
| Hour         | `0-23`                                        |
| Day of month | `1-31`                                        |
| Month        | `1-12` or `JAN`-`DEC`                         |
| Day of week  | `0-7` or `SUN`-`SAT` (`0` and `7` are Sunday) |

Each field accepts `*`, a value, an inclusive range `a-b`, a step `*/n` or
`a-b/n`, and `a/n`, which steps from `a` to the field's maximum (`5/15` in the
minute field is `5,20,35,50`). Combine them with commas, as in `0,30` or
`MON-FRI,SUN`. Names are three letters in any case and work in ranges. A
weekday range may end on Sunday, as in `FRI-SUN`. Ranges cannot otherwise
wrap. Fields are separated by spaces, tabs, or line breaks.

| Macro                   | Same as     |
| ----------------------- | ----------- |
| `@yearly`, `@annually`  | `0 0 1 1 *` |
| `@monthly`              | `0 0 1 * *` |
| `@weekly`               | `0 0 * * 0` |
| `@daily`, `@midnight`   | `0 0 * * *` |
| `@hourly`               | `0 * * * *` |

Macros are lowercase. `@reboot`, `L`, `W`, `#`, seconds, and years are not
supported.

When both day fields are restricted, either may match. When either starts
with `*` (including `*/step`), both day fields must match, following
traditional cron wildcard behavior. A schedule whose day of week is `*` and
whose months never have its days, such as `0 0 31 2 *`, is rejected.

## Development

```sh
zig fmt --check .
zig build test --summary all
zig build docs
```

MIT licensed. See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
