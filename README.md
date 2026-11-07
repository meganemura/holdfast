# holdfast

holdfast runs what you suspect about a Rails app instead of leaving it read but not run. You write each suspicion (a bug, a race between two actions, an effect on another area) as a few lines of YAML. `holdfast check` builds the world with the app's own factories, runs the action on base and head, and answers `confirmed` with a failing spec to keep, `refuted` with what it observed, or `could_not_run` with the exact error. `holdfast run` checks a change against its base, and hunts with random sequences of the app's entry points when nothing changed.

It is made for a coding agent that reads code and has to say what it found. The skill in [`skills/holdfast/`](skills/holdfast/SKILL.md) is the loop an agent follows.

## Quick start in your Rails app

You need Ruby 3.4 or newer, git, and an app whose specs run with RSpec and FactoryBot against a test database. Run each step from the app's root.

### 1. Add the gem

```ruby
group :test do
  gem "holdfast", require: false
end
```

Then run `bundle install`. holdfast depends on hegeltest, which the hunt uses.

### 2. Read, and write what you suspect

The examples below run against the clinic app in [`test/fixture/clinic`](test/fixture/clinic): appointments, a job that marks missed appointments as no-shows and charges a fee, and a desk check-in. Reading the job, two things look wrong. It also sweeps tentative appointments, which were never confirmed, and it loads its rows before it locks each one, so a check-in in between may be overwritten. Write both down:

```yaml
- says: a passed tentative appointment is charged a no-show fee
  given: {appointment: {status: tentative, starts_at: -1h}}
  do: NoShowSweepJob.perform_now
  expect: no PaymentGateway charge
- says: check-in between the sweep's load and its lock becomes a no-show
  given: {appointment: {status: booked, starts_at: -20m}}
  race: [NoShowSweepJob.perform_now, "CheckIn.new(appointment).call"]
  expect: appointment.status == "checked_in"
```

`given` makes one record per key from the factory of that name. `do` is Ruby. `race` holds the first action at a pause point while the second runs, then the reverse, and also runs both serial orders. `expect` is what must be true afterwards. The [skill](skills/holdfast/SKILL.md) lists every form.

### 3. Check

```sh
bundle exec holdfast check suspicions.yml
```

The first run learns how the app runs its tests and makes test databases of its own. This is the whole output on the clinic app:

```text
# holdfast

check: 2 suspicion(s); no change: checks run on the current tree only (af23e82); app, lib, config, db and the Gemfile match main (a17770f)
kept specs: spec/holdfast/main/ (branch main); rows: .holdfast/check/main/check.jsonl
seconds: record 9.6, run 5.5

confirmed=2 could_not_run=0 refuted=0

## Confirmed (the kept spec fails)

- `a passed tentative appointment is charged a no-show fee`: no PaymentGateway charge does not hold (observed [[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]])
  - ran: NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]
  - no PaymentGateway charge fails ([[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]])
  - spec output: suspicion confirmed: no PaymentGateway charge does not hold (observed [[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]])
  - repro: `DATABASE_URL=postgres://postgres@127.0.0.1:56111/hf_clinic_9f0097_c2 TEST_ENV_NUMBER=c2 bundle exec rspec spec/holdfast/main/s1_a_passed_tentative_appointment_is_charged_a_no_s_spec.rb`
  - next: keep spec/holdfast/main/s1_a_passed_tentative_appointment_is_charged_a_no_s_spec.rb; it fails until the code is fixed
