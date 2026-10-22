### ⏱️ croner - cron scheduling for Zig.

[Croner reference docs](https://xcaeser.github.io/croner)

[![Tests](https://github.com/xcaeser/croner/actions/workflows/main.yml/badge.svg)](https://github.com/xcaeser/croner/actions/workflows/main.yml)
[![Zig Version](https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig)](build.zig.zon)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)
[![Version](https://img.shields.io/badge/croner-v0.1.0-green)](https://github.com/xcaeser/croner/releases)

- [Library usage](#library-usage)

```sh
   zig fetch --save=libcron https://github.com/xcaeser/croner/archive/v0.1.0.tar.gz
```

- [CLI usage](#cli-usage)

```sh
   curl -fsSL https://raw.githubusercontent.com/xcaeser/croner/main/install.sh | sh
```

## Features

- Numeric `minute hour day-of-month month day-of-week` expressions
- Wildcards, lists, ranges, and steps
- POSIX day-of-month/day-of-week behavior
- Matching and next-occurrence calculation
- In-memory callbacks and direct child-process scheduling through `std.Io`
- UTC, fixed-offset, and caller-parsed TZif timezones
- A JSON-configured background daemon
- No runtime dependencies for `libcron`

## Library usage

### Add `libcron` to a project

```sh
zig fetch --save=libcron https://github.com/xcaeser/croner/archive/v0.1.0.tar.gz
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

fn runBackup(_: ?*anyopaque, io: std.Io, invocation: libcron.Invocation) !void {
    _ = io;
    _ = invocation;
    // Perform one scheduled invocation.
}

pub fn main(init: std.process.Init) !void {
    var scheduler = libcron.Scheduler.init(init.gpa);
    defer scheduler.deinit();

    _ = try scheduler.add(
        try libcron.Expression.parse("0 2 * * *"),
        .{ .callback = .{ .run = runBackup } },
        .{ .time_zone = try libcron.TimeZone.fixedOffset(2 * 60 * 60) },
    );
    _ = try scheduler.add(
        try libcron.Expression.parse("30 3 * * 1"),
        .{ .command = .{ .argv = &.{ "/usr/bin/env", "backup" } } },
        .{},
    );

    try scheduler.run(init.io, null);
}
```

`DateTime` is a Gregorian calendar minute without an attached timezone.
`Expression.next` is exclusive and returns `null` when no later representable
match exists. The CLI reads each job's schedule in its `time_zone`, UTC by
default.

Configure jobs before calling `Scheduler.run`; `add` and `remove` reject
changes while it is active. Jobs default to `.skip` overlap behavior; use
`.concurrent` to launch every due occurrence. Commands execute the supplied
argv directly, without a shell, inherit stdout/stderr, ignore stdin, and are
killed when the scheduler is canceled.

### API

- `Expression.parse(source) !Expression`
- `expression.matches(date_time) !bool`
- `expression.next(after) !?DateTime`
- `DateTime.init(year, month, day, hour, minute) !DateTime`
- `TimeZone.fixedOffset(seconds) !TimeZone`
- `TimeZone.fromTz(tz) !TimeZone`
- `Scheduler.init(allocator)` / `scheduler.deinit()`
- `scheduler.add(expression, task, options) !JobId`
- `scheduler.remove(id) !bool`
- `scheduler.run(io, observer) !void`

## CLI usage

### Install croner

```sh
curl -fsSL https://raw.githubusercontent.com/xcaeser/croner/main/install.sh | sh
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
| `croner reload`     | Validate and reconcile the config by stable job ID.      |
| `croner logs`       | Show the latest 100 combined log lines.                  |
| `croner enable`     | Start the daemon at login and restart it after a crash.  |
| `croner disable`    | Undo `enable` and stop the daemon.                       |
| `croner version`    | Print the installed Croner version.                      |

Each config gets its own daemon. Its socket, lock, log, and pause state live in
`~/.croner/run/<hash>/` (or `$CRONER_HOME/run/<hash>/`), where the hash is of
the config's absolute path, so `--config` reaches the same daemon from any
directory and the project directory stays clean.

`logs` accepts `--lines <n>` and `--follow`. A reload leaves the daemon
untouched when validation fails. Otherwise it compares jobs by ID: an
unchanged job keeps its schedule state, a changed job is replaced, a removed
job is no longer scheduled (a run in progress finishes), and a new job starts
active. A pause belongs to the ID, so a changed job that was paused stays
paused. Paused IDs are saved in the state directory, so they stay paused
across daemon restarts, crashes, and reboots.

### Run at login

`croner enable` validates the config and registers its daemon with the user's
service manager, never system-wide: a LaunchAgent in `~/Library/LaunchAgents`
on macOS, a user unit in `~/.config/systemd/user` on Linux. The daemon then
starts at login and is restarted after a crash, while `croner stop` still keeps
it down until `croner start` or the next login; `croner start` goes through the
service manager once a config is enabled. The unit records the config path,
`CRONER_HOME`, and the current `PATH` and `TZDIR`, so jobs find the same
programs and time zones; run `croner enable` again after changing them. On Linux, jobs stop when you log out
unless you run `loginctl enable-linger`. Runs missed while the machine was off
are not caught up.

### Configuration

The editor schema is published at
<https://xcaeser.github.io/croner/croner.schema.json>.

```json
{
  "$schema": "https://xcaeser.github.io/croner/croner.schema.json",
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

Each job requires a nonempty unique `id`, a five-field `schedule`, and an
`action`. `action.command.argv` is a nonempty direct argv array; it never gets
an implicit shell. Use an executable shebang or an explicit argv such as
`["bash", "script.sh"]` for shell scripts. `cwd` defaults to the config
directory, and relative paths resolve from there. `env` overlays the daemon's
inherited environment. `overlap` is `skip` or `concurrent` and defaults to
`skip`. `time_zone` is the IANA zone, such as `Europe/Paris`, the schedule is
read in; it defaults to UTC. Unknown fields, malformed environment names,
invalid schedules, unknown time zones, and invalid commands are rejected
before startup or reload, with a message that names the job and the field.
`$schema` is editor metadata and may point anywhere.

## Syntax

| Field        | Values                |
| ------------ | --------------------- |
| Minute       | `0-59`                |
| Hour         | `0-23`                |
| Day of month | `1-31`                |
| Month        | `1-12`                |
| Day of week  | `0-6` (`0` is Sunday) |

Each field accepts `*`, a number, comma-separated numbers or ranges, `*/step`,
and `range/step`. Ranges are inclusive and cannot wrap. Month and weekday
names, Sunday `7`, macros, and special operators are unsupported.

When both day fields are restricted, either may match. When either uses `*`
(including `*/step`), both day fields must match, following traditional cron
wildcard behavior.

## Development

```sh
zig fmt --check .
zig build test --summary all
zig build docs
```

MIT licensed. See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
