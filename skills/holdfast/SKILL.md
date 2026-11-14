---
name: holdfast
description: Run what you suspect instead of leaving it "read only". In a Ruby or Rails app, write each suspicion (a bug, a race, an effect on another area) as a few lines of YAML; `holdfast check` builds the world with the app's factories, runs it on base and head, and answers confirmed (with a failing spec to keep), refuted (with what it saw), or could_not_run (with the exact error). `holdfast run` checks a change against base, and hunts when nothing changed. Use after reading code, before calling a change safe, or when asked to find bugs.
---

# holdfast

## Setup

Add `gem "holdfast", require: false` to the app's `:test` group and run `bundle install`; run every command below as `bundle exec holdfast ...` from the app root. jitcatch and branchout, which `holdfast run` uses on a change, come with it. The app needs RSpec, FactoryBot and a test database on PostgreSQL or SQLite; races and the hunt run on both (MySQL is untested). SQLite lets one connection write at a time, so a race that holds an action after it wrote in its open transaction makes the other wait, and the row says `the second waited on a lock`.

## The loop: read, suspect, check, keep

1. Read the code. Write each thing you suspect in a file, one line of `says` and its `given`, `do` (or `race`) and `expect`. A race or a cross-area effect costs the same few lines; do not leave one "read, not run".
2. `holdfast check suspicions.yml` (or `--suspect '<one YAML mapping>'`, repeatable). Run it from the app root.
3. Keep each confirmed spec, `spec/holdfast/<branch>/<id>_spec.rb` (the header names the folder): it fails until the code is fixed. Report confirmed rows with their spec and refuted rows with what was observed. Fix each could_not_run suspicion and run again.

```yaml
- says: a passed tentative appointment is charged a no-show fee
  given: {appointment: {status: tentative, starts_at: -1h}}
  do: NoShowSweepJob.perform_now
  expect: no PaymentGateway charge
- says: check-in between the sweep's load and its lock becomes a no-show
  given: {appointment: {status: booked, starts_at: -20m}}
  race: [NoShowSweepJob.perform_now, "CheckIn.new(appointment).call"]
  expect: appointment.status == "checked_in"
- says: two desks checking in one appointment both succeed
  given: {appointment: {ruby: "create(:appointment, starts_at: 5.minutes.from_now)"}}
  race: ["CheckIn.new(appointment).call", "CheckIn.new(appointment).call"]
  expect: errors.compact.size == 1 && appointment.status == "checked_in"
- says: a check-in hands back the appointment, checked in
  given: {appointment: {status: booked, starts_at: +5m}}
  do: checked = CheckIn.new(appointment).call
  expect: no error && checked.status == "checked_in"
```

- `given`: one record per key, from the factory of that name (`factory:`, `traits:`). A value is a literal, a relative time (`-1h`, `+2d`, `-20m`), an earlier key, or `{ruby: "..."}`. A string, or `{ruby: "..."}`, in place of the attributes is Ruby that returns the record or any value. An earlier record fills a required `belongs_to` you leave out, and so does what it belongs to.
- `do`: Ruby, with each record by its name. A local or `@name` that `do` sets is what `expect` reads by that name (a record read again). Request helpers work: `post "/api/v1/..."`, then `response`. A 404 the app answers is an outcome; a path no route matches is could_not_run.
- `race`: two actions. The first is held at `pause` while the second runs, then the reverse, and both serial orders. Confirmed only when a held order fails `expect` and ends in a way no serial order ends (ids of records the actions made and times do not count). When a serial order fails `expect` too, the row says so and is refuted as a race, unless the held order's end is new; then the row names that end and each serial end. `pause` is `batch_load` (the first query that returns rows), `outside_call` (the first call to a client such as `PaymentGateway.client`), `row_lock` (before the first `with_lock` or `lock!`), `first_write`, or `Class#method`. With no `pause`, or a `batch_load` nobody reaches, each is tried in that order; the row says which one held.
- `expect`: Ruby that is true afterwards (records read again; `result`, `error`; in a race `results[0]`, `results[1]`, `errors[i]` by the order `race` lists them; `calls(X, :verb)`, the arguments of each call to `X.client`), or `no X verb`, `X verb [once|N times]`, `raises X`, `no error`; these combine with `&&` and `||`. A list must all hold. When `do` raised, a nil `response` or `result` in `expect` is that raise: the line fails and names it. A failed `a && b` names the part that failed and its value.

What to suspect for a race: a lock taken on a different row than the one written (two members booking one room each lock their own member row); a read before the lock (a status or a total read, then `with_lock`); an absolute write after a slow call (`attempts = notice.attempts + 1`, a courier call, then `update!(attempts:)`); check-then-act with no unique index under it (`exists?` then `create!`). Write the two actions and the end no serial order allows; leave `pause` out.

In a change (the tree differs from the base branch, or `--base REF`), each suspicion runs on base and on head with head's factories, and the row says whether the change brought it in. A base that has no such method, constant, column or route says "base cannot run it (feature absent: no column archived_at on Fine)", and the row is confirmed on head only. With no change, or `--here`, it runs once on the tree, and the header says so. Exit 2 when a row is confirmed.

