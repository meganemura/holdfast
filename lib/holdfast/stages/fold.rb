module Holdfast
  module Stages
    # Turns the test outcomes, the lines each test file ran, the pins and the
    # gaps into one row per changed method, plus one row per changed value
    # for the readers that sit outside every changed method. A row is
    # compared only when a test or a pin ran on both sides and reached the
    # target's changed lines in this run; a test that only names the method
    # is listed and does not count.
    module Fold
      ORIGIN_ORDER = ["drafted pin", "inputs pin", "evidence", "authored", "kept"].freeze

      def self.run(change, targets, diff, pins, gaps)
        lines = changed_lines(change)
        methods = targets.select(&:method?)
        readers = targets.select { _1.kind == "reader" }
        inside, outside = readers.partition { |r| methods.any? { within?(r, _1) } }
        owner = owners(diff, methods, lines)
        rows = methods.map do |t|
          row = method_row(t, diff, lines, owner, pins.find { _1.target == t }, gaps.find { _1.target == t }, inside.select { within?(_1, t) }, change)
          # An unchanged method's row says which changed value it reads; a
          # caller's row ranks first.
          t.unchanged? && t.why[1] ? row.with(stage: t.caller? ? "caller" : row.stage, reason: "#{t.why[1]}; #{row.reason}") : row
        end
        rows += outside.group_by { _1.reader ? _1.reader["value"] : _1.name }.map { |value, rs| value_row(value, rs, diff, owner, change) }
        # A failure a value row already lists (its file ran a reader's line)
        # is not repeated as a row of its own.
        stray = diff.outcomes.each_with_index.select { |o, i| o.kind != "clean" && owner[i].nil? && outside.none? { reads_line?(diff, o, _1) } }
        # A new spec with no base side states nothing to compare; a test
        # that reached no changed line and did not break on head is not
        # something the change can reach. Both stay in verdicts.jsonl only.
        rows += stray.map { |o, _| stray_row(o) }
        fold_into_failures(rows)
      end

      # An added method whose only comparison is a failing caller is part of
      # that caller's row, not a row of its own.
      def self.fold_into_failures(rows)
        folded, kept = rows.partition { _1.stage.start_with?("under:") }
        kept.map do |row|
          mine = folded.select { _1.stage == "under:#{row.target}" }
          next row if mine.empty?

          row.with(evidence: row.evidence.first(1) + ["it runs through added #{mine.map(&:target).join(", ")}, which have no base side of their own"] + row.evidence.drop(1))
        end
      end

      # file => { "base" => [lines], "head" => [lines] } from the diff hunks.
      def self.changed_lines(change)
        diff = Change.git(change.root, "diff", "--unified=0", change.base, change.head, "--", "app", "lib")
        out = Hash.new { |h, k| h[k] = { "base" => [], "head" => [] } }
        file = nil
        diff.each_line do |l|
          file = l[6..].strip if l.start_with?("+++ b/")
          next unless (m = l.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)) && file

          out[file]["base"] += (m[1].to_i...(m[1].to_i + (m[2] || 1).to_i)).to_a
          out[file]["head"] += (m[3].to_i...(m[3].to_i + (m[4] || 1).to_i)).to_a
        end
        out
      end

      # The changed lines of a method's body. Ruby runs a `def` line when
      # the file loads, so a test that only loaded the file would count as
      # reaching it; a change to the signature alone counts the whole body.
      def self.method_lines(t, lines)
        span = t.span
        # An unchanged method that reads a changed value has no changed line
        # of its own; running any line of its body is reaching it.
        if t.unchanged?
          whole = ->(from, to) { from && to ? (to > from + 1 ? ((from + 1)..(to - 1)) : (from..to)).to_a : [] }
          return { "head" => whole.(span["new_start"], span["new_end"]), "base" => whole.(span["old_start"], span["old_end"]) }
        end
        all = lines[t.file]
        body = ->(from, to, changed) do
          return [] unless from && to

          inner = (to > from + 1 ? ((from + 1)..(to - 1)) : (from..to)).to_a
          (changed & inner).then { _1.empty? && (changed & (from..to).to_a).any? ? inner : _1 }
        end
        { "head" => body.(span["new_start"], span["new_end"], all["head"]), "base" => body.(span["old_start"], span["old_end"], all["base"]) }
      end

      def self.within?(reader, t) = reader.file == t.file && t.span["new_start"] && (t.span["new_start"]..t.span["new_end"]).cover?(reader.line)

      def self.hits(diff, outcome, side, file) = diff.reach.dig(outcome.source.path, side == "base" ? "1" : "2", file) || []

      def self.reached?(diff, outcome, t, lines)
        want = method_lines(t, lines)
        %w[head base].any? { |side| (hits(diff, outcome, side, t.file) & want[side]).any? }
      end

      def self.reads_line?(diff, outcome, reader) = hits(diff, outcome, "head", reader.file).include?(reader.line)

      # Each outcome that is not clean belongs to one row, so a failure is
      # never listed twice: its own target for a pin or an evidence test,
      # else the first changed method whose lines its file ran.
      def self.owners(diff, methods, lines)
        diff.outcomes.each_with_index.to_h do |o, i|
          own = methods.find { o.source.origin !~ /kept|authored/ && o.source.targets.include?(_1.name) }
          hit = methods.select { reached?(diff, o, _1, lines) }
          stem = File.basename(o.source.path).sub(/_(spec|test)\.rb\z/, "")
          own ||= hit.find { |m| m.name.split(/[#.]/).first.split("::").map { Holdfast.snake(_1) }.include?(stem) } || hit.first
          [i, own&.name]
        end
      end

      def self.draw_step(t, undrawn, gap)
        value = undrawn.find(&:value)
        how = value ? "an input whose record holds #{value.label}" : "an input that takes #{undrawn.first.label}"
        place = gap&.draft ? "fill #{rel(gap.draft.path)} and copy it to .holdfast/evidence/" : "add it to .holdfast/evidence/#{Holdfast.slug(t.name)}.inputs.json"
        "draw #{how}: #{place}, or write it as a suspicion for holdfast check; then holdfast run"
      end

      def self.method_row(t, diff, lines, owner, pin, gap, readers, change)
        want = method_lines(t, lines)
        span = (want["head"].empty? ? want["base"] : want["head"]).then { _1.empty? ? "" : " #{t.file.split("/").last}:#{_1.min}#{"-#{_1.max}" if _1.max > _1.min}" }.then { _1.empty? ? " its changed lines" : _1 }
        mine = diff.outcomes.each_with_index.select { |o, i| owner[i] == t.name || (o.kind == "clean" && (reached?(diff, o, t, lines) || o.source.targets.include?(t.name))) }.map(&:first)
        reached, named = mine.partition { reached?(diff, _1, t, lines) }
        details = groups(reached).map { "#{_1} reach#{"es" if _1.start_with?("1 ")} the changed lines" } +
                  groups(named).map { "#{_1} name#{"s" if _1.start_with?("1 ")} it but did not reach the changed lines" }
        details += pin_details(pin) if pin
        new_specs = (reached + named).select { _1.kind == "no_base" }
        if new_specs.any?
          files = new_specs.map { Diff.shown_path(_1.source) }.uniq
          details << "new spec, no base side: #{new_specs.size} example(s) in #{files.first(2).join(", ")}#{" +#{files.size - 2}" if files.size > 2} pass on head; base cannot load what they call, so they are not a comparison"
        end
        details += readers.map { |r| "reader #{r.file}:#{r.line} (#{r.why.last}): #{diff.outcomes.any? { reads_line?(diff, _1, r) } ? "reached by a test" : "no test reached it"}" }
        bad = reached.select { _1.kind == "unintended_change" } + named.select { _1.kind == "unintended_change" }
        meant = reached.select { _1.kind == "intended_change" }
        agree = reached.select { _1.kind == "clean" }
        base = { target: t.name, stage: "diff", scope: (reached + named).map(&:place).uniq.join(", ") }
        if bad.any?
          first = bad.min_by { ORIGIN_ORDER.index(_1.source.origin) || 9 }
          Verdict.of(**base, kind: "unintended_change", reason: "#{count(bad, first)} passes on base and fails on head",
                     evidence: ["#{first.test["name"].to_s.sub(/\A.*? input /, "input ")}: #{difference(first, 4)}"] + details, repro: first.repro, next_step: first.next_step)
        elsif t.added? && (elsewhere = reached_failures(diff, t, lines, owner)).any?
          Verdict.of(**base, stage: "under:#{elsewhere.first}", kind: "unchecked", reason: "added; its callers are its only comparison, and #{elsewhere.first} fails",
                     evidence: details, next_step: "settle #{elsewhere.first} first, then holdfast run")
        elsif meant.any?
          first = meant.first
          Verdict.of(**base, kind: "intended_change", reason: "#{count(meant, first)} differs as marked: #{difference(first, 1)}",
                     evidence: details, repro: first.repro, next_step: "confirm the head value is the one the intent wants")
        elsif agree.any? && (undrawn = Drawn.missing(Drawn.needs(change, t, lines), reached, diff.reach)).any?
          # Its tests ran its lines, but none drew a value the change added
          # or removed, so agreeing says nothing about that value.
          Verdict.of(**base, kind: "unchecked", reason: "#{agree.size} test(s) ran it on both sides and agree, but no input drew #{undrawn.first(3).map(&:label).join(", ")}#{" (+#{undrawn.size - 3} more)" if undrawn.size > 3}",
                     evidence: undrawn.map { "not drawn: #{_1.label} (#{_1.why})" } + Drawn.one_sided(undrawn, reached, diff.reach) + details,
                     next_step: draw_step(t, undrawn, gap))
        elsif agree.any?
          Verdict.of(**base, kind: "clean", reason: t.added? ? "added; #{agree.size} test(s) of its callers ran on both sides, reached it on head, and agree" : "#{agree.size} test(s) ran on both sides, reached#{span}, and agree",
                     evidence: details, next_step: "nothing; the claim covers only the tests in scope")
        else
          unchecked_method(t, base, details, span, pin, gap)
        end
      end

      def self.reached_failures(diff, t, lines, owner)
        diff.outcomes.each_with_index.filter_map { |o, i| owner[i] if o.kind == "unintended_change" && owner[i] != t.name && reached?(diff, o, t, lines) }.uniq
      end

      def self.unchecked_method(t, base, details, span, pin, gap, why: nil)
        why ||= t.added? ? "added, and no test reached it on head" : "no test or pin ran on both sides and reached#{span}"
        step = if gap&.draft
                 "fill #{gap.draft.holes.join(", ")} in #{rel(gap.draft.path)}, copy it to .holdfast/evidence/, then holdfast run"
               elsif pin
                 "the #{pin.origin} inputs (#{rel(pin.inputs.file)}) did not reach#{span}; add inputs that take it, then holdfast run"
               elsif t.added?
                 "write a test that states what #{t.name} does in .holdfast/evidence/#{Holdfast.slug(t.name)}/, or name it from a caller's pin"
               else
                 "write a test in .holdfast/evidence/#{Holdfast.slug(t.name)}/ that reaches#{span}, then holdfast run"
               end
        details += ["draft: #{gap.reason}"] if gap && !gap.draft
        Verdict.of(**base, kind: "unchecked", reason: why, evidence: details, next_step: step)
      end

      def self.pin_details(pin)
        out = ["#{pin.observed.count { !_1["input_error"] }} #{pin.origin == "drafted" ? "drafted" : "given"} input(s) pinned at #{pin.rev[0, 7]} from #{rel(pin.inputs.file)}"]
        out << "#{pin.input_errors.size} input(s) did not build: #{pin.input_errors.first}" if pin.input_errors.any?
        frontier = Array(pin.report["frontier"]).reject { |f| Array(pin.report["covered"]).any? { _1["id"] == f["id"] } }.uniq { _1["id"] }
        out << "arms no input took: #{frontier.first(3).map { "#{_1["loc"]} #{_1["sense"]} `#{_1["cond"]}`" }.join("; ")}" if frontier.any?
        out
      end

      def self.value_row(value, readers, diff, owner, change)
        ran = diff.outcomes.each_with_index.select { |o, _| readers.any? { reads_line?(diff, o, _1) } }
        bad = ran.select { |o, i| o.kind == "unintended_change" && owner[i].nil? }.map(&:first)
        unreached = readers.reject { |r| ran.any? { |o, _| reads_line?(diff, o, r) } }
        details = readers.map { |r| "#{r.file}:#{r.line} #{r.why.first.sub(/ \(.*\)\z/, "")}: #{unreached.include?(r) ? "no test reached it" : "reached by #{ran.count { |o, _| reads_line?(diff, o, r) }} test(s)"}" }
        base = { target: value, stage: "readers", evidence: details }
        if bad.any?
          Verdict.of(**base, evidence: ["#{bad.size} failing test(s), first #{bad.first.place}"] + details,
                     kind: "unintended_change", reason: "a test that reads it fails on head: #{difference(bad.first)}", repro: bad.first.repro, next_step: bad.first.next_step)
        elsif unreached.empty? && (undrawn = Drawn.missing(Drawn.lookup(Drawn.constants(change), value.to_s)&.then { Drawn.members_needs(value.to_s, _1) } || [], ran.map(&:first), diff.reach)).any?
          Verdict.of(**base, kind: "unchecked", reason: "every reader was reached by a test, but no input drew #{undrawn.first(3).map(&:label).join(", ")}",
                     evidence: undrawn.map { "not drawn: #{_1.label} (#{_1.why})" } + details,
                     next_step: "write a test or a suspicion (holdfast check) whose record holds #{undrawn.first.label} and that runs #{readers.first.name}; then holdfast run")
        elsif unreached.empty?
          Verdict.of(**base, kind: "clean", reason: "every reader outside the changed methods was reached by a test that ran on both sides",
                     next_step: "nothing; the claim covers only the tests that reached each line")
        else
          r = unreached.first
          sentence = r.reader ? r.reader["test"] : "Write a test that runs #{r.name}."
          Verdict.of(**base, kind: "unchecked", reason: "#{unreached.size} of #{readers.size} reader(s) no test reached",
                     next_step: "#{sentence} Put it in .holdfast/evidence/#{Holdfast.slug(r.name)}/, then holdfast run")
        end
      end

      def self.stray_row(o)
        kind = o.kind == "no_base" ? "unchecked" : o.kind
        Verdict.of(target: o.place, stage: "diff", kind:, reason: "#{o.source.origin} test, which reached no changed method: #{o.reason}",
                   evidence: [o.evidence], repro: o.repro, shown: o.kind == "unintended_change",
                   next_step: o.kind == "no_base" ? "nothing to compare; check what it exercises through an existing caller or a pin" : o.next_step)
      end

      def self.groups(outcomes)
        outcomes.group_by { _1.source.origin }.sort_by { ORIGIN_ORDER.index(_1.first) || 9 }.map do |origin, os|
          files = os.map { Diff.shown_path(_1.source) }.uniq
          tally = os.map(&:kind).tally.map { |k, n| "#{n} #{k == "clean" ? "agree" : k == "no_base" ? "with no base side" : k.tr("_", " ")}" }.join(", ")
          "#{files.size} #{origin} file#{"s" if files.size > 1} (#{tally}; #{files.first(2).join(", ")}#{" +#{files.size - 2}" if files.size > 2})"
        end
      end

      def self.count(list, first)
        same = list.count { _1.source.origin == first.source.origin }
        same > 1 ? "#{same} #{first.source.origin} examples (first: #{first.place})" : "#{first.source.origin} #{first.place}"
      end

      # A pin failure lists the paths that differ; a test failure is its message.
      def self.difference(o, limit = 3)
        text = [o.test.dig("head", "message"), o.test.dig("base", "message")].compact.find { !_1.strip.empty? }.to_s
        if text.include?("differs: ")
          parts = text[/differs: (.*)/, 1].strip.split(" | ")
          return parts.first(limit).join(" | ") + (parts.size > limit ? " (+#{parts.size - limit} more)" : "")
        end

        text.lines.map(&:strip).reject(&:empty?).first(2).join(" ")[0, 200].then { _1.empty? ? o.evidence : _1 }
      end

      def self.rel(path) = path.to_s.sub(%r{\A.*?/\.holdfast/}, ".holdfast/")
    end
  end
end
