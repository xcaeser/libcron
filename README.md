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

### `main.zig` example

```zig
const std = @import("std");
const libcron = @import("libcron");

const Backup = struct {
    target: []const u8,

    fn run(context: ?*anyopaque, io: std.Io, invocation: libcron.Invocation) !void {
        _ = io;
        const self: *Backup = @ptrCast(@alignCast(context.?));
        std.log.info("backing up {s} for {f}", .{ self.target, invocation.local_time });
    }
};

const Log = struct {
    fn record(_: *Log, invocation: libcron.Invocation, outcome: libcron.Outcome) void {
        std.log.info("job {d}: {f}", .{ @backingInt(invocation.job_id), outcome });
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var paris = try libcron.TimeZone.load(io, init.gpa, init.environ_map, "Europe/Paris");
    defer paris.deinit();

    var scheduler = libcron.Scheduler.init(init.gpa);
    defer scheduler.deinit();

    var backup: Backup = .{ .target = "/srv/data" };
    const nightly = comptime libcron.Expression.parse("30 2 * * *") catch unreachable;
    _ = try scheduler.add(io, nightly, .{
        .callback = .{ .context = &backup, .run = Backup.run },
    }, .{ .time_zone = paris });
    _ = try scheduler.add(io, try .parse("@weekly"), .{
        .command = .{ .argv = &.{ "/usr/bin/env", "rotate-logs" } },
    }, .{});

    var log: Log = .{};
    try scheduler.run(io, .init(&log, Log.record));
}
```

Parsing a literal at `comptime` with `catch unreachable` fails the build on a
typo. For text from users, `Expression.parseWithDiagnostics` reports the
failing field and a short message, such as `hour values must be within 0-23`.
`Observer.init` takes a typed context pointer, so observers need no casts.

`Scheduler.run` blocks until canceled. Run it in its own task (for example
with `io.concurrent`) to keep changing jobs: `add`, `replace`, `remove`,
`pause`, and `unpause` work at any time, also while `run` is active. A job
added while running first fires at its next matching minute, and
`JobOptions.paused` adds it paused. `replace` changes a job in place: it keeps
its id, its pause, and its running invocations, which finish with the old
task, so a `.skip` job never overlaps its predecessor. A removed job's running
invocation finishes and reports its outcome; an unpaused job does not catch up
minutes it missed. `add` copies a command's argv, working directory, and
environment, so they can be freed once it returns; a callback's context must
stay valid until the job is removed and its last outcome reported, or the
scheduler is deinitialized. The observer is called from the scheduler's and
the jobs' tasks, so it must be thread-safe, but never with the scheduler
locked, so it may add, replace, remove, pause, or unpause jobs.

`run` dispatches every minute that starts on the real clock, including minutes
repeated after the clock is set back, and each job reads it on the wall clock
of its `TimeZone`:

- After the clock is set back, or in the repeated hour of a fall-back, a job
  whose minute or hour field starts with `*` reruns on every matching minute,
  while a fixed-time job waits until the wall clock passes the latest minute
  it has handled, so it never runs twice.
- After a jump ahead of up to and including three hours, such as a
  spring-forward, a late wake, or the clock set ahead, each fixed-time match
  in the skipped minutes runs once, with that minute as
  `Invocation.local_time`, and the job's overlap policy decides whether those
  runs pile up. Jobs starting with `*` run only for the current minute.
- A jump of more than three hours either way is taken as the new time:
  nothing is caught up or held back.

A paused job keeps up with the clock, so unpausing it catches nothing up.
`Expression.nextInstant` answers when a job next fires under these rules.

Jobs default to `.skip` overlap behavior; use `.concurrent` to launch every
due occurrence. Commands execute the supplied argv directly, without a shell,
inherit stdout and stderr, ignore stdin, and run in their own process group.
Canceling the scheduler sends SIGTERM to that group, then SIGKILL after
`JobOptions.termination_grace` (10 seconds by default), so commands that trap
SIGTERM and their background children do not outlive it.

`DateTime` is a Gregorian calendar minute without an attached timezone and
formats as `2026-10-25 02:30`. `Expression.next` is exclusive and returns
`null` when no later representable match exists.

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