- `check-in between the sweep's load and its lock becomes a no-show`: first held at batch_load, second runs (held at Appointment load (1 rows)) ends [[Appointment#1(status: "no_show")], Appointment#1(status: "checked_in"); appointment.status == "checked_in" fails ("no_show")], an end no serial order reaches (first then second ends [[Appointment#1(status: "no_show")], raised CheckIn::Refused; appointment.status == "checked_in" fails ("no_show")]; second then first ends [[], Appointment#1(status: "checked_in"); appointment.status == "checked_in" holds ("checked_in")]); serial order "first then second" also fails expect, so this end is the evidence
  - pause points tried: batch_load: Appointment load (1 rows)
  - first held at batch_load, second runs: NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]; CheckIn.new(appointment).call returned Appointment#1(status: "checked_in"); held at Appointment load (1 rows); appointment.status == "checked_in" fails ("no_show")
  - first then second: NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]; CheckIn.new(appointment).call raised CheckIn::Refused: appointment is no_show; appointment.status == "checked_in" fails ("no_show")
  - second then first: CheckIn.new(appointment).call returned Appointment#1(status: "checked_in"); NoShowSweepJob.perform_now returned []; appointment.status == "checked_in" holds ("checked_in")
  - second held at batch_load, first runs: CheckIn.new(appointment).call returned Appointment#1(status: "checked_in"); NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]; held at Appointment load (1 rows); the second waited on a lock; appointment.status == "checked_in" fails ("no_show")
  - spec output: suspicion confirmed: first held at batch_load, second runs (held at Appointment load (1 rows)) ends [[Appointment#1(status: "no_show")], Appointment#1(status: "checked_in"); appointment.status == "checked_in" fails ("no_show")], an end no serial order reaches (first then second ends [[Appointment#1(status: "no_show")], raised CheckIn::Refused; appointment.status == "checked_in" fails ("no_show")]; second then first ends [[], Appointment#1(status: "checked_in"); appointment.status == "checked_in" holds ("checked_in")]); serial order "first then second" also fails expect, so this end is the evidence
  - repro: `DATABASE_URL=postgres://postgres@127.0.0.1:56111/hf_clinic_9f0097_c2 TEST_ENV_NUMBER=c2 bundle exec rspec spec/holdfast/main/s2_check_in_between_the_sweep_s_load_and_its_lock_b_spec.rb`
  - next: keep spec/holdfast/main/s2_check_in_between_the_sweep_s_load_and_its_lock_b_spec.rb; it fails until the code is fixed
rows: .holdfast/check/main/check.jsonl; kept specs: spec/holdfast/main/
```

The race is confirmed only because the held order ends in a state that no serial order reaches. A race whose end some serial order also reaches is refuted.

### 4. Keep

Each confirmed row names a spec under `spec/holdfast/<branch>/` that fails until the code is fixed. Fix the code, run the spec, and keep it. After the sweep selects only booked appointments, the first spec passes:

```sh
bundle exec rspec spec/holdfast/main/s1_a_passed_tentative_appointment_is_charged_a_no_s_spec.rb
```

```text
1 example, 0 failures
```

Exit status 2 means a row was confirmed, 1 a usage error, and 0 that nothing was confirmed.

## Check a change

On a branch that differs from the base branch (`--base REF` names another), each suspicion runs on base and on the working tree, both with head's factories, and the row says whether the change brought it in. Here the branch `skip-tentative` changes the sweep to select only booked appointments, and the same file runs again:

```text
# holdfast

check: 2 suspicion(s); change: each runs on base main (a17770f) and on the working tree (a0a7f53); 1 file(s) differ: app/jobs/no_show_sweep_job.rb
kept specs: spec/holdfast/skip-tentative/ (branch skip-tentative); rows: .holdfast/check/skip-tentative/check.jsonl
seconds: record 0.0, run 5.6

confirmed=1 could_not_run=0 refuted=1

## Confirmed (the kept spec fails)

- `check-in between the sweep's load and its lock becomes a no-show`: first held at batch_load, second runs (held at Appointment load (1 rows)) ends [...]
  - base a17770f: confirmed: [...]; it was there before the change
  [...]

## Refuted (what was observed)

- `a passed tentative appointment is charged a no-show fee`: no PaymentGateway charge holds (observed [])
  - base a17770f: confirmed: no PaymentGateway charge does not hold (observed [[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]]); the change removes it
  - ran: NoShowSweepJob.perform_now returned []
  - no PaymentGateway charge holds ([])
rows: .holdfast/check/skip-tentative/check.jsonl; kept specs: spec/holdfast/skip-tentative/
```

`[...]` marks text cut from the race row, which repeats the row above. A suspicion that calls a method, a column or a route that base does not have is confirmed on head only, and the row says that base cannot run it.

`holdfast run` checks a change without suspicions. It gives each changed method a row, and the callers of a changed constant or scope too, runs the tests that name each target on base and head, and drafts pins from each method's parameters. A row is `unintended_change` (passes on base, fails on head), `intended_change` (a difference you marked as meant), `unchecked` (with the value nobody drew, to write as a suspicion), or `clean` (covering only the evidence it lists). This part needs [jitcatch](https://github.com/meganemura/jitcatch) and [branchout](https://github.com/meganemura/branchout), which are not on RubyGems yet. Without them, `holdfast run` on a change exits 1 and says how to install them.

## Hunt when nothing changed

`holdfast run` with no change drafts one sequence definition per write area of the app (routes, Grape endpoints, jobs) into `.holdfast/sequences/`. It then runs random orders of their actions against the test database, under invariants, other time zones, two actions interleaved at an outside call, and a job held after its first batch load. A failure is shrunk to the shortest sequence. `--budget SECONDS` caps the run (default 600). On the clinic app, with a budget of 120 seconds:

```text
# holdfast

nothing in the app changed against main (27257f9)
note: HUNT REACHED LITTLE: unreached: 1 of 2 actions (refused every time or never drawn); 0 of 1 areas reached under half
seconds: record 10.1, hunt 16.8

unintended_change=0 bug_suspect=1 unchecked=1 intended_change=0 clean=0

## Suspected bugs

- `sequences: check_ins`: no_show_sweep_job loaded Appointment#1 with status "booked"; check_ins_create set it to "checked_in" while no_show_sweep_job held it; no_show_sweep_job then wrote "no_show", though its own query does not select a row whose status is "checked_in"
  - failure: no_show_sweep_job loaded Appointment#1 with status "booked"; check_ins_create set it to "checked_in" while no_show_sweep_job held it; no_show_sweep_job then wrote "no_show", though its own query does not select a row whose status is "checked_in"
  - log: .holdfast/runs/sequences/check_ins.log (the shortest sequence and an `it` block that replays it)
  - next: paste the `it` block from the log into .holdfast/sequences/check_ins.rb, see it fail, fix the code, run again

## Not checked

- `(hunt)`: unreached: 1 of 2 actions (refused every time or never drawn); 0 of 1 areas reached under half
  - next: read each area's row below for the refusals, fix the setup or the sign-in in its file, then holdfast run; until then the hunt says little about these areas
rows: .holdfast/verdicts.jsonl
```

The hunt found the same race as the second suspicion, with no suspicion written. A hunt row leads to a suspicion: write it down and confirm it with `holdfast check`. `holdfast run --sequences` also hunts over the areas a change touches, and `--observe` runs each area's action orders on base and head and reports each step that differs.

## Usage

```text
holdfast check [FILE]... [--suspect YAML]... [--base REF] [--here] [--repo DIR]
holdfast run [--base REF] [--target NAME]... [--only NAME]... [--intent TEXT] [--learn] [--sequences] [--observe] [--budget SECONDS] [--repo DIR]
holdfast show
```

- `--suspect YAML` passes one suspicion as a YAML flow mapping, and repeats.
- `--here` runs a check once on the working tree, even in a change.
- `--learn` learns again how the app runs its tests, after you fix a failed setup.
- `show` prints the last summary of `holdfast run` again.

holdfast writes under `.holdfast/` and `spec/holdfast/` in the app. Add `.holdfast/` to the app's `.gitignore`. Commit the specs you keep.

Each app gets its own test database names through `DATABASE_URL`, made from its directory, so base and head, and two apps on one server, do not share one. The setup runs `bin/rails db:create db:schema:load`.

## Limits

- A drafted pin whose inputs build no record checks nothing, and `holdfast run` can still list its target as `clean` when the pin loads the changed line. Read the evidence of a `clean` row before you trust it.
- A race is tried at the pause points `batch_load`, `outside_call`, `row_lock`, `first_write`, or a method you name. Other interleavings are not tried.
- The hunt reaches only the actions whose drafted setup and sign-in work. The first line says how many it did not reach.

## Development

```sh
bundle install
bundle install --gemfile test/fixture/clinic/Gemfile
DB_HOST=localhost DB_PORT=5432 ruby -Ilib test/run.rb
```

Without `DB_HOST`, the tests that run the clinic app skip. [AGENTS.md](AGENTS.md) has the details.

## License

MIT

---

[Japanese](README.ja.md)
