# Changelog

## [0.2.0] - 2026-11-14

- Races and the hunt run on SQLite as well as PostgreSQL: they empty tables with `DELETE` and restart ids through `sqlite_sequence` where PostgreSQL takes `TRUNCATE`, and read stored days with `date()`. On SQLite each side and each hunt worker gets a database file of its own under `.holdfast/db/`, so the app's own test database is never written, and the repro line names that file.
- A check that fails in holdfast's own support code, or a hunt whose drafting fails there, says so and names the database adapter, in place of telling the agent to fix the suspicion or the app.
- The hunt refuses a TCP connection to any host but this machine. An area whose action reached a real service is `unchecked` with `environment: real network call to HOST:PORT`, not `bug_suspect`, and a drafted area names in a TODO the app module that calls HTTP itself.
- In a race, a module method the suspicion stubs (`allow(LockerApi).to receive(:register)`) is an `outside_call` pause point, and `pause: LockerApi.register` holds at it.
- Every hunt shrinks a failure, for a quarter of an area's time limit, between 15 and 60 seconds. Shrinking was off for any `--budget` under 900, the default of 600 included.
- A request sent again no longer fails the area with an internal `Sequences::Diverged` when an action since destroyed its record.
- A hunt never drafts over an area file that exists, so a merged area stays merged. The skill shows how to fake a service that calls HTTP itself with `outside_calls`, `failure` and `failures:`, and how to merge areas so a bug across two of them is reachable.
- A kept spec is named by its suspicion's `says` text and a digest of it, not by its place in the file, so specs from separate runs no longer share an `sN_` number and checking a suspicion again replaces its own spec.
- A `do` of several lines shows as one line in a row, so it no longer breaks the Markdown list.
- A dirty working tree shows as `uncommitted changes on <commit>`, a commit `git log` has, in place of the hash of holdfast's private snapshot.

## [0.1.0] - 2026-11-13

First release. holdfast runs what an agent suspects about a Rails app, on base and on head, and keeps the spec that proves it.

- `holdfast check FILE... [--suspect YAML]...` turns each suspicion (`says`, `given`, `do` or `race`, `pause`, `expect`) into a spec that builds its records with the app's factories and runs it on base and on the working tree. Each row is `confirmed` with the kept spec, `refuted` with the values observed, or `could_not_run` with the error and the part of the suspicion it came from. A `race` holds one action at a pause point (`batch_load`, `outside_call`, `row_lock`, `first_write`, or a method) while the other runs, and is confirmed only when that order ends in a state no serial order reaches. With no change, or `--here`, a check runs once on the working tree.
- `holdfast run` checks a change against its base: one row per changed method and per caller of a changed constant or scope, from the tests that name it, the test files the change edited, evidence under `.holdfast/evidence/`, and pins drafted from the method's parameters. Each row is `unintended_change`, `intended_change`, `bug_suspect`, `unchecked` (with the value nobody drew), or `clean` (with the evidence it covers). It runs on jitcatch and branchout.
- `holdfast run` with nothing changed hunts. It drafts one sequence definition per write area into `.holdfast/sequences/` and runs random orders of the area's routes, API endpoints, and jobs: two actions interleaved at a call to an outside client, a job held after its first batch load, clocks at day edges in other time zones, a request sent again as a double click or a retry would, and a desk route against an API endpoint about one table. Drafted invariants check money a record took, the order a waiting status is left in, one row for each `has_one` no unique index holds, and the bounds a column name states (`*_left`, `*_count` against `max_*`, a percentage). A failure is shrunk to a short numbered sequence with an `it` block that replays it. The first line says how many actions the hunt reached, and each area lists the actions it never reached with the refusals they met. `--sequences` hunts over the areas a change touches, and `--observe` compares each area's action orders on base and head.
- On three apps it had not seen, the hunt found a guest signed in twice on one day (a 500 from a unique index), an insurance policy update that raised on a nil policy, and a sailing cancelled while the close job filed its manifest that ended `departed`, each confirmed with `holdfast check`.
- Each app gets its own test database names through `DATABASE_URL`, so base, head, and other apps on one server do not share one.
- An agent skill in `skills/holdfast/`.
- Ruby 3.4 or newer. Runtime dependencies: hegeltest 0.5.1, jitcatch and branchout (`~> 0.1`).
