module Holdfast
  module Stages
    # Runs every test that speaks for a target on base and on head (jitcatch's
    # runner) and returns one Outcome per test, with the app lines each test
    # file ran on each side. Fold decides what an outcome says about a target;
    # Diff only runs and classifies. Four sources:
    #   kept      base's copy of each selected test the change did not edit
    #   authored  head's copy of each test file the change added or edited;
    #             it states the new behavior, so it counts as meant to change
    #   evidence  .holdfast/evidence/<target>/ tests the agent wrote
    #   pin       the pin tests Fill wrote (inputs or drafted)
    # A path segment named `change` marks a test whose difference is intended.
    module Diff
      Source = Data.define(:path, :targets, :origin, :edited)
      Outcome = Data.define(:source, :test, :kind, :reason, :evidence, :repro, :next_step) do
        def place = "#{Diff.shown_path(source)}#{":#{test["line"]}" if test["line"]}"
      end
      Result = Data.define(:outcomes, :reach, :failure)
      # Where read_reach keeps the values a test file's inputs wrote.
      DREW = "(drew)"
      # Prefix of the key that holds the branch arms a test took in one file,
      # each as "line:column-line:column", the start and end of the arm.
      ARMS = "(arms)"
      DISCARDS = {
        "signature_change" => "the test calls something whose arguments the change altered",
        "load_error" => "the test does not load on head",
        "no_table" => "a table the test needs is missing on one side",
        "no_database" => "the test database was not reachable on one side",
        "timeout" => "the test timed out on one side"
      }.freeze

      def self.run(change, record, targets, pins, values: [])
        work = File.join(Holdfast.dir(change.root), "runs", "diff")
        FileUtils.rm_rf(work) if work.end_with?("/.holdfast/runs/diff")
        reach_dir = File.join(work, "reach")
        FileUtils.mkdir_p(reach_dir)
        sources = gather(change, record, targets, pins, work)
        outcomes = []
        failure = nil
        sources.each_slice(JitCatch::Runner::FILE_CAP).with_index do |chunk, i|
          dir = File.join(work, "run#{i}")
          chunk.each { |s| FileUtils.mkdir_p(File.dirname(File.join(dir, s.path))) && FileUtils.cp(File.join(work, "all", s.path), File.join(dir, s.path)) }
          got, failure = compare(change, record, chunk, dir, reach_dir, values)
          outcomes += got
        end
        Result.new(outcomes:, reach: read_reach(reach_dir), failure:)
      end

      # test path (as in the run directory) => { "1" => {file => [lines]}, "2" => ... },
      # and the same for "<test path>:<example line>" when the recorder could
      # tell the examples of a file apart.
      # What one outcome ran on one side ("1" base, "2" head): its own
      # example's lines when they were kept, else its whole file's.
      def self.ran(reach, outcome, side)
        own = "#{outcome.source.path}:#{outcome.test["line"]}"
        (reach.key?(own) && reach[own].key?(side) ? reach[own] : reach.fetch(outcome.source.path, {})).fetch(side, {})
      end

      def self.read_reach(dir)
        reach = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = Hash.new { |h3, k3| h3[k3] = [] } } }
        Dir.glob(File.join(dir, "reach-*.json")).each do |file|
          row = JSON.parse(File.read(file))
          row["hits"].each { |path, lines| reach[row["test"]][row["side"]][path] |= lines }
          reach[row["test"]][row["side"]][DREW] |= Array(row["drew"])
          Hash(row["arms"]).each { |path, arms| reach[row["test"]][row["side"]][ARMS + path] |= arms }
          Hash(row["examples"]).each do |line, seen|
            own = reach["#{row["test"]}:#{line}"][row["side"]]
            seen["hits"].each { |path, lines| own[path] |= lines }
            seen["arms"].each { |path, arms| own[ARMS + path] |= arms }
          end
        end
        reach
      end

      def self.gather(change, record, targets, pins, work)
        all = File.join(work, "all")
        edited = Change.git(change.root, "diff", "--name-only", "--diff-filter=AM", change.base, change.head, "--", "spec", "test")
                       .lines.map(&:strip).select { _1.end_with?(record.test_suffix) }
        by_test = Hash.new { |h, k| h[k] = [] }
        targets.each { |t| t.tests.select { _1.end_with?(record.test_suffix) }.each { by_test[_1] << t.name } }
        sources = []
        (by_test.keys - edited).each do |file|
          text = show(change, change.base, file) or next
          sources << write(all, "kept/#{file}", text, by_test[file], "kept")
        end
        edited.each do |file|
          sources << write(all, "change/authored/#{file}", show(change, change.head, file), by_test[file], "authored", edited_lines(change, file))
        end
        targets.each do |t|
          dir = File.join(Holdfast.dir(change.root), "evidence", Holdfast.slug(t.name))
          Dir.glob("**/*{_spec,_test}.rb", base: dir).each do |file|
            sources << write(all, "t-#{Holdfast.slug(t.name)}/evidence/#{file}", File.read(File.join(dir, file)), [t.name], "evidence", nil)
          end
        end
        pins.each do |p|
          Dir.glob("**/*{_spec,_test}.rb", base: p.dir).each do |file|
            sources << write(all, "t-#{Holdfast.slug(p.target.name)}/#{p.origin}-pin/#{file}", File.read(File.join(p.dir, file)), [p.target.name], "#{p.origin} pin", nil)
          end
        end
        sources
      end

      def self.show(change, rev, file)
        out, status = Open3.capture2("git", "show", "#{rev}:#{file}", chdir: change.root)
        status.success? ? out : nil
      end

      def self.write(all, path, text, targets, origin, edited = nil)
        FileUtils.mkdir_p(File.dirname(File.join(all, path)))
        File.write(File.join(all, path), text)
        Source.new(path:, targets:, origin:, edited:)
      end

      # Head line numbers the change added or rewrote in one test file.
      def self.edited_lines(change, file)
        diff = Change.git(change.root, "diff", "--unified=0", change.base, change.head, "--", file)
        diff.scan(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/).flat_map { |start, count| (start.to_i...(start.to_i + (count || 1).to_i)).to_a }
      end

      def self.compare(change, record, chunk, dir, reach_dir, values = [])
        env_names = record.env_names + %w[RUBYOPT HOLDFAST_REACH_DIR HOLDFAST_VALUES] + (record.database_url ? ["DATABASE_URL"] : [])
        saved = ENV.to_h.slice("RUBYOPT", "HOLDFAST_REACH_DIR", "DATABASE_URL", "HOLDFAST_VALUES")
        ENV["HOLDFAST_VALUES"] = JSON.generate(values)
        ENV["RUBYOPT"] = "-r#{File.join(RUNTIME, "reach.rb")}"
        ENV["HOLDFAST_REACH_DIR"] = reach_dir
        ENV["DATABASE_URL"] = record.database_url if record.database_url
        doc = JitCatch::Assessor.apply(JitCatch::Runner.run(change.root, change.base, change.head, dir, env: env_names.uniq,
                                                            setup: record.side_setup, timeout: 60, number_database_url: !record.database_url.nil?))
        by_path = chunk.to_h { [_1.path, _1] }
        starts = doc["tests"].group_by { _1["file"] }.transform_values { |ts| ts.filter_map { _1["line"] }.sort }
        outcomes = doc["tests"].map do |test|
          source = by_path[test["file"]] || Source.new(path: test["file"], targets: [], origin: "unknown", edited: nil)
          meant = test["file"].split("/").include?("change") && (source.edited.nil? || example_edited?(test, starts[test["file"]], source.edited))
          # An example the change edited that still passes on base states kept
          # behavior in new words; only marks the agent wrote can be wrong.
          meant = false if source.origin == "authored" && test["classification"] == "no_signal"
          kind, reason, next_step = classify(test, meant)
          Outcome.new(source:, test:, kind:, reason:, evidence: evidence(test), next_step: next_step || MARK.fetch(source.origin.split.first, MARK["evidence"]),
                      repro: "#{record.bundle}rspec #{File.join(dir, test["file"]).delete_prefix("#{change.root}/")}#{":#{test["line"]}" if test["line"]}")
        end
        [outcomes, nil]
      rescue JitCatch::EnvironmentError => e
        [[], "setup failed on #{e.doc["setup_failed"].map { "#{_1["side"]}: #{Array(_1["stderr"]).last}" }.join("; ")}"]
      ensure
        %w[RUBYOPT HOLDFAST_REACH_DIR DATABASE_URL HOLDFAST_VALUES].each { ENV.delete(_1) }
        ENV.update(saved)
      end

      def self.shown_path(source)
        case source.origin
        when "kept" then source.path.delete_prefix("kept/")
        when "authored" then source.path.delete_prefix("change/authored/")
        else source.path
        end
      end

      MARK = {
        "kept" => "fix the code; if the intent covers it, edit this test in the change to state the new behavior",
        "authored" => "fix the code; if the intent covers it, edit this example in the change to state the new behavior",
        "drafted" => "fix the code; if the intent covers it, copy the draft to evidence/ and mark the input \"change\": true or add a change_when",
        "inputs" => "fix the code; if the intent covers it, mark the input \"change\": true or cover it with change_when",
        "evidence" => "fix the code; if the intent covers it, move the test under change/"
      }.freeze

      def self.example_edited?(test, starts, edited)
        return edited.any? unless test["line"]

        stop = starts.find { _1 > test["line"] } || Float::INFINITY
        edited.any? { (test["line"]...stop).cover?(_1) }
      end

      def self.classify(test, meant)
        head_passes = %w[pass skip].include?(test.dig("head", "status"))
        case [test["classification"], test["disposition"]]
        in ["fail_on_base", _] if head_passes && no_base?(test)
          # Base cannot even name what the test calls, so its failure there
          # says nothing about behavior; what the test exercises is compared
          # through the existing callers and the pins instead.
          ["no_base", "new spec, no base side (base: #{test.dig("base", "message").to_s.lines.first.to_s.strip})", nil]
        in ["no_signal", _] if meant
          ["unchecked", "marked as meant to change, but passes on both sides", "make it state the new behavior so that it fails on base, or drop the change mark"]
        in ["no_signal", _] then ["clean", "agrees"]
        in ["candidate", "reported"] if meant
          ["intended_change", "differs, as marked", "confirm the head value is the one the intent wants"]
        in ["candidate", "reported"]
          ["unintended_change", "passes on base, fails on head, not marked", nil]
        in ["candidate", _]
          reason = test["tags"].grep(/\Adiscard:/).map { DISCARDS.fetch(_1.delete_prefix("discard:"), _1) }.join("; ")
          ["unchecked", "differs, but #{reason}", "rewrite the call for head's signature with the same expectation in .holdfast/evidence/<target>/"]
        in ["fail_on_base", _] if meant && head_passes
          ["intended_change", "fails on base, passes on head, as marked", "confirm the head value is the one the intent wants"]
        in ["fail_on_base", _] if meant
          ["unchecked", "fails on both sides", "read the head failure; fix the code or the test"]
        in ["fail_on_base", _]
          ["unchecked", "fails on base, so it states no behavior to keep", "fix the test, or mark it as meant to change"]
        in ["flaky", _]
          ["unchecked", "results differ between runs", "make the test deterministic"]
        end
      end

      NO_BASE = /uninitialized constant|undefined (method|local variable)|unknown attribute|has no attribute|UndefinedColumn|unknown keyword|No route matches/

      def self.no_base?(test) = test.dig("base", "message").to_s.match?(NO_BASE)

      def self.evidence(test)
        base, head = test["base"] || {}, test["head"] || {}
        failed = [head, base].find { !_1["message"].to_s.strip.empty? }
        detail = failed ? " (#{failed["message"].to_s.lines.first(3).map(&:strip).join(" ")[0, 220]})" : ""
        "#{test["name"]}: base #{base["status"]}, head #{head["status"]}#{detail}"
      end
    end
  end
end
