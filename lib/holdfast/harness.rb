# rbs_inline: enabled

module Holdfast
  # One run: read the record and the change, then run the stages the change
  # calls for. The harness decides what runs from the change alone; the
  # caller only adds evidence (tests, pin inputs) between runs.
  #   change  select -> fill (inputs or drafts) -> diff -> fold, one row per target
  #           (+ hunt over the changed areas with --sequences)
  #   before  select the named targets -> fill and vary -> one row per target
  #   hunt    nothing changed and nothing named: sequences over the whole app
  module Harness
    Result = Data.define(
      :change, #: Change
      :verdicts, #: Array[Verdict]
      :notes, #: Array[String]
      :seconds #: Hash[String, Float]
    )

    # @rbs root: String
    # @rbs base: String?
    # @rbs named: Array[String]
    # @rbs relearn: bool?
    # @rbs only: Array[String]
    # @rbs sequences: bool?
    # @rbs budget: Integer?
    # @rbs observe: bool?
    # @rbs intent: String?
    # @rbs return: Result
    def self.run(root, base:, named:, relearn: false, only: [], sequences: false, budget: nil, observe: false, intent: nil)
      timings = {} #: Hash[String, Float]
      record = timed(timings, "record") { Record.load_or_learn(root, relearn:) }
      change = Change.read(root, base_ref: base || record.base_branch, named:)
      unless record.ok?
        return Result.new(change:, notes: [], seconds: timings, verdicts: [
          Verdict.of(target: "(all)", stage: "record", kind: "unchecked",
                     reason: "project setup failed (#{record.failure}); see .holdfast/record.json steps",
                     next_step: "fix the environment the failed step names, then holdfast run --learn")
        ])
      end

      verdicts = [] #: Array[Verdict]
      notes = [] #: Array[String]
      if change.mode == "hunt"
        verdicts += timed(timings, "hunt") { Stages::Hunt.run(change, record, budget:) }
      else
        Tools.jitcatch!
        selected = timed(timings, "select") { Stages::Select.run(change, record) }
        targets = only.empty? ? selected.targets : selected.targets.select { only.include?(_1.name) }
        notes += selected.notes + ["targets: #{targets.count(&:method?)} method(s), #{targets.count { _1.kind == "reader" }} reader(s)"]
        verdicts += selected.verdicts
        pins, gaps = timed(timings, "fill") { Stages::Fill.run(change, record, targets) }
        if change.changed?
          lines = Stages::Fold.changed_lines(change)
          values = targets.flat_map { Drawn.needs(change, _1, lines) }.filter_map(&:value).uniq
          diff = timed(timings, "diff") { Stages::Diff.run(change, record, targets, pins, values:) }
          notes << "diff: #{diff.failure}" if diff.failure
          verdicts += Stages::Fold.run(change, targets, diff, pins, gaps)
          verdicts += timed(timings, "observe") { Stages::Observe.run(change, record, intent:, files: changed_files(change)) } if observe
          verdicts += timed(timings, "sequences") { Stages::Hunt.run(change, record, budget:, files: changed_files(change)) } if sequences
        else
          verdicts += pins.flat_map { before_rows(change, _1) } + gaps.map { gap_row(_1) }
        end
      end
      reach = verdicts.find { _1.target == "(hunt)" }
      notes.unshift("#{reach.reason.include?("; 0 of ") ? "hunt" : "HUNT REACHED LITTLE"}: #{reach.reason}") if reach
      notes << "sequences: not run; add --sequences before a pull request" if change.changed? && !sequences
      Result.new(change:, verdicts: verdicts.sort_by { [_1.target == "(hunt)" ? -1 : KINDS.index(_1.kind), _1.stage == "caller" ? 0 : 1, _1.target] }, notes:, seconds: timings)
    end

    #: (Change) -> Array[String]
    def self.changed_files(change) = Change.git(change.root, "diff", "--name-only", change.base, change.head, "--", "app").lines.map(&:strip)

    #: [T] (Hash[String, Float] timings, String name) { () -> T } -> T
    def self.timed(timings, name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      timings[name] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    end

    #: (Change, Stages::Fill::Pins) -> Array[Verdict]
    def self.before_rows(change, pins)
      declared = pins.inputs.declared_errors
      # An error the method raises itself (`raise Refused, ...`) is its
      # behavior, and the pin holds it; only another error is a suspect.
      own = ->(klass) { pins.target.source.to_s.match?(/raise\s+(#{Regexp.escape(klass)}|#{Regexp.escape(klass.split("::").last)})\b/) }
      raised = pins.observed.select { _1["raises"] && !declared.include?(_1["raises"]) && !own.(_1["raises"]) }
      details = Stages::Fold.pin_details(pins)
      pins.observed.filter_map { _1["raises"] if _1["raises"] && own.(_1["raises"]) }.tally.each { |k, n| details << "#{n} input(s) raise #{k}, which the method raises itself; pinned" }
      rows = raised.group_by { _1["raises"] }.map do |klass, same|
        Verdict.of(target: pins.target.name, stage: "fill", kind: "bug_suspect",
                   reason: "#{same.size} input(s) raised #{klass}: #{same.first["message"]}",
                   evidence: details, next_step: "fix the code, or mark the input \"raises\": \"#{klass}\" in #{Stages::Fold.rel(pins.inputs.file)} if that error is the behavior")
      end
      ran = pins.observed.count { !_1["input_error"] }
      kind = ran.zero? ? "unchecked" : "clean"
      rows << Verdict.of(target: pins.target.name, stage: "fill", kind:,
                         reason: ran.zero? ? "no input ran" : "pinned #{ran} input(s) at #{change.tree_label} by what each returns, raises and writes",
                         evidence: details + pins.target.tests.first(3).map { "selected test: #{_1}" },
                         scope: pins.dir.delete_prefix("#{change.root}/"),
                         next_step: ran.zero? ? "fix the inputs the evidence names, then holdfast run" : "make the change, then holdfast run; these pins are compared on both sides")
      rows
    end

    #: (Stages::Fill::Gap) -> Verdict
    def self.gap_row(gap)
      step = gap.draft ? "fill #{gap.draft.holes.join(", ")} in #{Stages::Fold.rel(gap.draft.path)}, copy it to .holdfast/evidence/, then holdfast run" : "write .holdfast/evidence/#{Holdfast.slug(gap.target.name)}.inputs.json, then holdfast run"
      Verdict.of(target: gap.target.name, stage: "fill", kind: "unchecked", reason: "no pin: #{gap.reason}", next_step: step)
    end
  end
end
