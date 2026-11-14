# rbs_inline: enabled

module Holdfast
  # A thing the run checks: a changed method, a reader of a changed value
  # that is not a plain call site, or a method the caller named before a
  # change. +tests+ are the existing test files that exercise it, at base.
  Target = Data.define(
    :name, #: String
    :kind, #: String
    :file, #: String
    :line, #: Integer
    :why, #: Array[String]
    :tests, #: Array[String]
    :source, #: String?
    :reader, #: json?
    :span, #: json
    :reads #: json?
  )

  class Target
    # @rbs!
    #   def self.new: (name: String, kind: String, file: String, line: Integer, why: Array[String], tests: Array[String],
    #                  source: String?, reader: json?, span: json, ?reads: json?) -> instance
    #               | ...

    #: (?reads: json?, **untyped rest) -> void
    def initialize(reads: nil, **rest) = super(reads:, **rest)
    #: () -> bool
    def caller? = why.first == "caller"
    #: () -> bool
    def unchanged? = %w[caller affected].include?(why.first)
    #: () -> bool
    def added? = why.first == "added"
    #: () -> bool
    def method? = name.match?(/\A[A-Z][\w:]*[#.][a-z_]\w*[?!=]?\z/)
  end

  module Stages
    # Which targets this run checks and which tests belong to each. The
    # changed methods and their tests come from jitcatch's change brief
    # (grep, or a jitcatch-coverage-v1 file when the record names one); the
    # readers of each changed value come from the readers list.
    module Select
      Result = Data.define(
        :targets, #: Array[Target]
        :verdicts, #: Array[Verdict]
        :notes #: Array[String]
      )

      #: (Change, Record) -> Result
      def self.run(change, record)
        jc = jitcatch(change, record)
        brief = jc.build
        methods = brief["methods"]
        methods = methods.select { |m| change.named.any? { named_match?(_1, m) } } unless change.changed?
        methods = methods.reject { _1["file"].start_with?("db/") || accessor_only?(_1) }
        removed, kept = methods.partition { _1["change"] == "removed" }
        targets = kept.map do |m|
          Target.new(name: m["name"], kind: "method", file: m["file"], line: m["start_line"],
                     why: [m["change"], ("reads #{brief["constants"].find { |k| k["id"] == m["via_constant"] }&.dig("name")}, which the change edits" if m["via_constant"])].compact,
                     tests: (m["existing_tests"] + m["entry_point_tests"]).map { _1["file"] }.uniq,
                     source: [m["old_source"], m["new_source"]].compact.join("\n"), reader: nil,
                     span: m.slice("old_start", "old_end", "new_start", "new_end"),
                     reads: Callers.value_of(m, brief, change)&.then { |v| { "constant" => v.constant, "values" => v.values, "model" => v.model, "column" => v.column, "outside" => v.outside }.compact })
        end
        targets = Callers.targets(jc, brief, change) + targets if change.changed?
        verdicts = [] #: Array[Verdict]
        unless change.changed?
          missing = change.named.reject { |n| kept.any? { named_match?(n, _1) } }
          verdicts += missing.map do |n|
            Verdict.of(target: n, stage: "select", kind: "unchecked", reason: "no method or file named #{n} at #{change.tree_label}",
                       next_step: "name it as Const#method, Const.method, or a path under app/, then run holdfast run --target again")
          end
        end
        targets += readers(brief, test_files(change, record)) if change.changed?
        warnings = change.changed? ? brief["warnings"].map { "jitcatch warning: #{_1}" } : [] #: Array[String]
        notes = removed.map { "removed: #{_1["name"]}" } + warnings
        notes << "tests chosen by #{brief["existing_tests_via"]}" unless change.changed?
        notes << "tests chosen by #{brief["existing_tests_via"]}#{" (#{record.coverage})" if record.coverage}; a row counts a test only when it reached the changed lines in this run" if change.changed?
        Result.new(targets:, verdicts:, notes:)
      end

      #: (Change, Record) -> JitCatch::Changes
      def self.jitcatch(change, record)
        base = change.changed? ? change.base : empty_parent(change)
        JitCatch::Changes.new(JitCatch::GitRepo.new(change.root), base, change.head, readers: change.changed?,
                              coverage: record.coverage&.then { File.join(change.root, _1) })
      end

      # Reading from the first commit's parent makes every method "added", so
      # the same brief lists each method of head with its tests.
      #: (Change) -> String
      def self.empty_parent(change)
        first = Change.git(change.root, "rev-list", "--max-parents=0", change.head).split.last
        "#{first}^"
      end

      # A member a Data.define or attr_reader line adds holds no logic of its
      # own; the methods that read it are the targets.
      #: (json) -> bool
      def self.accessor_only?(m) = m["change"] == "added" && !m["new_source"].to_s.lstrip.start_with?("def ")

      #: (String named, json method) -> bool
      def self.named_match?(named, method) = method["name"] == named || method["file"] == named

      #: (Change, Record) -> Array[String]
      def self.test_files(change, record)
        Change.git(change.root, "ls-tree", "-r", "--name-only", change.base, "--", "spec", "test")
              .lines.map(&:strip).select { _1.end_with?(record.test_suffix) }
      end

      # The readers list names a line, not a test. The tests named after the
      # reader's file (closures_controller.rb, views/closures/ -> closures_spec)
      # are the nearest the harness can pick without coverage; a row says so.
      #: (String file, Array[String] tests) -> Array[String]
      def self.tests_named_after(file, tests)
        stem = file.start_with?("app/views/") ? file.split("/")[2] : File.basename(file, ".*").sub(/_controller\z/, "")
        tests.select { File.basename(_1).sub(/_(spec|test)\.rb\z/, "").sub(/_controller\z/, "") == stem }
      end

      # jitcatch's readers: code that reads a changed value without calling it
      # by name (a scope's SQL, a validation, a default, a page).
      #: (json brief, Array[String] tests) -> Array[Target]
      def self.readers(brief, tests)
        Array(brief.dig("readers", "rows")).reject { _1["file"].start_with?("spec/", "test/") }.map do |row|
          Target.new(name: "#{row["file"]}:#{row["line"]}", kind: "reader", file: row["file"], line: row["line"],
                     why: ["#{row["rank"]} (#{row["value"]})", row["why"]], tests: tests_named_after(row["file"], tests), source: nil, reader: row, span: {})
        end
      end
    end
  end
end
