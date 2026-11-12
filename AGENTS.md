# Developing holdfast

This file is for agents changing this repository. The loop for an agent applying holdfast to an app is [`skills/holdfast/SKILL.md`](skills/holdfast/SKILL.md).

## What it is

holdfast checks a Rails app by running it. `holdfast check` turns suspicions written as YAML into specs that build their records with the app's factories, runs them on base and head, and reports each as `confirmed`, `refuted`, or `could_not_run`. `holdfast run` compares a change with its base through jitcatch, branchout, and hegeltest, and with nothing changed it hunts with random sequences of the app's entry points.

## Layout

- `bin/holdfast` is the command. `lib/holdfast/cli.rb` parses it.
- `lib/holdfast/check.rb` parses suspicions and writes one spec per suspicion. `lib/holdfast/runtime/check_support.rb` is copied next to those specs and runs inside the app's test process: it builds `given`, runs and races the actions at a pause point, and writes one JSON report per suspicion.
- `lib/holdfast/record.rb` learns once how the app runs its tests (framework, helper, database names) and keeps it in the app's `.holdfast/record.json`. `lib/holdfast/change.rb` reads base and head; the working tree becomes a commit through a private index.
- `lib/holdfast/harness.rb` runs the stages of `holdfast run`: `stages/select.rb` (targets from jitcatch's change brief), `stages/fill.rb` (pins, run inside the app with branchout), `stages/diff.rb` (base and head through jitcatch's runner), `stages/fold.rb` (one row per target), `stages/hunt.rb`, and `stages/observe.rb`.
- `lib/holdfast/sequences/` is the hunt. `propose.rb` drafts one definition per write area, `sequences.rb` runs a definition inside the app's test process (it needs hegeltest there), and `run.rb` runs every area, each on a numbered database. The hunt stage calls them by path.
- `lib/holdfast/tools.rb` loads jitcatch and finds branchout for the stages of `holdfast run`.
- `skills/holdfast/SKILL.md` is the agent skill that ships in the gem.
- `test/fixture/clinic` is a small Rails app on PostgreSQL with two planted defects, a sweep that charges tentative appointments and a sweep that overwrites a check-in made after its load. The skill's examples and the README's output run against it.

## Visibility

This repository is intended for public release. Write all committed text in English, except `README.ja.md`. Do not reference private tools, private repositories, machine paths, or internal working documents in committed content.

## Rules

- Ruby 3.4 or newer: hegeltest needs it, and the hunt uses `it`.
- The runtime dependencies are hegeltest, pinned exactly, and jitcatch and branchout (`~> 0.1`), which only the stages of `holdfast run` load. Add a dependency only with the owner's approval, pinned exactly, at least 7 days past its release.
- Comments say only a non-obvious why. Each file starts with its responsibility.
- Tests prove behavior by running holdfast on the fixture app. A test never greps source.
- A change to a suspicion form or a row changes `skills/holdfast/SKILL.md` in the same commit, and every YAML example there runs in `test/skill_examples_test.rb`. A change to README.md changes README.ja.md in the same commit: natural Japanese, one sentence per line, no em dash. The output in both READMEs comes from a real run on the fixture.
- Every change that a gem user can notice adds a line under `## [Unreleased]` in `CHANGELOG.md`.
- A release, a gem push, and a change of the repository's visibility are the owner's to run.

## Commands

```sh
bundle install
bundle install --gemfile test/fixture/clinic/Gemfile
DB_HOST=localhost DB_PORT=5432 ruby -Ilib test/run.rb
gem build holdfast.gemspec
```

`test/run.rb` runs every test file. `test/check_parse_test.rb` needs no database. `test/skill_examples_test.rb` and `test/hunt_test.rb` copy the clinic fixture to a temporary directory, commit it, and run `bin/holdfast` there with the fixture's own bundle. They need a PostgreSQL server at `DB_HOST` and `DB_PORT` (user `DB_USER`, default `postgres`, with no password), the fixture's gems, and hegeltest installed for the same Ruby. Without `DB_HOST` they skip; `HOLDFAST_PG=required` turns the skip into a failure, as CI does. They take about 40 seconds.

CI (`.github/workflows/ci.yml`) runs the tests on Ruby 3.4 and 4.0 with a PostgreSQL 16 service, and builds the gem.

To try a command on the fixture by hand, copy `test/fixture/clinic` somewhere, run `git init` and commit it, add `gem "holdfast", path: "<this checkout>"` to its `Gemfile`, run `bundle install`, and run `bundle exec holdfast check --suspect '...'` with `DB_HOST` and `DB_PORT` set.