| row | means | do |
|---|---|---|
| `confirmed` | `expect` failed; the spec fails, its output is in the row | Keep the spec. Fix the code. |
| `refuted` | `expect` held; each observed value is listed | Nothing to fix for this suspicion. |
| `could_not_run` | Nothing was checked: the row names the `given` key and its error, the `do` line that raised, a request with no route or one turned away (401, 403), or that no pause point was reached (with the app methods the action called, to name as `pause`) | Fix the suspicion, run again. |

An error that app code raised is how the action ended, and `expect` is checked against it. An error from your own line (a misspelt name, a wrong argument list) is could_not_run. A could_not_run row that starts `holdfast:` failed in holdfast's own support code, and its `next` names the database adapter: neither the suspicion nor the app is the cause. Each branch keeps its own specs and rows: `.holdfast/check/<branch>/check.md` is the summary, `check.jsonl` beside it has every row.

## Check a change: holdfast run

```sh
holdfast run [--base REF] [--intent TEXT] [--target NAME]... [--only NAME]... [--sequences] [--observe] [--budget SECONDS]
```

It compares the working tree with the merge base of REF. Each changed method gets a row; so do the callers of a changed constant or scope, one and two calls up, ranked first. On base and head it runs the tests that name each target, the test files the change edited, your evidence tests, and pins it drafts from the method's parameters. A test counts only when its own example reached the changed lines, not when another example in its file did.

A row is `clean` only when, besides reaching the lines, an input drew each value the change added or removed (a member of a changed list or table constant the target reads, a literal a changed line compares with) on both sides, and a test ran each branch the change added (for `return x if y`, the body itself, not only the line). Otherwise it is `unchecked` and names the value nobody drew: write that as a suspicion and `holdfast check` it.

| kind | do |
|---|---|
| `unintended_change` | Passes on base, fails on head, not marked. Fix the code, or mark it meant (below). |
| `bug_suspect` | A hunt broke a rule or raised. Fix the code, or declare the error. |
| `unchecked` | Do what `next` says. Never report it as safe. |
| `intended_change` | A difference you marked as meant, or new behavior only new specs run (an added method, or an added branch the agreeing tests never took). Confirm the head value is what the intent wants. |
| `clean` | Covers only the evidence it lists. A drafted pin whose inputs built no record (`returns: []` in `.holdfast/runs/<slug>/observed.json`) checked nothing: write the case as a suspicion. |

Evidence goes under `.holdfast/evidence/<slug>` (the row's `next` names the path): `<slug>/*_spec.rb` tests (under `change/` when meant to fail on base), or `<slug>.inputs.json` pin inputs (copy the draft from `.holdfast/drafts/`, fill each `{"fill": ...}`, mark `"change": true` where the intent changes the result). `--target NAME` with nothing changed pins NAME before you edit it.

## Hunt: nothing changed

`holdfast run` with no change drafts one sequences definition per write area into `.holdfast/sequences/` and runs random orders, interleavings, time zones and second doors under invariants (`--budget`, default 600 s). The first line says how much ran: `unreached: N of M actions`. An area that reached under half its actions is never clean; fix its setup or sign-in, then run again. Hunt rows lead you to suspicions: confirm each with `holdfast check`.

Each run tries random orders of an area's actions from a world of drawn size, two actions interleaved at a call into an outside client, a job held after its first batch load while another action changes a row it loaded, a clock at day edges in other time zones, the same instant in another UTC offset, a request the app accepted sent once more with the same inputs (a double click or a retry, shown as `again, as sent before:`), and a desk route and an API endpoint about one table from the same state. Any HTTP 5xx, and any exception the area does not list as a refusal, fails.

The first hunt writes `.holdfast/sequences/invariants.rb`. Its drafted rules (money a record took, the order a waiting status is left in, one row for each `has_one` no unique index holds, and the bounds a column name states: `*_left` and `*_remaining` never below zero, `*_count` never past its `max_*`, a percentage within 0..100) run as written: delete one only when the app means otherwise. Add the rules only you know in the same shape; each returns true when it holds, or a message that names the rows that break it:

```ruby
Sequences.everywhere do
  invariant(:a_checked_in_appointment_is_never_charged) do
    charged = PaymentGateway.client.charges.map(&:reference)
    bad = Appointment.where(status: "checked_in").select { charged.include?("no-show-#{it.id}") }
    bad.empty? || "checked-in appointments #{bad.map(&:id)} were charged a no-show fee"
  end
end
```

A `bug_suspect` row names the broken rule, and its log holds the shortest sequence as a numbered narrative and an `it` block that replays it. Shrinking stops 60 s after the first failure (`SEQ_SHRINK_SECONDS`), and the row then says `shrinking stopped`; when the area's time limit cut it first, the row says `not shrunk`. Either way the log holds the shortest sequence found so far. A twins pair the two doors cannot feed the same inputs (one picks a record the other takes from the sign-in, or one makes a new unique value) is listed as not reached; drop the `twins` line or give both doors the same params. A partly checked area lists each action that was only refused (with up to three refusals, most common first, and the param to change) or never drawn: make the record in the area's `setup`, narrow a `pool`, or change the draws, then run again. An area the time limit stopped between cases says `cut by the time limit after N of M cases`; what ran still counts.

## When setup fails

The first run learns `.holdfast/record.json` (test framework, databases: each side gets its own through `DATABASE_URL`, a name of this app's own on a server and a file under `.holdfast/db/` on SQLite; the app's own test database is never written). A failed step is kept with its command and output, and every row says so. Fix the environment, then `holdfast run --learn`.
