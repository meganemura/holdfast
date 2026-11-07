module Holdfast
  # `holdfast check`: the agent reads the code and writes what it suspects;
  # holdfast turns each suspicion into a spec that builds the world with the
  # app's factories, runs the action (or races two), and checks `expect`.
  # In a change it runs on base and on head; otherwise once on the tree.
  # Each suspicion is one row: confirmed (the spec fails, and is kept in
  # spec/holdfast/<branch>/), refuted (what was observed), or could_not_run (the
  # exact error, and which part of `given` or `do` it came from).
  module Check
    KEYS = %w[says given do race pause expect].freeze
    Suspicion = Data.define(:id, :says, :given, :acts, :pause, :expects, :calls, :errors, :source, :shared)
    SUPPORT = %w[spec/holdfast spec/support spec/factories spec/rails_helper.rb spec/spec_helper.rb test/support test/factories test/test_helper.rb].freeze
    SIDE_NUMBERS = { "base" => "c1", "head" => "c2" }.freeze
    COMPARE = %i[== != < <= > >= === =~ include? eql? equal?].freeze

    def self.run(root, files:, inline:, base: nil, here: false)
      timings = {}
      record = Harness.timed(timings, "record") { Record.load_or_learn(root) }
      raise Holdfast::Error, "project setup failed (#{record.failure}); fix it, then holdfast run --learn" unless record.ok?

      suspicions = parse(files, inline)
      change = Change.read(root, base_ref: base || record.base_branch, named: [])
      sides = change.changed? && !here ? { "base" => change.base, "head" => nil } : { "head" => nil }
      place = Place.of(root)
      dir = File.join(root, place.specs)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "holdfast_check.rb"), File.read(File.join(RUNTIME, "check_support.rb")))
      suspicions.each { File.write(File.join(dir, "#{_1.id}_spec.rb"), spec(_1, record)) }
      reports = Harness.timed(timings, "run") do
        sides.map { |side, rev| Thread.new { [side, run_side(root, record, side, rev, suspicions, place)] } }.map(&:value).to_h
      end
      rows = suspicions.map { row(_1, reports, change, sides, record, place) }
      header = ["check: #{suspicions.size} suspicion(s); #{scope_line(change, here)}",
                "kept specs: #{place.specs}/ (#{place.label}); rows: #{place.out}/check.jsonl",
                "seconds: #{timings.map { "#{_1} #{_2}" }.join(", ")}"]
      [rows, header, place]
    end

    # Specs and outputs of one branch, so a branch switch neither mixes kept
    # specs nor shows another branch's rows. A detached HEAD is keyed by its
    # commit.
    Place = Data.define(:key, :label) do
      def self.of(root)
        branch = Change.git(root, "rev-parse", "--abbrev-ref", "HEAD")
        branch = nil if branch == "HEAD"
        sha = Change.git(root, "rev-parse", "--short=7", "HEAD")
        new(key: branch ? Holdfast.slug(branch) : sha, label: branch ? "branch #{branch}" : "detached HEAD #{sha}")
      end

      def specs = "spec/holdfast/#{key}"
      def out = ".holdfast/check/#{key}"
    end

    # What the rows were checked on, so a run that compared with a base says
    # which files made it a change, and one that did not says so.
    def self.scope_line(change, here)
      base = "#{change.base_label} (#{change.short(change.base)})"
      return "no change: checks run on the current tree only (#{change.short(change.head)}); app, lib, config, db and the Gemfile match #{base}" unless change.changed?
      return "--here: checks run on the current tree only (#{change.short(change.head)}); the change against #{base} is not compared" if here

      files = Change.git(change.root, "diff", "--name-only", change.base, change.head, "--", *Holdfast::CODE).lines.map(&:strip)
      "change: each runs on base #{base} and on the working tree (#{change.short(change.head)}); #{files.size} file(s) differ: #{files.first(5).join(", ")}#{" and #{files.size - 5} more" if files.size > 5}"
    end

    # A file holds a list of suspicions (or `suspicions:` with one); each
    # --suspect is one suspicion as a YAML flow mapping.
    def self.parse(files, inline)
      raw = files.flat_map do |f|
        doc = begin
          YAML.safe_load(quote_ruby(File.read(f)), aliases: false)
        rescue SystemCallError => e
          raise Holdfast::Error, "#{f}: #{e.message.sub(/ @ \w+ - .*/, "")}"
        rescue Psych::SyntaxError => e
          raise Holdfast::Error, "#{f}: line #{e.line} column #{e.column}: #{e.problem}; a value that holds `: ` or starts with a quote must be quoted ('...')"
        end
        doc = doc["suspicions"] if doc.is_a?(Hash) && doc.key?("suspicions")
        Array(doc).map { [_1, f] }
      end
      raw += inline.map { [YAML.safe_load(quote_ruby(_1)), "--suspect"] }
      raise Holdfast::Error, "no suspicion given; pass a YAML file or --suspect" if raw.empty?

      raw.each_with_index.map { |(h, from), i| suspicion(h, i, from) }
    end

    # `do: x.call(a: 1)` is Ruby, not a YAML mapping: a plain value of says,
    # do, expect or pause is quoted before YAML reads it. So is an item of a
    # block list under race or expect, and any other plain value that holds
    # `: ` (a given written as Ruby), which YAML would refuse.
    def self.quote_ruby(text)
      quote = ->(s) { "'#{s.gsub("'", "''")}'" }
      # In `expect: [no error, calls(X, :y).empty?]` each item is quoted,
      # since `:y` in a YAML flow list is not a value.
      text = text.gsub(/^(\s*(?:-\s+)?(?:race|expect):[ \t]+)\[(.*)\][ \t]*$/) do
        "#{$1}[#{flow_items($2).map { |item| Prism.parse(item).value.statements.body.then { _1.size == 1 && _1.first.is_a?(Prism::StringNode) } ? item : quote.(item) }.join(", ")}]"
      end
      text = text.gsub(/^(\s*(?:-\s+)?(?:says|do|expect|pause):[ \t]+)(?!['"\[{|>])(\S.*?)[ \t]*$/) { "#{$1}#{quote.($2)}" }
      text = text.gsub(/^(\s*(?:race|expect):[ \t]*\n)((?:\s+-[ \t]+.*\n?)+)/) do
        $1 + $2.gsub(/^(\s+-[ \t]+)(?!['"\[{|>])(\S.*?)[ \t]*$/) { "#{$1}#{quote.($2)}" }
      end
      text.gsub(/^(\s+\w+:[ \t]+)(?!['"\[{|>&*!])(\S.*: .*?)[ \t]*$/) { "#{$1}#{quote.($2)}" }
    end

    # The items of a flow list, split at the commas outside brackets and
    # quotes.
    def self.flow_items(text)
      items = [+""]
      depth = 0
      quote = nil
      text.each_char do |c|
        if quote
          quote = nil if c == quote
        elsif %w[" '].include?(c) then quote = c
        elsif "([{".include?(c) then depth += 1
        elsif ")]}".include?(c) then depth -= 1
        elsif c == "," && depth.zero?
          items << +""
          next
        end
        items.last << c
      end
      items.map(&:strip).reject(&:empty?)
    end

    def self.suspicion(h, i, from)
      raise Holdfast::Error, "suspicion #{i + 1} in #{from} is not a mapping" unless h.is_a?(Hash)

      h = h.transform_keys(&:to_s)
      unknown = h.keys - KEYS
      raise Holdfast::Error, "suspicion #{i + 1}: unknown key(s) #{unknown.join(", ")}; the keys are #{KEYS.join(", ")}" if unknown.any?
      raise Holdfast::Error, "suspicion #{i + 1}: give `do` (one action) or `race` (two)" unless h["do"].nil? ^ h["race"].nil?
      raise Holdfast::Error, "suspicion #{i + 1}: `race` takes two actions" if h["race"] && Array(h["race"]).size != 2
      raise Holdfast::Error, "suspicion #{i + 1}: `expect` is missing" if h["expect"].to_s.strip.empty? && !h["expect"].is_a?(Array)

      # In a flow list (`expect: [a, x.where(id: 1).none?]`) YAML reads
      # `id: 1` as a mapping; the Ruby is joined back.
      ruby = ->(v) { v.is_a?(Hash) && v.size == 1 ? "#{v.keys.first}: #{v.values.first}" : v.to_s }
      %w[do expect race].each { |k| h[k] = h[k].is_a?(Array) ? h[k].map(&ruby) : ruby.(h[k]) if h.key?(k) }
      says = h["says"].to_s.strip
      calls = []
      errors = false
      expects = Array(h["expect"]).map(&:to_s).map do |text|
        e = expectation(text)
        calls |= e[:calls]
        errors ||= e[:errors]
        e
      end
      acts = h["race"] ? h["race"].map(&:to_s) : [h["do"].to_s]
      label = "suspicion #{i + 1}#{" (#{says})" unless says.empty?}"
      acts.each { |a| ruby!(a, "#{label}: `#{h["race"] ? "race" : "do"}`") }
      expects.each { |e| ruby!(e[:ruby], "#{label}: `expect: #{e[:text]}`") }
      # `do` and `expect` share the locals `do` sets and the instance
      # variables of the object it runs on; a name `given` already has stays
      # the record, so the given blocks still read it.
      shared = acts.flat_map { Prism.parse(_1).value.locals }.uniq - Hash(h["given"]).keys.map(&:to_sym)
      set = acts.flat_map { ivars(_1, :write) }
      unset = expects.flat_map { ivars(_1[:ruby], :read) }.uniq - set
      raise Holdfast::Error, "#{label}: `expect` reads #{unset.join(", ")}, which no `do` sets; set it in `do`, or read the record by its `given` name" if unset.any?
      Suspicion.new(id: "s#{i + 1}_#{Holdfast.slug(says.empty? ? acts.first : says).tr("-", "_")[0, 48].sub(/_\z/, "")}",
                    says:, given: Hash(h["given"]), acts:, pause: h["pause"]&.to_s,
                    expects:, calls:, errors:, source: from, shared:)
    end

    # A line that is not Ruby fails here, before any database work, naming
    # the line, instead of as a spec rspec cannot load.
    def self.ruby!(code, where)
      error = Prism.parse(code).errors.first or return
      raise Holdfast::Error, "#{where} is not Ruby (#{error.message} at column #{error.location.start_column + 1}): #{code}"
    end

    IVAR_NODES = { write: [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
                           Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableTargetNode],
                   read: [Prism::InstanceVariableReadNode] }.freeze

    def self.ivars(code, kind)
      walk = ->(n) { [n, *n.compact_child_nodes.flat_map(&walk)] }
      walk.(Prism.parse(code).value).select { |n| IVAR_NODES.fetch(kind).any? { n.is_a?(_1) } }.map(&:name)
    end

    # The few lines an agent writes most often, and Ruby for the rest. Each
    # operand of a top-level `&&` or `||` may be a short form too, so
    # `no error && fine.paid?` is two checks, not a call to `no`.
    def self.expectation(text)
      t = text.strip
      pieces, ops = logic_split(t)
      return short_form(t) || ruby_form(t) if ops.empty?

      forms = pieces.map { short_form(_1) || ruby_form(_1) }
      ruby = forms.each_with_index.map { |f, i| "#{" #{ops[i - 1]} " if i.positive?}#{short_form(f[:text]) ? "(#{f[:ruby]})" : f[:ruby]}" }.join
      parts = if ops.uniq.size == 1 then forms.map { [_1[:text], _1[:ruby], _1[:observe] || observed_side(_1[:ruby])] }
              else operands(ruby).map { [_1, _1, observed_side(_1)] }
              end
      { text: t, ruby:, observe: nil, parts:, calls: forms.flat_map { _1[:calls] }.uniq, errors: forms.any? { _1[:errors] } }
    end

    def self.short_form(t)
      case t
      when /\Ano error\z/i then { text: t, ruby: "error.nil?", observe: "error", calls: [], errors: true }
      when /\Araises ([A-Z][\w:]*)\z/ then { text: t, ruby: "error.is_a?(#{$1})", observe: "error", calls: [], errors: true }
      when /\Ano ([A-Z][\w:]*) (\w+)\z/
        { text: t, ruby: "calls(#{$1}, :#{$2}).empty?", observe: "calls(#{$1}, :#{$2})", calls: [[$1, $2]], errors: false }
      when /\A([A-Z][\w:]*) (\w+)(?: (once|twice|(\d+) times))?\z/
        n = { "once" => 1, "twice" => 2 }[$3] || $4&.to_i
        { text: t, ruby: n ? "calls(#{$1}, :#{$2}).size == #{n}" : "calls(#{$1}, :#{$2}).any?", observe: "calls(#{$1}, :#{$2})", calls: [[$1, $2]], errors: false }
      end
    end

    def self.ruby_form(t)
      parts = operands(t)
      { text: t, ruby: t, observe: (observed_side(t) if parts.empty?), parts: parts.map { [_1, _1, observed_side(_1)] },
        calls: [], errors: t.match?(/\berror(s?)\b/) }
    end

    # The operands of the `&&` and `||` outside brackets and quotes, and the
    # operators between them. Text, not Prism: a short form is not Ruby.
    def self.logic_split(text)
      pieces = [+""]
      ops = []
      depth = 0
      quote = nil
      i = 0
      while i < text.size
        c = text[i]
        if quote
          quote = nil if c == quote && text[i - 1] != "\\"
        elsif %w[" '].include?(c) then quote = c
        elsif "([{".include?(c) then depth += 1
        elsif ")]}".include?(c) then depth -= 1
        elsif depth.zero? && %w[&& ||].include?(text[i, 2])
          ops << text[i, 2]
          pieces << +""
          i += 2
          next
        end
        pieces.last << c
        i += 1
      end
      pieces = pieces.map(&:strip)
      pieces.any?(&:empty?) ? [[text], []] : [pieces, ops]
    end

    def self.top_node(ruby)
      node = Prism.parse(ruby).value.statements.body.first
      node = node.body.body.first while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
      node
    end

    # `a && b && c` is three operands, so a failed line can name the one
    # that failed; a single comparison has none.
    def self.operands(ruby)
      node = top_node(ruby)
      return [] unless node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)

      kind = node.class
      flat = ->(n) { n.is_a?(kind) ? flat.(n.left) + flat.(n.right) : [n.slice] }
      flat.(node)
    rescue StandardError
      []
    end

    # For `a.b == c` show what `a.b` was.
    def self.observed_side(ruby)
      node = top_node(ruby)
      return ruby unless node.is_a?(Prism::CallNode) && COMPARE.include?(node.name) && node.receiver

      node.receiver.slice
    rescue StandardError
      ruby
    end

    RELATIVE = /\A([+-]?)(\d+)\s*(s|m|min|h|d|w)\z/
    UNITS = { "s" => "seconds", "m" => "minutes", "min" => "minutes", "h" => "hours", "d" => "days", "w" => "weeks" }.freeze

    def self.value(v, names)
      case v
      when RELATIVE
        sign, n, unit = $1, $2.to_i, UNITS.fetch($3)
        "#{n}.#{n == 1 ? unit.chomp("s") : unit}.#{sign == "-" ? "ago" : "from_now"}"
      when String then names.include?(v) ? v : v.inspect
      when Hash
        raise Holdfast::Error, "a nested value in `given` is {ruby: \"...\"}" unless v.keys.map(&:to_s) == ["ruby"]

        v.values.first.to_s
      when Array then "[#{v.map { value(_1, names) }.join(", ")}]"
      else v.inspect
      end
    end

    def self.given_lines(given)
      names = []
      given.map do |name, attrs|
        name = name.to_s
        # `{ruby: "..."}` in place of the attributes is the same Ruby a bare
        # string is; any other plain value is that value.
        attrs = attrs.values.first.to_s if attrs.is_a?(Hash) && attrs.keys.map(&:to_s) == ["ruby"]
        if attrs.is_a?(String) || !(attrs.is_a?(Hash) || attrs.nil?)
          names << name
          ruby = attrs.is_a?(String) ? attrs : attrs.inspect
          next "build :#{name}, #{ruby.inspect} do #{ruby} end"
        end
        attrs = Hash(attrs).transform_keys(&:to_s)
        opts = []
        opts << "factory: :#{attrs.delete("factory")}" if attrs.key?("factory")
        opts << "traits: #{Array(attrs.delete("traits")).map { ":#{_1}" }.join(", ").then { "[#{_1}]" }}" if attrs.key?("traits")
        opts += attrs.map { |k, v| "#{k}: #{value(v, names)}" }
        names << name
        "make #{[":#{name}", *opts].join(", ")}"
      end
    end

    def self.spec(s, record)
      check = lambda do |e|
        observe = e[:observe] ? ", observe: proc { #{e[:observe]} }" : ""
        parts = Array(e[:parts]).map { |text, ruby, seen| "[#{text.inspect}, proc { #{ruby} }, #{seen ? "proc { #{seen} }" : "nil"}]" }
        parts = parts.any? ? ",\n          parts: [#{parts.join(", ")}]" : ""
        "expectation(#{e[:text].inspect}#{observe}#{parts}) { #{e[:ruby]} }"
      end
      calls = s.calls.map { "[#{_1}, :#{_2}]" }
      <<~RUBY
        # holdfast check: #{s.says}
        # This example fails while the suspicion holds. Keep it once the code is fixed.
        require #{record.helper.inspect}
        require_relative "holdfast_check"

        RSpec.describe "suspicion #{s.id}", type: :request do
          include HoldfastCheck
        #{"  self.use_transactional_tests = false\n" if s.acts.size > 1}
          it #{s.says.inspect} do
        #{"    #{s.shared.join(" = ")} = nil # set by `do`, read by `expect`\n" if s.shared.any?}    holdfast_suspicion #{s.id.inspect},
              given: proc {
        #{given_lines(s.given).map { "        #{_1}" }.join("\n")}
              },
              acts: [
        #{s.acts.map { "        act(#{_1.inspect}) { #{_1} }" }.join(",\n")}
              ],#{"\n      pause: #{s.pause.inspect}," if s.acts.size > 1 && s.pause}#{"\n      calls: [#{calls.join(", ")}]," if calls.any?}#{"\n      errors: true," if s.errors}#{"\n      shared: binding," if s.shared.any?}
              expects: [
        #{s.expects.map { "        #{check.(_1)}" }.join(",\n")}
              ]
          end
        end
      RUBY
    end

    def self.run_side(root, record, side, rev, suspicions, place)
      out = File.join(root, place.out, "runs", side)
      FileUtils.rm_rf(out) if out.include?("/.holdfast/check/")
      FileUtils.mkdir_p(out)
      tree = root
      if rev
        tree = File.join(Dir.mktmpdir("holdfast-check"), "tree")
        Change.git(root, "worktree", "add", "--quiet", "--detach", tree, rev)
        # Both sides build the world with the same factories and helpers:
        # test support is not the behavior under comparison.
        SUPPORT.each do |part|
          src = File.join(root, part)
          next unless File.exist?(src)

          FileUtils.rm_rf(File.join(tree, part)) if File.directory?(src)
          FileUtils.mkdir_p(File.dirname(File.join(tree, part)))
          FileUtils.cp_r(src, File.join(tree, part))
        end
      end
      env = Record.side_env(record.data, SIDE_NUMBERS.fetch(side)).merge("BUNDLE_GEMFILE" => File.join(tree, "Gemfile"), "HOLDFAST_CHECK_OUT" => out)
      log = []
      if record.side_setup && !schema_current?(root, tree, side)
        o, st = Open3.capture2e(env, "/bin/sh", "-c", record.side_setup, chdir: tree)
        log << o
        return { "failure" => "setup on #{side}: `#{record.side_setup}` exited #{st.exitstatus}: #{Record.failure_lines(o).join(" ")}" } unless st.success?

        schema_mark(root, tree, side)
      end
      files = suspicions.map { "#{place.specs}/#{_1.id}_spec.rb" }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      o, = Open3.capture2e(env, "/bin/sh", "-c", "#{record.bundle}rspec #{files.join(" ")} --format progress --format json --out #{File.join(out, "rspec.json")}", chdir: tree)
      File.write(File.join(out, "rspec.log"), o)
      rspec = JSON.parse(File.read(File.join(out, "rspec.json"))) rescue {}
      reports = suspicions.to_h { |s| [s.id, (JSON.parse(File.read(File.join(out, "#{s.id}.json"))) rescue nil)] }
      examples = Array(rspec["examples"]).to_h { [File.basename(_1["file_path"].to_s, "_spec.rb"), _1] }
      { "rev" => rev, "out" => out, "reports" => reports, "examples" => examples, "log" => o,
        "seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) }
    ensure
      if rev && tree && tree != root && tree.start_with?(Dir.tmpdir)
        system("git", "worktree", "remove", "--force", tree, chdir: root, out: File::NULL, err: File::NULL)
        FileUtils.rm_rf(File.dirname(tree))
      end
    end

    # A side's database is set up again only when its schema file changed.
    def self.schema_digest(tree) = %w[db/schema.rb db/structure.sql].filter_map { File.file?(File.join(tree, _1)) && Digest::SHA1.file(File.join(tree, _1)).hexdigest }.join
    def self.schema_mark_path(root, side) = File.join(Holdfast.dir(root), "check-#{side}.schema")
    def self.schema_current?(root, tree, side) = File.file?(schema_mark_path(root, side)) && File.read(schema_mark_path(root, side)) == schema_digest(tree)
    def self.schema_mark(root, tree, side) = File.write(schema_mark_path(root, side), schema_digest(tree))

    def self.side_result(run, s)
      return { "result" => "could_not_run", "phase" => "setup", "error" => run["failure"] } if run["failure"]

      report = run["reports"][s.id]
      ex = run["examples"][s.id]
      return report if report && report["result"]

      # The spec ended before it wrote a result: the first line rspec saw
      # and the first frame of the kept spec stand in, never an empty reason.
      msg = ex&.dig("exception", "message").to_s.lines.first.to_s.strip
      msg = run["log"].to_s.lines.grep(/Error|error/).first.to_s.strip if msg.empty?
      frame = Array(ex&.dig("exception", "backtrace")).find { _1.include?("spec/holdfast/") }
      msg = "rspec printed nothing for it; read #{run["out"]}/rspec.log" if msg.empty?
      { "result" => "could_not_run", "phase" => "spec", "error" => "the spec did not finish: #{ex&.dig("exception", "class")} #{msg[0, 400]}#{" at #{frame[%r{spec/holdfast/\S+}]}" if frame}".squeeze(" ") }
    end

    def self.describe(r)
      case r["result"]
      when "could_not_run" then "could not run (#{r["phase"] || "spec"}): #{r["error"]}"
      when "confirmed" then "confirmed: #{r["why"]}"
      else
        seen = Array(r["checks"]).map { "#{_1["expect"]} holds#{" (observed #{_1["observed"]})" if _1["observed"]}" }.join("; ")
        (r["why"] || seen).start_with?("refuted") ? (r["why"] || seen) : "refuted: #{r["why"] || seen}"
      end
    end

    def self.check_line(c) = "#{c["expect"]} #{c["holds"] ? "holds" : "fails"}#{" (#{c["observed"]})" if c["observed"]}#{": #{c["failed"].join("; ")}" if c["failed"]}"

    def self.row(s, reports, change, sides, record, place)
      head = side_result(reports["head"], s)
      evidence = []
      evidence << "pause points tried: #{head["pauses"].join("; ")}" if head["pauses"]
      Array(head["orders"]).sort_by { |label, _| label == head["order"] ? 0 : 1 }.each { |label, run| evidence << "#{label}: #{run["result"] == "could_not_run" ? "could not run: #{run["error"]}" : "#{Array(run["outcomes"]).join("; ")}#{"; #{run["paused"]}" if run["paused"]}; #{Array(run["checks"]).map { check_line(_1) }.join("; ")}"}" }
      evidence += Array(head["outcomes"]).map { "ran: #{_1}" } unless head["orders"]
      evidence += Array(head["checks"]).map { check_line(_1) } unless head["orders"]
      head_only = false
      if sides.key?("base")
        base = side_result(reports["base"], s)
        # A base that has no such method, constant, attribute or route
        # predates the feature: it is not evidence either way.
        absent = base["result"] == "could_not_run" && base["absent"] && base["absent"] != head["absent"]
        head_only = (absent || base["result"] == "could_not_run") && head["result"] != "could_not_run"
        line = if absent then "base cannot run it (feature absent: #{base["absent"]})"
               elsif base["result"] == "could_not_run" then "base could not run it (#{base["phase"] || "spec"}: #{base["error"]})"
               else
                 tail = if head["result"] == "confirmed" then base["result"] == "confirmed" ? "; it was there before the change" : "; the change brings it in"
                        elsif base["result"] == "confirmed" then "; the change removes it"
                        else ""
                        end
                 "#{describe(base)}#{tail}"
               end
        evidence.unshift("base #{change.short(change.base)}: #{line}")
      end
      ex = reports.dig("head", "examples", s.id)
      spec_path = "#{place.specs}/#{s.id}_spec.rb"
      # The database the head side ran on, so the line runs as printed even
      # where the app's own test database was never created.
      db = Record.side_env(record.data, SIDE_NUMBERS.fetch("head")).slice("DATABASE_URL", "TEST_ENV_NUMBER").map { "#{_1}=#{_2}" }.join(" ")
      repro = "#{db} #{record.bundle}rspec #{spec_path}".strip
      case head["result"]
      when "confirmed"
        failure = ex&.dig("exception", "message").to_s.strip
        evidence << "spec output: #{failure.lines.first(4).map(&:strip).join(" ")}" unless failure.empty?
        Verdict.of(target: s.says, stage: "check", kind: "confirmed", reason: "#{"confirmed on head only: " if head_only}#{head["why"]}", evidence:, repro:,
                   scope: spec_path, next_step: "keep #{spec_path}; it fails until the code is fixed")
      when "refuted"
        Verdict.of(target: s.says, stage: "check", kind: "refuted", reason: "#{"on head (base cannot run it): " if head_only}#{describe(head).delete_prefix("refuted: ")}", evidence:, scope: spec_path,
                   next_step: "nothing to fix for this suspicion; delete #{spec_path} or keep it as a test")
      else
        step = case head["phase"]
               when ->(_) { head["absent"] } then "this tree has #{head["absent"]}; check the name, or run where the change that adds it is checked out"
               when "given" then "fix the named part of `given` (an attribute, a factory: or a traits: key), then holdfast check again"
               when "do" then "the action raised before `expect` ran; if that error is the bug, write `expect: no error`, else fix `do`"
               when "pause" then "name a method the first action passes through as `pause: Class#method`"
               else "read the error, fix the suspicion, then holdfast check again"
               end
        Verdict.of(target: s.says, stage: "check", kind: "could_not_run", reason: "#{head["phase"] || "spec"}: #{head["error"]}", evidence:, scope: spec_path, repro:, next_step: step)
      end
    end
  end
end
