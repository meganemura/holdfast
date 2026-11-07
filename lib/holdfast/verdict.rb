module Holdfast
  # The one row every stage returns: one per changed method, per changed
  # value, or per hunted area. +evidence+ is the list of what was checked
  # under it (tests that reached the changed lines, pins, readers), so a row
  # never reads as more than it covered. +next_step+ is the one thing to do
  # after reading it; every row has one.
  Verdict = Data.define(:target, :stage, :kind, :reason, :scope, :evidence, :repro, :next_step, :shown) do
    def self.of(target:, stage:, kind:, reason:, next_step:, scope: nil, evidence: nil, repro: nil, shown: true)
      raise ArgumentError, "unknown verdict kind #{kind}" unless KINDS.include?(kind)
      raise ArgumentError, "a verdict needs a next step" if next_step.to_s.empty?

      new(target:, stage:, kind:, reason:, scope: scope.to_s.empty? ? nil : scope, evidence: Array(evidence), repro:, next_step:, shown:)
    end

    def to_json_line
      JSON.generate({ "target" => target, "stage" => stage, "kind" => kind, "reason" => reason, "scope" => scope,
                      "evidence" => (evidence unless evidence.empty?), "repro" => repro, "next" => next_step, "shown" => (false unless shown) }.compact)
    end
  end

  # The order a person reads in: what needs a decision first.
  KINDS = %w[confirmed unintended_change bug_suspect could_not_run unchecked intended_change refuted clean].freeze

  # One screen: a row that needs nothing is one line; a row that needs a
  # decision shows its evidence, its repro and its next step. Everything
  # else is in verdicts.jsonl.
  module Summary
    HEADINGS = {
      "confirmed" => "Confirmed (the kept spec fails)",
      "unintended_change" => "Changed, and the intent did not say so",
      "bug_suspect" => "Suspected bugs",
      "could_not_run" => "Could not run",
      "unchecked" => "Not checked",
      "intended_change" => "Changed as intended (confirm against the intent)",
      "refuted" => "Refuted (what was observed)",
      "clean" => "Compared on both sides and unchanged"
    }.freeze
    SHOWN = { "confirmed" => 8, "could_not_run" => 3, "refuted" => 3, "unintended_change" => 4, "bug_suspect" => 4, "unchecked" => 2, "intended_change" => 0, "clean" => 0 }.freeze
    QUIET = %w[intended_change refuted clean].freeze

    def self.markdown(header, verdicts, mode: "change", rows: "verdicts.jsonl")
      shown_kinds = verdicts.any? { _1.stage == "check" } ? %w[confirmed could_not_run refuted] : KINDS - %w[confirmed could_not_run refuted]
      counts = (shown_kinds | verdicts.map(&:kind).uniq).map { |kind| "#{kind}=#{verdicts.count { _1.kind == kind }}" }.join(" ")
      lines = ["# holdfast", "", *header, "", counts, ""]
      hidden = verdicts.reject(&:shown)
      verdicts = verdicts.select(&:shown)
      KINDS.each do |kind|
        group = verdicts.select { _1.kind == kind }
        next if group.empty?

        lines << "## #{mode == "before" && kind == "clean" ? "Pinned before the change" : HEADINGS.fetch(kind)}" << ""
        lines << "Read each test the change wrote and confirm its head value is what the intent wants; repro lines are in verdicts.jsonl." << "" if kind == "intended_change"
        group.each do |v|
          lines << "- `#{v.target}`: #{v.reason}"
          shown = mode == "before" ? 3 : SHOWN[kind]
          v.evidence.first(shown).each { lines << "  - #{_1}" }
          lines << "  - (#{v.evidence.size - shown} more in #{rows})" if shown.positive? && v.evidence.size > shown
          next if QUIET.include?(kind)

          lines << "  - repro: `#{v.repro}`" if v.repro
          lines << "  - next: #{v.next_step}"
        end
        lines << ""
      end
      lines << "#{hidden.size} more row(s) the change cannot reach (tests that reached no changed line and did not break, new specs with no base side) are in verdicts.jsonl only." << "" if hidden.any?
      lines.join("\n")
    end
  end
end
