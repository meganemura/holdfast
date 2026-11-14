# rbs_inline: enabled

module Holdfast
  module Stages
    # A behavior diff that starts from inputs, not from changed methods: the
    # hunt's area definitions (drafted on head) run every ordering of their
    # actions up to three steps, with fixed draws, once in a checkout of base
    # and once in a checkout of head, each on its own database. Every step
    # records how it ended, the rows it wrote by attributes, and the fakes it
    # touched. Where the two sides differ is behavior that changed, whether
    # or not a changed method is anywhere near it; an unchanged caller of a
    # changed value shows up because its own observation moves.
    #
    # Only the first differing step of a sequence counts (the steps after it
    # start from another state). Each difference is matched against the
    # words of --intent: one that names it is shown to confirm, any other is
    # unintended.
    module Observe
      # The first step of one ordering whose +what+ (outcome, writes or
      # outside) differs; +base+ and +head+ are what each side recorded.
      Diff = Data.define(
        :area, #: String
        :action, #: String
        :what, #: String
        :seq, #: Array[String]
        :step, #: Integer
        :base, #: untyped
        :head, #: untyped
        :args #: untyped
      )

      #: (Change change, Record record, intent: String?, files: Array[String]) -> Array[Verdict]
      def self.run(change, record, intent:, files:)
        dir = File.join(Holdfast.dir(change.root), "sequences")
        work = File.join(Holdfast.dir(change.root), "runs", "observe")
        FileUtils.rm_rf(work) if work.end_with?("/.holdfast/runs/observe")
        FileUtils.mkdir_p([dir, work])
        env = { "RAILS_ENV" => "test", "SEQUENCES_OUT" => dir, "SEQUENCES_LIB" => File.join(SEQUENCES, "sequences.rb") }
        url = record.database_url
        env["SEQUENCES_DATABASE_URL"] = url if url
        bundle = Hunt.overlay(change, env)
        return [bundle] if bundle.is_a?(Verdict)

        drafted = Hunt.draft(change, record, dir, env)
        return [drafted] if drafted.is_a?(Verdict)

        areas = Hunt.touching(Dir.glob(File.join(dir, "*.rb")).reject { File.basename(_1) == "invariants.rb" }.sort, files)
        return [row("(observe)", "unchecked", "no drafted area touches the changed files", [], "nothing to observe for this change")] if areas.empty?

        sides = { "base" => change.base, "head" => change.head }.to_h do |side, rev|
          [side, Thread.new { observe_side(change, record, env, side, rev, areas, work) }]
        end.transform_values(&:value)
        failed = sides.select { |_, r| r[:error] }
        return failed.map { |side, r| row("(observe)", "unchecked", "the #{side} side did not run: #{r[:error]}", [], "read #{Fold.rel(r[:log])}, fix the setup, then holdfast run --observe") } if failed.any?

        diffs = compare(sides["base"][:lines], sides["head"][:lines])
        steps = sides["head"][:lines].size
        return [row("(observe)", "clean", "#{steps} step(s) in #{areas.size} area(s) observed the same on both sides", [],
                    "nothing; the claim covers only these orderings and draws", scope: areas.map { File.basename(_1, ".rb") }.join(", "))] if diffs.empty?

        said = intent.to_s.downcase.scan(/[a-z][a-z_]{3,}/) #: Array[String]
        words = said.uniq - %w[that with from this have should when then into only also each same than they them]
        groups = diffs.group_by { [_1.area, _1.action, _1.what] } #: Hash[[String, String, String], Array[Diff]]
        groups.map { |(area, action, what), ds| diff_row(area, action, what, ds, words) }
      end

      # What one side observed, { lines:, log: }, or why it did not run, { error:, log: }.
      #: (Change change, Record record, Hash[String, String] env, String side, String rev, Array[String] areas, String work) -> Hash[Symbol, untyped]
      def self.observe_side(change, record, env, side, rev, areas, work)
        tree = File.join(Dir.mktmpdir("holdfast-observe"), "tree")
        Change.git(change.root, "worktree", "add", "--quiet", "--detach", tree, rev)
        number = Record::SIDES.fetch(side)
        side_env = env.merge(record.env_for(side)).merge("BUNDLE_GEMFILE" => env.fetch("BUNDLE_GEMFILE", File.join(tree, "Gemfile")))
        log = File.join(work, "#{side}.log")
        if (setup = record.side_setup)
          out, status = Open3.capture2e(side_env, "/bin/sh", "-c", setup, chdir: tree)
          File.write(log, out)
          return { error: "database setup failed", log: } unless status.success?
        end
        lines = [] #: Array[json]
        areas.each do |area|
          out_file = File.join(work, "#{side}-#{File.basename(area, ".rb")}.jsonl")
          out, = Open3.capture2e(side_env.merge("SEQ_OBSERVE" => out_file, "TEST_ENV_NUMBER" => number), "bundle", "exec", "rspec", area, chdir: tree)
          File.write(log, out, mode: "a")
          lines += File.readlines(out_file).map { JSON.parse(_1) } if File.file?(out_file)
        end
        { lines:, log: }
      ensure
        if tree && File.directory?(tree)
          system("git", "worktree", "remove", "--force", tree, chdir: change.root, err: File::NULL)
          FileUtils.rm_rf(File.dirname(tree))
        end
      end

      #: (Array[json] base, Array[json] head) -> Array[Diff]
      def self.compare(base, head)
        by_key = base.to_h { [[_1["area"], _1["index"], _1["step"]], _1] }
        head.group_by { [_1["area"], _1["index"]] }.filter_map do |_, steps|
          steps.sort_by { _1["step"] }.each do |h|
            b = by_key[[h["area"], h["index"], h["step"]]] or break nil
            what = %w[outcome writes outside].find { b[_1] != h[_1] } or next
            break Diff.new(area: h["area"], action: h["action"], what:, seq: h["seq"], step: h["step"], base: b[what], head: h[what], args: h["args"])
          end.then { _1.is_a?(Diff) ? _1 : nil }
        end
      end

      #: (String area, String action, String what, Array[Diff] ds, Array[String] words) -> Verdict
      def self.diff_row(area, action, what, ds, words)
        first = ds.min_by { [_1.seq.size, _1.step] } #: Diff
        named = words.select { |w| [action, JSON.generate(first.base), JSON.generate(first.head)].any? { _1.to_s.downcase.include?(w) } }
        evidence = ["shortest: #{first.seq.first(first.step).join(" -> ")} (step #{first.step}: #{action} #{first.args})",
                    "base #{what}: #{show(first.base)}", "head #{what}: #{show(first.head)}",
                    "#{ds.size} ordering(s) differ first at #{action}"]
        if named.any?
          row("observe: #{area} #{action}", "intended_change", "#{what} differs at #{action}, and the intent names #{named.first(3).join(", ")}", evidence,
              "confirm the head #{what} is what the intent wants")
        else
          row("observe: #{area} #{action}", "unintended_change", "#{what} differs at #{action} after #{first.step - 1} earlier step(s); the intent does not name it", evidence,
              "fix the code, or say it in --intent; the orderings are in .holdfast/runs/observe/")
        end
      end

      #: (untyped) -> String
      def self.show(v) = (v.is_a?(String) ? v : JSON.generate(v)).then { _1.size > 400 ? "#{_1[0, 400]}..." : _1 }

      #: (String target, String kind, String reason, Array[String] evidence, String next_step, ?scope: String?) -> Verdict
      def self.row(target, kind, reason, evidence, next_step, scope: nil)
        Verdict.of(target:, stage: "observe", kind:, reason:, evidence:, next_step:, scope:)
      end
    end
  end
end
