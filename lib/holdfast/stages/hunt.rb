module Holdfast
  module Stages
    # The hunt stage: the sequences library drafts one definition per write
    # area of the app (routes, Grape endpoints, jobs), then runs random
    # orders of those actions against the real database under invariants,
    # time zones and second doors. Its definitions live in
    # .holdfast/sequences/, outside the app's tree, so a hunt never makes the
    # next run see a change. Each area's verdict becomes one row:
    #   FAILURE         -> bug_suspect, with the log that holds the shortest sequence
    #   partly checked  -> unchecked, with what was not covered
    #   unchecked       -> unchecked, with why it never ran
    #   clean           -> clean, scoped to the seeds and cases that ran
    # In a change, only the areas that touch a changed file run.
    module Hunt
      DEFAULT_BUDGET = 600

      def self.run(change, record, budget:, files: nil)
        budget ||= DEFAULT_BUDGET
        dir = File.join(Holdfast.dir(change.root), "sequences")
        work = File.join(Holdfast.dir(change.root), "runs", "sequences")
        FileUtils.mkdir_p([dir, work])
        env = { "RAILS_ENV" => "test", "SEQUENCES_OUT" => dir, "SEQUENCES_WORK" => work,
                "SEQUENCES_LIB" => File.join(SEQUENCES, "sequences.rb") }
        env["SEQUENCES_DATABASE_URL"] = record.database_url if record.database_url
        bundle = overlay(change, env)
        return [bundle] if bundle.is_a?(Verdict)

        drafted = draft(change, record, dir, env)
        return [drafted] if drafted.is_a?(Verdict)

        areas = Dir.glob(File.join(dir, "*.rb")).reject { File.basename(_1) == "invariants.rb" }.sort
        areas = touching(areas, files) if files
        return [row("(sequences)", "unchecked", "no area touches the changed files", [], "nothing to hunt for this change")] if areas.empty?

        per_area = [budget * 4 / [areas.size, 4].max, 60].max
        cases = budget >= 900 ? 300 : 60
        # Shrinking a failure takes minutes; a short hunt reports it as found.
        env["SEQ_NO_SHRINK"] = "1" if budget < 900
        json = File.join(work, "table.json")
        FileUtils.rm_f(json)
        out, = Open3.capture2e(env, RbConfig.ruby, File.join(SEQUENCES, "run.rb"), "-j", "4", "--cases", cases.to_s, "--seeds", "1",
                               "--timeout", per_area.to_s, "--json", json, *areas, chdir: change.root)
        File.write(File.join(work, "run.log"), out)
        unless File.file?(json)
          return [row("(sequences)", "unchecked", "the sequences run printed no table: #{out.lines.grep(/Error|error/).first.to_s.strip}", ["log: #{Fold.rel(File.join(work, "run.log"))}"], "read the log, fix the error it names, then holdfast run")]
        end

        table = JSON.parse(File.read(json))
        rows = table.map { area_row(change, _1) }
        [reach_row(change, table)].compact + rows
      end

      # The first line of a hunt says how much of it ran: an action that was
      # refused every time, or never drawn, checked nothing, and an area that
      # reached under half its actions is not listed as clean. An area that
      # failed stopped at its failure, so its reach says nothing about setup.
      def self.reach_row(change, table)
        counts = table.filter_map { |r| r["verdict"] != "FAILURE" && r["reached"].to_s[%r{(\d+)/(\d+)}] && [r, $1.to_i, $2.to_i] }
        total = counts.sum { _1[2] }
        reached = counts.sum { _1[1] }
        return nil if total.zero? || reached == total

        thin = counts.select { |_, a, b| a * 2 < b }.sort_by { |_, a, b| a.fdiv(b) }
        # Each thin area names its file and the first actions that checked
        # nothing, with the refusal, so the fix starts at a line, not a count.
        evidence = thin.map do |r, a, b|
          missing = r["text"].to_s.lines.drop(1).map { _1.strip.delete_prefix("- ") }.reject(&:empty?)
          "#{r["area"]} (#{r["file"].to_s.delete_prefix("#{change.root}/")}): #{a}/#{b} actions reached#{"; first: #{missing.first(2).join("; ")}" if missing.any?}"
        end
        worst = thin.first&.first
        step = worst ? "start with #{worst["area"]}: make the records or the sign-in its unreached actions need in #{worst["file"].to_s.delete_prefix("#{change.root}/")}, then holdfast run" :
                       "read each area's row below for the refusals, fix the setup or the sign-in in its file, then holdfast run"
        row("(hunt)", "unchecked", "unreached: #{total - reached} of #{total} actions (refused every time or never drawn); #{thin.size} of #{counts.size} areas reached under half",
            evidence, "#{step}; until then the hunt says little about these areas")
      end

      # The sequences library needs hegeltest, which the app's bundle may
      # not list. A Gemfile of holdfast's own evaluates the app's and adds
      # it, locked from the gems already installed, so the app's Gemfile and
      # lock stay untouched.
      def self.overlay(change, env)
        dir = File.join(Holdfast.dir(change.root), "bundle")
        FileUtils.mkdir_p(dir)
        gemfile = File.join(dir, "Gemfile")
        app_lock = File.join(change.root, "Gemfile.lock")
        if File.read(app_lock).match?(/^    hegeltest /)
          env["BUNDLE_GEMFILE"] = File.join(change.root, "Gemfile")
          return nil
        end
        File.write(gemfile, %(eval_gemfile #{File.join(change.root, "Gemfile").inspect}\ngem "hegeltest", "#{Holdfast::HEGELTEST_VERSION}", require: false\n))
        FileUtils.cp(app_lock, "#{gemfile}.lock") unless File.file?("#{gemfile}.lock")
        out, status = Open3.capture2e({ "BUNDLE_GEMFILE" => gemfile }, "bundle", "lock", "--local", chdir: change.root)
        return row("(sequences)", "unchecked", "could not add hegeltest to a bundle of holdfast's own: #{out.lines.last.to_s.strip}", [], "install hegeltest #{Holdfast::HEGELTEST_VERSION} for this Ruby, then holdfast run") unless status.success?

        env["BUNDLE_GEMFILE"] = gemfile
        nil
      end

      def self.draft(change, record, dir, env)
        probe_env = env.merge(record.database_url ? { "DATABASE_URL" => "#{record.database_url}_seq0" } : {})
        if record.side_setup
          _, status = Open3.capture2e(probe_env, "/bin/sh", "-c", record.side_setup, chdir: change.root)
          return row("(sequences)", "unchecked", "the probe database did not set up", [], "holdfast run --learn") unless status.success?
        end
        return nil if Dir.glob(File.join(dir, "*.rb")).size > 1

        out, status = Open3.capture2e(probe_env, "bundle", "exec", "ruby", File.join(SEQUENCES, "propose.rb"), "--all", chdir: change.root)
        return nil if status.success?

        row("(sequences)", "unchecked", "drafting the areas failed: #{out.lines.grep(/Error|error/).first.to_s.strip}", [],
            "fix the error it names in the app or its factories, then holdfast run")
      end

      # An area runs for a change when its definition names a changed file's
      # table, constant or route resource.
      def self.touching(areas, files)
        words = files.flat_map do |f|
          base = File.basename(f, ".rb").delete_suffix("_controller").delete_suffix("_api")
          [base, base.end_with?("s") ? base : "#{base}s"]
        end.uniq
        areas.select { |a| text = File.read(a); words.any? { text.include?(_1) } }
      end

      def self.area_row(change, r)
        text = r["text"].to_s
        lines = text.lines.map(&:strip)
        scope = "#{r["seeds"].to_s.split(",").size} seed(s) x #{r["cases"]} cases, #{r["reached"]} actions reached"
        cut = text[/cut by the time limit after \S+ of \d+ cases/]
        scope = "#{cut}, #{r["reached"]} actions reached" if cut
        log = r["log"].to_s.delete_prefix("#{change.root}/")
        area = "sequences: #{r["area"]}"
        case r["verdict"]
        when "FAILURE"
          # The failure text is the first line under "Sequences::Failure:" in
          # RSpec's report, kept whole: a cut message hid which row broke.
          logged = File.file?(r["log"].to_s) ? File.readlines(r["log"], encoding: "UTF-8").map { _1.scrub.strip } : []
          at = logged.index { _1.end_with?("Sequences::Failure:") }
          found = at ? logged[at + 1] : logged.find { _1.match?(/ raised |invariant \w+ broken|differ|disagree/) && !_1.start_with?("#", "1)") }
          reason = found ? found.sub(/\A.*?in '[^']+': /, "").sub(/ \(Sequences::Failure\)\z/, "") : lines.first.delete_prefix("FAILURE: ")
          short = reason.size > 300 ? "#{reason[0, 300]}... (whole text in evidence)" : reason
          # An error raised in holdfast's own code, not the app's, says nothing
          # about the app: report it as holdfast's, with where it was raised.
          frame = logged.find { _1.start_with?("# /") }
          if at.nil? && frame&.include?(File.expand_path("..", __dir__))
            return row(area, "unchecked", "holdfast failed while hunting here: #{short}", ["at: #{frame.delete_prefix("# ")}", "log: #{log}"],
                       "report it to holdfast with the log; the hunt checked nothing in this area", scope:)
          end
          # Broken before any action ran, the world the setup drafted already
          # breaks the rule: the setup or the drafted rule is wrong, not the app.
          if (rule = reason[/invariant (\w+) broken after setup/, 1])
            return row(area, "unchecked", "the drafted setup already breaks #{rule}, before any action; the hunt checked nothing here",
                       ["failure: #{reason}", "log: #{log}"],
                       "make the setup in #{r["file"].to_s.delete_prefix("#{change.root}/")} build records that keep #{rule}, or drop the rule from .holdfast/sequences/invariants.rb if the app does not promise it; then holdfast run", scope:)
          end
          row(area, "bug_suspect", short, ["failure: #{reason}", "log: #{log} (the shortest sequence and an `it` block that replays it)"],
              "paste the `it` block from the log into #{r["file"].to_s.delete_prefix("#{change.root}/")}, see it fail, fix the code, run again", scope:)
        when "partly checked"
          missing = lines.drop(1).map { _1.delete_prefix("- ") }
          row(area, "unchecked", "partly checked (#{scope}); #{missing.size} action(s) checked nothing", missing,
              "make the record in setup, narrow a pool, or change the param draws in #{r["file"].to_s.delete_prefix("#{change.root}/")}, then holdfast run", scope:)
        when "clean"
          a, b = r["reached"].to_s.scan(/\d+/).map(&:to_i)
          return row(area, "unchecked", "reached only #{a}/#{b} actions (#{scope})", [], "make the records the other actions need in #{r["file"].to_s.delete_prefix("#{change.root}/")}, then holdfast run", scope:) if a && b && a * 2 < b

          row(area, "clean", "every action, offset replay and door pair reached its target (#{scope})", [], "nothing; the claim covers only these seeds and cases", scope:)
        else
          row(area, "unchecked", lines.first.to_s.delete_prefix("unchecked: "), ["log: #{log}"], "read the log, fix the setup it names, then holdfast run")
        end
      end

      def self.row(target, kind, reason, evidence, next_step, scope: nil)
        Verdict.of(target:, stage: "sequences", kind:, reason:, evidence:, next_step:, scope:)
      end
    end
  end
end
