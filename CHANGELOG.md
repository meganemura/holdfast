# Changelog

## Unreleased

First release.

- `holdfast check FILE... [--suspect YAML]...` turns each suspicion (`says`, `given`, `do` or `race`, `pause`, `expect`) into a spec that builds its records with the app's factories, runs it on base and on the working tree, and reports `confirmed` with the kept spec, `refuted` with the observed values, or `could_not_run` with the error and the part of the suspicion it came from. A `race` holds one action at a pause point (`batch_load`, `outside_call`, `row_lock`, `first_write`, or a method) while the other runs, and is confirmed only when that order ends in a state no serial order reaches. With no change, or `--here`, a check runs once on the working tree.
- `holdfast run` checks a change against its base: one row per changed method and per caller of a changed constant or scope, from the tests that name it, the test files the change edited, evidence under `.holdfast/evidence/`, and pins drafted from the method's parameters. It needs jitcatch and branchout, which are not on RubyGems yet; without them it exits 1 and says how to install them. A test counts by its own example's lines and, for a branch on one line such as `return x if y`, by the arm it took. New behavior that only the change's new specs run is `intended_change`, and a controller action gets no drafted pin, since it needs a request.
- `holdfast run` with nothing changed drafts one sequence definition per write area into `.holdfast/sequences/` and hunts with random orders, interleavings at an outside call or a batch load, other time zones and UTC offsets, and a desk route against an API endpoint, under drafted and written invariants. `--sequences` hunts over the areas a change touches, and `--observe` compares each area's action orders on base and head. The drafted world uses a parent a unique index holds to one child only once, and sets a capacity column only when the record stays valid with it. A rule the drafted setup breaks before any action is reported as unchecked, not as a suspected bug, and the unreached line names each thin area's file and its first unreached actions.
- Each app gets its own test database names through `DATABASE_URL`, so base, head, and other apps on one server do not share one.
- An agent skill in `skills/holdfast/`.
- Ruby 3.4 or newer. The one runtime dependency is hegeltest 0.4.1.
