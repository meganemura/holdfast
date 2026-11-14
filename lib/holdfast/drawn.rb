# rbs_inline: enabled

module Holdfast
  # What an input has to draw before a row may say clean: each value the
  # change added or removed that the target can see (a member of a changed
  # list or table constant it reads, a literal a changed line compares
  # with), and each branch the change added to it. Tests that reach a line
  # and agree say nothing about a value none of them drew: a scope that
  # stopped selecting `in_transit` agrees on every hold that is not in
  # transit.
  module Drawn
    # arm is set for a branch whose body shares the line with its condition
    # (`return x if y`): every run of that line counts it, so only branch
    # coverage, matched on the body's span, can tell whether the body ran.
    Need = Data.define(
      :value, #: String?
      :file, #: String
      :line, #: Integer?
      :why, #: String
      :arm #: String?
    )

    class Need
      # @rbs!
      #   def self.new: (value: String?, file: String, line: Integer?, why: String, ?arm: String?) -> instance
      #               | ...

      #: (value: String?, file: String, line: Integer?, why: String, ?arm: String?) -> void
      def initialize(value:, file:, line:, why:, arm: nil) = super
      #: () -> String
      def label = value ? value.inspect : "the branch at #{File.basename(file)}:#{line}"
    end
    COMPARE = %i[== != === include? in? eql?].freeze #: Array[Symbol]
    # What a test ran in a file it never reached.
    NONE = Array.new.freeze #: Array[untyped]

    # @rbs self.@constants: Hash[[String, String], Hash[String, json]]

    # Qualified constant name => { "added" => [...], "removed" => [...] } for
    # every list or table constant the change edits, adds or deletes.
    #: (Change) -> Hash[String, json]
    def self.constants(change)
      @constants ||= {} #: Hash[[String, String], Hash[String, json]]
      @constants[[change.base, change.head]] ||= begin
        files = Change.git(change.root, "diff", "--name-only", change.base, change.head, "--", "app", "lib").lines.map(&:strip).select { _1.end_with?(".rb") }
        table = {} #: Hash[String, json]
        files.each_with_object(table) do |file, out|
          old = members(show(change, change.base, file))
          new = members(show(change, change.head, file))
          (old.keys | new.keys).each do |name|
            a, r = Array(new[name]) - Array(old[name]), Array(old[name]) - Array(new[name])
            out[name] = { "added" => a, "removed" => r, "file" => file } if a.any? || r.any?
          end
        end
      end
    end

    #: (Change change, String rev, String file) -> String
    def self.show(change, rev, file)
      out, status = Open3.capture2("git", "show", "#{rev}:#{file}", chdir: change.root, err: File::NULL)
      status.success? ? out : ""
    end

    # NAME = %w[...] / [...] / { "k" => ... } (with or without .freeze), by
    # its qualified name.
    #: (String) -> Hash[String, Array[String]]
    def self.members(source)
      found = {} #: Hash[String, Array[String]]
      walk = lambda do |node, nesting|
        case node
        when Prism::ClassNode, Prism::ModuleNode
          inner = nesting + [node.constant_path.slice]
          node.compact_child_nodes.each { walk.(_1, inner) }
          next
        when Prism::ConstantWriteNode
          value = node.value
          value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze && value.receiver
          list = case value
                 when Prism::ArrayNode then value.elements.filter_map { literal(_1) }
                 when Prism::HashNode then value.elements.filter_map { literal(_1.key) if _1.is_a?(Prism::AssocNode) }
                 end
          found[(nesting + [node.name.to_s]).join("::")] = list if list&.any?
        end
        node.compact_child_nodes.each { walk.(_1, nesting) }
      end
      walk.(Prism.parse(source).value, [])
      found
    end

    #: (Prism::Node?) -> String?
    def self.literal(node) = node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode) ? node.unescaped : nil

    # The needs of one target: the changed constants it reads (by a changed
    # line, or as the value a caller was walked from), the literals its
    # changed lines compare with that the other side lacks, and the
    # branches the change added inside it.
    #: (Change change, Target t, changed_lines changed) -> Array[Need]
    def self.needs(change, t, changed)
      table = constants(change)
      out = [] #: Array[Need]
      if (via = t.reads&.fetch("constant", nil)) && (entry = lookup(table, via))
        out += members_needs(via, entry)
      end
      span = t.span || {}
      head_lines = Array(changed.dig(t.file, "head")).select { |l| span["new_start"] && (span["new_start"]..span["new_end"]).cover?(l) }
      base_lines = Array(changed.dig(t.file, "base")).select { |l| span["old_start"] && (span["old_start"]..span["old_end"]).cover?(l) }
      head_src = show(change, change.head, t.file)
      base_src = show(change, change.base, t.file)
      head_ast = Prism.parse(head_src).value
      base_ast = Prism.parse(base_src).value
      sides = [[head_ast, head_lines], [base_ast, base_lines]] #: Array[[Prism::ProgramNode, Array[Integer]]]
      sides.each do |ast, lines|
        nodes(ast) { |n| lines.include?(n.location.start_line) && (n.is_a?(Prism::ConstantReadNode) || n.is_a?(Prism::ConstantPathNode)) }
          .each { |n| (entry = lookup(table, n.slice)) && (out += members_needs(n.slice, entry)) }
      end
      head_vals = compared(head_ast, head_lines)
      base_vals = compared(base_ast, base_lines)
      head_all = compared(head_ast, span["new_start"] ? (span["new_start"]..span["new_end"]).to_a : [])
      base_all = compared(base_ast, span["old_start"] ? (span["old_start"]..span["old_end"]).to_a : [])
      (head_vals - base_all).each { out << Need.new(value: _1, file: t.file, line: nil, why: "a changed line of #{t.name} compares with it") }
      (base_vals - head_all).each { out << Need.new(value: _1, file: t.file, line: nil, why: "#{t.name} no longer compares with it") }
      branches(head_ast, head_lines).each { |line, arm, text| out << Need.new(value: nil, file: t.file, line:, arm:, why: "the change adds `#{text}`") }
      out.uniq { [_1.value, _1.line] }
    end

    #: (Hash[String, json] table, String name) -> json?
    def self.lookup(table, name)
      return table[name] if table.key?(name)

      hit = table.keys.select { _1 == name || _1.end_with?("::#{name.split("::").last}") && name.split("::").last == _1.split("::").last }
      hit.size == 1 ? table[hit.first] : nil
    end

    #: (String name, json entry) -> Array[Need]
    def self.members_needs(name, entry)
      entry["added"].map { Need.new(value: _1, file: entry["file"], line: nil, why: "#{name} adds it") } +
        entry["removed"].map { Need.new(value: _1, file: entry["file"], line: nil, why: "#{name} drops it") }
    end

    # String and symbol literals in a comparison, a `when`, or an `in` on
    # the given lines.
    #: (Prism::Node ast, Array[Integer] lines) -> Array[String]
    def self.compared(ast, lines)
      return [] if lines.empty?

      vals = [] #: Array[String?]
      nodes(ast) { lines.include?(_1.location.start_line) }.each do |n|
        case n
        when Prism::CallNode
          next unless COMPARE.include?(n.name)

          ([n.receiver] + Array(n.arguments&.arguments)).each do |x|
            vals << literal(x) if literal(x)
            vals += x.elements.filter_map { literal(_1) } if x.is_a?(Prism::ArrayNode)
          end
        when Prism::WhenNode then vals += n.conditions.filter_map { literal(_1) }
        when Prism::InNode then vals << literal(n.pattern) if literal(n.pattern)
        end
      end
      vals.compact.uniq
    end

    # Each if, unless, elsif, when or in that starts on a changed line,
    # with the first line of its body: reaching it is drawing the branch. A
    # body on the condition's own line also carries its span.
    # Each as [body line, arm or nil, the branch's first line].
    #: (Prism::Node ast, Array[Integer] lines) -> Array[[Integer, String?, String?]]
    def self.branches(ast, lines)
      nodes(ast) { |n| (n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode) || n.is_a?(Prism::WhenNode) || n.is_a?(Prism::InNode)) && lines.include?(n.location.start_line) }.filter_map do |n|
        n = n #: Prism::IfNode | Prism::UnlessNode | Prism::WhenNode | Prism::InNode
        body = n.statements&.body&.first or next
        line = body.location.start_line
        # An arm's start alone is ambiguous: the else arm of `x if y` starts where
        # the whole expression does, so the arm is named by its start and end.
        arm = (l = body.location; "#{l.start_line}:#{l.start_column}-#{l.end_line}:#{l.end_column}") if line == n.location.start_line && !n.is_a?(Prism::WhenNode)
        [line, arm, n.slice.lines.first.strip[0, 60]]
      end
    end

    #: (Prism::Node ast) { (Prism::Node) -> boolish } -> Array[Prism::Node]
    def self.nodes(ast, &keep)
      found = [] #: Array[Prism::Node]
      stack = [ast]
      while (n = stack.pop)
        found << n if keep.(n)
        stack.concat(n.compact_child_nodes)
      end
      found
    end

    # A value counts as drawn when one reached test wrote it on both sides:
    # the same input on base and head. Written on one side only, it came
    # from the code under test, not from an input. A branch counts when a
    # reached test ran its first body line on head, or, for a body on the
    # condition's line, took that arm.
    #: (Array[Need] needs, Array[Stages::Diff::Outcome] outcomes, reach reach) -> Array[Need]
    def self.missing(needs, outcomes, reach)
      needs.reject do |need|
        outcomes.any? do |o|
          if need.value then sides_writing(reach, o, need.value).size == 2
          elsif need.arm then Stages::Diff.ran(reach, o, "2").fetch(Stages::Diff::ARMS + need.file, NONE).include?(need.arm)
          else Stages::Diff.ran(reach, o, "2").fetch(need.file, NONE).include?(need.line)
          end
        end
      end
    end

    #: (reach reach, Stages::Diff::Outcome outcome, String value) -> Array[String]
    def self.sides_writing(reach, outcome, value) = %w[1 2].select { Array(reach.dig(outcome.source.path, _1, Stages::Diff::DREW)).include?(value) }

    # "in_transit: written on base only by spec/services/member_merge_spec.rb"
    #: (Array[Need] needs, Array[Stages::Diff::Outcome] outcomes, reach reach) -> Array[String]
    def self.one_sided(needs, outcomes, reach)
      needs.filter_map do |need|
        next unless need.value

        o = outcomes.find { sides_writing(reach, _1, need.value).size == 1 } or next
        side = sides_writing(reach, o, need.value).first == "1" ? "base" : "head"
        "#{need.label} was written on #{side} only, by the code that #{Stages::Diff.shown_path(o.source)} runs, and the tests still agree"
      end
    end
  end
end
