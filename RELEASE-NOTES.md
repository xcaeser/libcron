# Release Notes

## Unreleased

### libcron

- Expressions accept month and weekday names, Sunday as `7`, the `@yearly`,
  `@monthly`, `@weekly`, `@daily`, and `@hourly` macros, and `a/n` steps, and
  reject days that can never occur, such as `0 0 31 2 *`.
- `Expression.parseWithDiagnostics` names the failing field with a short
  message, and `Expression.comptimeParse` checks literals at compile time.
- Jobs follow their time zone across DST changes the way cronie does: once per
  day across a fall-back, once after a spring-forward, and once after a wake of
  under three hours; wildcard jobs run every real minute.
  `Expression.nextInstant` answers when a job fires next.
- `TimeZone.load` reads zones such as `Europe/Paris` from the system database;
  `toLocal` and `nextTransition` are public.
- Jobs can be added, removed, paused, and unpaused while `Scheduler.run` is
  active. **Breaking:** `add` and `remove` take an `Io`, and `remove` no longer
  fails.
- Commands run in their own process group; cancellation sends SIGTERM, then
  SIGKILL after `JobOptions.termination_grace` (10 seconds by default).
- **Breaking:** `Outcome` carries durations and gains `dispatch_error`;
  `Outcome.format` describes it. `Invocation.scheduled_unix_minute` is now
  `scheduled_unix_seconds`. `RunError` is `Canceled` or `AlreadyRunning`.
- `Callback.init` and `Observer.init` take typed contexts, `Command.validate`
  runs the checks `add` makes, and `DateTime` formats with `{f}`.
- `Expression.next` is several times faster.

### CLI

- Daemon state moves out of the project to `~/.croner/run/<hash>/`, or
  `$CRONER_HOME/run/<hash>/`, which also fixes `NameTooLong` from deep
  directories.
- `croner enable` and `croner disable` start the daemon at login and restart
  it after a crash through launchd or systemd user units.
- Pauses survive daemon restarts, crashes, and reboots, and follow the job ID
  across reloads.
- Jobs take an optional `time_zone`; UTC remains the default.
- One scheduler runs every job, and `reload` compares jobs by ID, keeping
  unchanged jobs running untouched. `croner stop <id>` lets a run in progress
  finish.
- The log has one line per event with an ISO-8601 UTC time, the job, and the
  outcome, such as `exited with code 7 after 1.5s`.
- Errors are sentences that name the file, job, and field, including the
  failing schedule field.
- Output redirected to a file no longer overwrites itself, and any `$schema`
  value is accepted.

## v0.1.0 (Initial Release)

Cron scheduling for Zig, in-process or from a single `croner.json`.

- Parse and evaluate familiar five-field cron expressions.
- Schedule callbacks or direct child processes with `libcron`.
- Control timezones, overlap behavior, and cancellation.
- Manage command jobs with `setup`, `start`, `stop`, `list`, `reload`, and `logs`.
- Validate configurations with the published [JSON Schema](https://xcaeser.github.io/croner/croner.schema.json).

The CLI supports macOS and Linux and schedules jobs in UTC.

`libcron` has no runtime dependencies.
