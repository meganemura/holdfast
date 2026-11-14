# rbs_inline: enabled

module Holdfast
  module Stages
    # Adds the tests that are missing. Each method target gets inputs: the
    # agent's file under evidence/ when there is one, else a draft (see
    # Draft); a complete draft runs at once. One rspec process in a checkout
    # of the pinned side runs every input through Observe and writes a pin
    # test per input that holds what it returned, raised and wrote, as JSON.
    # The same process lets branchout run the inputs too, only for its list
    # of the branch arms no input took.
    #
    # Before a change, each input is varied: an Integer, a String or a
    # boolean argument is redrawn at the method's boundaries while every
    # argument written as Ruby (a record) stays as given.
    module Fill
      # The pins of one target: what each input returned, raised and wrote
      # (+observed+, one entry per input) and branchout's +report+.
      Pins = Data.define(
        :target, #: Target
        :origin, #: String
        :dir, #: String
        :rev, #: String
        :report, #: json
        :inputs, #: Inputs
        :observed, #: Array[json]
        :input_errors #: Array[String]
      )
      Gap = Data.define(
        :target, #: Target
        :draft, #: Draft::Result?
        :reason #: String
      )
      COMPARISON = %i[< <= > >=].freeze #: Array[Symbol]

      # @rbs!
      #   # One target to pin: its inputs, where they came from, and the entries to run.
      #   type job = [Target, Inputs, String, Array[Inputs::Entry]]
      #
      #   # A job and the directory its run writes to.
      #   type planned = [Target, Inputs, String, Array[Inputs::Entry], String]

      #: (Change change, Record record, Array[Target] targets) -> [Array[Pins], Array[Gap]]
      def self.run(change, record, targets)
        rev = change.changed? ? change.base : change.head
        gaps = [] #: Array[Gap]
        jobs = targets.select(&:method?).filter_map do |target|
          next if target.why.first == "added" && change.changed?
          next if target.name.end_with?("#initialize")

          bounds = boundaries(target.source)
          file = Inputs.path(change.root, target.name)
          origin = "inputs"
          unless File.file?(file)
            draft = Draft.for(change, rev, target)
            if draft.path.nil?
              gaps << Gap.new(target:, draft: nil, reason: draft.holes.join(", "))
              next
            end
            Draft.new(change, rev, target).write(draft)
            unless draft.complete?
              gaps << Gap.new(target:, draft:, reason: "the draft needs #{draft.holes.join(", ")}")
              next
            end
            file = draft.path #: String
            origin = "drafted"
          end
          inputs = Inputs.new(file, JSON.parse(File.read(file)), bounds)
          entries = inputs.entries
          entries += variants(entries, bounds) if change.mode == "before"
          job = [target, inputs, origin, entries] #: job
          job
        rescue Holdfast::Error, JSON::ParserError => e
          gaps << Gap.new(target:, draft: nil, reason: e.message)
          nil
        end
        return [[], gaps] if jobs.empty?

        [explore(change, record, rev, jobs), gaps]
      end

      # Integer literals a comparison in the target's source names.
      #: (String?) -> Array[Integer]
      def self.boundaries(source)
        found = [] #: Array[Integer]
        walk = ->(node) do
          if node.is_a?(Prism::CallNode) && COMPARISON.include?(node.name) && node.receiver && (args = node.arguments&.arguments || Draft::NO_NODES).size == 1
            [node.receiver, args.first].each { found << _1.value if _1.is_a?(Prism::IntegerNode) }
          end
          node.compact_child_nodes.each(&walk)
        end
        walk.call(Prism.parse(source.to_s).value)
        found.uniq
      end

      # Each JSON scalar, positional or keyword, is redrawn on its own; every
      # value written as Ruby (a record, a date) stays exactly as given.
      #: (Array[Inputs::Entry] entries, Array[Integer] bounds) -> Array[Inputs::Entry]
      def self.variants(entries, bounds)
        values = (bounds.flat_map { [_1 - 1, _1, _1 + 1] } + [0, -1]).uniq
        redraw = lambda do |v|
          case v
          when Integer then values - [v]
          when String then ["", "#{v}x"]
          when true, false then [!v]
          else []
          end
        end #: ^(untyped) -> Array[untyped]
        entries.flat_map do |e|
          args = Array(e.input["args"])
          none = {} #: json
          kwargs = e.input.fetch("kwargs", none) #: json
          by_arg = args.each_index.flat_map do |i|
            redraw.(args[i]).map { |v| [e.input.merge("args" => args.dup.tap { _1[i] = v }), "arg #{i + 1} to #{v.inspect}"] }
          end
          by_kwarg = kwargs.flat_map do |k, old|
            redraw.(old).map { |v| [e.input.merge("kwargs" => kwargs.merge(k => v)), "#{k}: to #{v.inspect}"] }
          end
          varied = by_arg + by_kwarg #: Array[[json, String]]
          varied.map { |input, what| Inputs::Entry.new(input: input.merge("note" => "varied #{what}"), change: e.change, note: "varied #{what}") }
        end.uniq { _1.input }
      end

      #: (Change change, Record record, String rev, Array[job] jobs) -> Array[Pins]
      def self.explore(change, record, rev, jobs)
        tree = File.join(Dir.mktmpdir("holdfast-pin"), "tree")
        Change.git(change.root, "worktree", "add", "--quiet", "--detach", tree, rev)
        planned = jobs.map do |target, inputs, origin, entries|
          run_dir = File.join(Holdfast.dir(change.root), "runs", Holdfast.slug(target.name))
          FileUtils.rm_rf(run_dir) if run_dir.include?("/.holdfast/runs/")
          FileUtils.mkdir_p(run_dir)
          File.write(File.join(run_dir, "inputs.json"), JSON.pretty_generate({ "inputs" => entries.map(&:input) }))
          plan = [target, inputs, origin, entries, run_dir] #: planned
          plan
        end
        File.write(File.join(tree, "holdfast_fill_spec.rb"), spec_source(record, planned))
        env = record.env_for("pin").merge("BUNDLE_GEMFILE" => File.join(tree, "Gemfile"))
        steps = [record.side_setup, "#{record.bundle}rspec holdfast_fill_spec.rb"].compact
        failure = nil #: String?
        steps.each do |command|
          step_env = command == record.side_setup ? env : env.merge("RUBYOPT" => "-I#{Tools.branchout_lib} -rbundler/setup -rbranchout/coverage")
          out, status = Open3.capture2e(step_env, "/bin/sh", "-c", command, chdir: tree)
          next if status.success? || command != steps.first && planned.all? { File.file?(File.join(_1[4], "observed.json")) }

          failure = "pinning at #{change.short(rev)} failed: `#{command}`: #{failure_line(out)}"
          break
        end
        planned.map do |target, inputs, origin, entries, run_dir|
          observed = File.file?(File.join(run_dir, "observed.json")) ? JSON.parse(File.read(File.join(run_dir, "observed.json"))) : [] #: Array[json]
          report = File.file?(File.join(run_dir, "report.json")) ? JSON.parse(File.read(File.join(run_dir, "report.json"))) : {} #: json
          errors = observed.filter_map { _1["input_error"] }
          errors << failure if failure && observed.empty?
          write_pins(record, target, entries, observed, File.join(run_dir, "pinned"))
          Pins.new(target:, origin:, dir: File.join(run_dir, "pinned"), rev:, report:, inputs:, observed:, input_errors: errors.uniq)
        end
      ensure
        if tree && File.directory?(tree) && tree.start_with?(Dir.tmpdir)
          system("git", "worktree", "remove", "--force", tree, chdir: change.root)
          FileUtils.rm_rf(File.dirname(tree))
        end
      end

      #: (Record record, Array[planned] planned) -> String
      def self.spec_source(record, planned)
        examples = planned.map do |target, _inputs, _origin, _entries, run_dir|
          <<~RUBY
            it #{target.name.inspect} do
              inputs = JSON.parse(File.read(#{File.join(run_dir, "inputs.json").inspect}))["inputs"]
              observed = inputs.map do |input|
                Holdfast::Observe.observe(self, input, #{target.name.inspect})
              rescue StandardError, SyntaxError => e
                { "input_error" => "\#{e.class}: \#{e.message.lines.first.to_s.strip}" }
              end
              File.write(#{File.join(run_dir, "observed.json").inspect}, JSON.generate(observed))
              report = begin
                Branchout.explore(#{target.name.inspect}, within: self, json: true, inputs: #{File.join(run_dir, "inputs.json").inspect})
              rescue StandardError => e
                JSON.generate({ "error" => e.message })
              end
              File.write(#{File.join(run_dir, "report.json").inspect}, report)
            end
          RUBY
        end
        <<~RUBY
          require #{record.helper.inspect}
          require "branchout"
          require #{File.join(RUNTIME, "observe").inspect}
          RSpec.describe "holdfast fill", type: :model do
          #{examples.join}
          end
        RUBY
      end

      # One pin test per input that ran; an input whose own Ruby failed (a
      # factory, a typo) pins nothing and is listed instead.
      #: (Record record, Target target, Array[Inputs::Entry] entries, Array[json] observed, String dir) -> void
      def self.write_pins(record, target, entries, observed, dir)
        FileUtils.mkdir_p(dir)
        groups = entries.zip(observed).reject { _2.nil? || _2["input_error"] }.group_by { _1.first.change ? "change/change" : "keep" }
        groups.each do |group, rows|
          examples = rows.each_with_index.map do |(entry, seen), i|
            label = "#{target.name} input #{i + 1}#{" (#{entry.note.delete_prefix("drawn ")})" if entry.note}"
            <<~RUBY
              it #{label.inspect} do
                input = JSON.parse(#{JSON.generate(entry.input).inspect})
                expected = JSON.parse(#{JSON.generate(seen).inspect})
                differs = Holdfast::Observe.differences(expected, Holdfast::Observe.observe(self, input, #{target.name.inspect}))
    expect(differs).to be_empty, "differs: \#{differs.first(3).join(" | ")}"
              end
            RUBY
          end
          path = File.join(dir, "#{group}#{record.test_suffix}")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, <<~RUBY)
            require #{record.helper.inspect}
            require #{File.join(RUNTIME, "observe").inspect}
            RSpec.describe #{"pins #{target.name}".inspect} do
            #{examples.join}
            end
          RUBY
        end
      end

      #: (String) -> String
      def self.failure_line(out)
        out.lines.map(&:strip).grep(/Error|error:|expected/).first(2).join(" ").then { _1.empty? ? out.lines.last(2).join(" ").strip : _1 }
      end
    end
  end
end
