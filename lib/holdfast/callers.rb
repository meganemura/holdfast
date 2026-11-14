# rbs_inline: enabled

module Holdfast
  # The unchanged code that reads a changed value through something else: a
  # scope or a method whose own lines did not change but that reads a
  # constant the change edits, and the methods that call that scope or
  # method, one or two calls up. A reader of the diff stops at the diff, so
  # this is where a break hides; each caller becomes a target with a drafted
  # pin and ranks first.
  #
  # jitcatch's brief names the affected methods and their direct and
  # dynamic callers. The second hop comes from jitcatch's call graph, which
  # it does not publish, so this reads it through the brief's own instance.
  module Callers
    CAP = 8
    Value = Data.define(
      :method, #: json
      :constant, #: String?
      :model, #: String?
      :column, #: String?
      :values, #: Array[String]
      :outside #: String?
    )

    # jitcatch's index of one side and its call graph are not part of its
    # published interface, so they stay untyped here.
    #: (JitCatch::Changes jc, json brief, Change change) -> Array[Target]
    def self.targets(jc, brief, change)
      values = brief["methods"].filter_map { value_of(_1, brief, change) }
      return [] if values.empty?

      head_idx = jc.send(:index_ref, change.head, "head")
      base_idx = jc.send(:index_ref, change.base, "base")
      edges = jc.send(:edges_for, head_idx)
      known = brief["methods"].map { _1["name"] }
      found = {} #: Hash[String, [Value, String]]
      values.each do |v|
        m = v.method
        hop1 = (Array(m["callsites"]).map { _1["enclosing"] } + Array(m["dynamic_callers"]).map { _1["from"] } +
                Hash(m["caller_depths"]).select { _2 == 1 }.keys).uniq
        hop1.each { found[_1] ||= [v, m["name"]] unless skip?(_1, known) }
        hop1.each do |c|
          jc.send(:callers_by_depth, c, edges, 1).each_key { found[_1] ||= [v, c] unless skip?(_1, known) }
        end
      end
      found.first(CAP).filter_map { |name, (v, through)| target(name, v, through, head_idx, base_idx, change) }
    end

    # A value this module walks from: a method the brief marks as affected by
    # a changed constant, or a changed scope.
    #: (json m, json brief, Change change) -> Value?
    def self.value_of(m, brief, change)
      scope = m["new_source"].to_s.lstrip.start_with?("scope ")
      return nil unless m["change"] == "affected" || (m["change"] == "modified" && scope)

      const = brief["constants"].find { _1["id"] == m["via_constant"] }
      old_values = strings(const && const["old_source"])
      new_values = strings(const && const["new_source"])
      owner = m["name"].split(/[#.]/).first
      column = scope && const ? where_column(m["new_source"], const["name"].split("::").last) : nil
      model_file = m["file"] if column
      outside = model_file ? (other_strings(change, model_file) - old_values - new_values).first : nil
      Value.new(method: m, constant: const && const["name"], model: (owner if column), column:,
                values: (old_values | new_values), outside:)
    end

    #: (String name, Array[String] known) -> bool
    def self.skip?(name, known)
      known.include?(name) || !name.match?(/\A[A-Z][\w:]*[#.][a-z_]\w*[?!=]?\z/) ||
        name.split(/[#.]/).first.end_with?("Controller") || name.end_with?("#initialize")
    end

    #: (String name, Value v, String through, untyped head_idx, untyped base_idx, Change change) -> Target?
    def self.target(name, v, through, head_idx, base_idx, change)
      node = head_idx["methods"].find { _1.qualified == name } or return nil
      old = base_idx["methods"].find { _1.qualified == name }
      via = v.constant ? "#{v.method["name"]}, which reads #{v.constant}" : v.method["name"]
      why = through == v.method["name"] ? "calls #{via}" : "calls #{through}, which calls #{via}"
      reads = { "via" => v.method["name"], "constant" => v.constant, "model" => v.model, "column" => v.column,
                "values" => v.values, "outside" => v.outside }.compact
      Target.new(name:, kind: "method", file: node.file, line: node.start_line, why: ["caller", why],
                 tests: tests_for(change, node), source: node.source, reader: nil, reads:,
                 span: { "old_start" => old&.start_line, "old_end" => old&.end_line, "new_start" => node.start_line, "new_end" => node.end_line })
    end

    # Test files at base that name the caller's method, or its class and a
    # request into it; coverage in the run decides which ones reached it.
    #: (Change change, untyped node) -> Array[String]
    def self.tests_for(change, node)
      bare = node.bare_name
      owner = node.qualified.split(/[#.]/).first.split("::").last
      out, = Open3.capture2("git", "grep", "-l", "-w", "-e", bare, change.base, "--", "spec", "test", chdir: change.root)
      named = out.lines.map { _1.strip.sub(/\A#{change.base}:/, "") }
      out2, = Open3.capture2("git", "grep", "-l", "-w", "-e", owner, change.base, "--", "spec", "test", chdir: change.root)
      (named & out2.lines.map { _1.strip.sub(/\A#{change.base}:/, "") }).first(6)
    end

    # The string elements of the first array literal in a source line.
    #: (String?) -> Array[String]
    def self.strings(source)
      return [] unless source

      found = [] #: Array[String]
      walk(Prism.parse(source).value) do |n|
        next unless n.is_a?(Prism::ArrayNode) && found.empty?

        found = n.elements.filter_map { |e| e.unescaped if e.is_a?(Prism::StringNode) || e.is_a?(Prism::SymbolNode) }
      end
      found
    end

    # Every string listed in the model file's array constants (STATUSES), so
    # a draw also holds a value neither side's list holds.
    #: (Change change, String file) -> Array[String]
    def self.other_strings(change, file)
      text = Open3.capture2("git", "show", "#{change.head}:#{file}", chdir: change.root).first
      lists = text.scan(/^\s*[A-Z][A-Z0-9_]*\s*=\s*(%w\[[^\]]*\]|\[[^\]]*\])/) #: Array[[String]]
      lists.flat_map { strings(_1.first) }.uniq
    end

    # The column a scope compares with the constant: `where(status: OPEN)`.
    #: (String? source, String const) -> String?
    def self.where_column(source, const)
      col = nil #: String?
      walk(Prism.parse(source.to_s).value) do |n|
        next unless n.is_a?(Prism::CallNode) && %i[where not].include?(n.name) && n.arguments

        hashes = n.arguments.arguments.grep(Prism::KeywordHashNode) #: Array[Prism::KeywordHashNode]
        hashes.flat_map(&:elements).each do |pair|
          # `where(**OPEN)` splats the constant; it names no column.
          next unless pair.is_a?(Prism::AssocNode)

          val = pair.value
          name = val.is_a?(Prism::ConstantReadNode) ? val.name.to_s : val.is_a?(Prism::ConstantPathNode) ? val.name.to_s : nil
          col ||= pair.key.unescaped if name == const && pair.key.is_a?(Prism::SymbolNode)
        end
      end
      col
    end

    #: (Prism::Node? node) { (Prism::Node) -> void } -> void
    def self.walk(node, &block)
      return unless node

      yield node
      node.compact_child_nodes.each { walk(_1, &block) }
    end
  end
end
