module Holdfast
  # A first inputs file for one method, drafted from what the code says: the
  # method's parameters (a record by a factory of its name, a date by its
  # default), the conditions it branches on, and the literals and constants
  # those conditions compare with. A date argument is drawn around each date
  # column of a record argument that the method reads, because "before the
  # due date" and "after it" are where date code differs.
  #
  # A draft with no placeholder left is complete: the run pins it at once,
  # marked as drafted, and the agent accepts it by copying it to evidence.
  # A draft with a placeholder is only written, and the row names it.
  class Draft
    OFFSETS = [-10, -1, 0, 1, 10].freeze
    ANCHOR = "Date.new(2026, 3, 20)".freeze
    COMPARE = %i[< <= > >= == !=].freeze

    Result = Data.define(:path, :data, :holes, :basis) do
      def complete? = holes.empty?
    end

    def self.path(root, target) = File.join(Holdfast.dir(root), "drafts", "#{Holdfast.slug(target)}.inputs.json")

    def self.for(change, rev, target)
      new(change, rev, target).result
    end

    def initialize(change, rev, target)
      @change, @rev, @target = change, rev, target
    end

    def result
      const_name, kind, name = @target.name.match(/\A(.+?)([#.])(\w+[?!=]?)\z/).captures
      node = method_node(@target.source, name) || scope_node(@target.source)
      holes = []
      basis = []
      return Result.new(path: nil, data: nil, holes: ["no def found for #{name}"], basis:) unless node
      # A controller built with `.new` has no request, so every action fails
      # inside Rails the same way on both sides, and that pin compares nothing.
      if @target.file.start_with?("app/controllers/")
        return Result.new(path: nil, data: nil, holes: ["#{@target.name} runs through a request; write a request spec, or a suspicion whose `do` sends that request, and run holdfast check"], basis:)
      end

      params = node.parameters
      params = params.parameters if params.is_a?(Prism::BlockParametersNode)
      # `_1` and `it` name no parameter a draft could fill by its name.
      if params.is_a?(Prism::NumberedParametersNode) || params.is_a?(Prism::ItParametersNode)
        return Result.new(path: nil, data: nil, holes: ["#{@target.name} takes `_1` or `it` parameters; write its inputs in .holdfast/evidence/"], basis:)
      end
      records = {}
      args = Array(params&.requireds).map do |p|
        param_value(p.name.to_s, nil, records, holes)
      end
      kwargs = {}
      Array(params&.keywords).each do |p|
        default = p.respond_to?(:value) && p.value ? p.value.slice : nil
        if date_default?(default) || date_name?(p.name.to_s)
          kwargs[p.name.to_s] = :date
        elsif default.nil?
          kwargs[p.name.to_s] = param_value(p.name.to_s, nil, records, holes)
        end
      end

      receiver = receiver_for(const_name, kind, holes)
      # A record receiver is drafted like a record argument: its own column
      # reads (`returned_at`, `due_on`) choose its factory's attributes.
      if receiver.is_a?(Hash) && (model = receiver["ruby"].to_s[/\AFactoryBot\.create\(:(\w+)\)\z/, 1])
        records["self"] = model
        receiver = { "factory" => model, "param" => "self" }
      end
      reads = attribute_reads(node, records.keys)
      draws = {}
      overrides = Hash.new { |h, k| h[k] = {} }
      records.each do |param, factory|
        columns = columns_of(factory)
        reads.fetch(param, []).uniq.each do |attr, bounds|
          col = columns[attr] || columns["#{attr.delete_suffix("?")}_at"] && "#{attr.delete_suffix("?")}_at"
          if columns[attr] == "integer" && bounds.any?
            draw = "#{param}_#{attr}"
            draws[draw] = { "one_of" => ([0] + bounds.flat_map { [_1 - 1, _1, _1 + 1] }).select { _1 >= 0 }.uniq.sort }
            overrides[param][attr] = "%{#{draw}}"
            basis << "#{param}.#{attr} around #{bounds.join(", ")}"
          elsif columns[attr] == "datetime" && !attr.match?(/\A(created|updated)_at\z/)
            draw = "#{param}_#{attr}"
            draws[draw] = { "booleans" => true }
            overrides[param][attr] = "(%{#{draw}} ? Time.utc(2026, 3, 1, 12) : nil)"
            basis << "#{param}.#{attr} set and unset"
          elsif attr.end_with?("?") && col.is_a?(String) && columns[col] == "datetime"
            draw = "#{param}_#{col}"
            draws[draw] = { "booleans" => true }
            overrides[param][col] = "(%{#{draw}} ? Time.utc(2026, 3, 1, 12) : nil)"
            basis << "#{param}.#{attr} both ways"
          end
        end
        dates = columns.select { _2 == "date" }.keys
        read = dates & reads.fetch(param, []).map(&:first)
        next unless kwargs.value?(:date) && (anchor = read.first || dates.first)

        overrides[param][anchor] = ANCHOR
        @anchored ||= [param, anchor]
      end
      world = world_for(node, records, draws, overrides, basis)
      offsets = OFFSETS | literals(node).flat_map { [_1, _1 + 1] }.select { _1.abs <= 40 }
      kwargs.each_key do |key|
        next unless kwargs[key] == :date

        draws["#{key}_days"] = { "one_of" => offsets.sort }
        kwargs[key] = { "ruby" => "#{ANCHOR} + %{#{key}_days}" }
        basis << (@anchored ? "#{key}: around #{@anchored.join(".")}" : "#{key}: around #{ANCHOR}")
      end
      factory_args = ->(param) do
        o = overrides[param]
        o.empty? ? "" : ", #{o.map { "#{_1}: #{_2}" }.join(", ")}"
      end
      create = ->(param) { "FactoryBot.create(:#{records[param]}#{factory_args.(param)})" }
      # A drafted world makes each record once, in `before`, so the record
      # the world links to is the one the method receives.
      fill = lambda do |v|
        next v unless v.is_a?(Hash) && v["factory"]

        { "ruby" => world ? "@#{v["param"]}#{v["suffix"]}" : "#{create.(v["param"])}#{v["suffix"]}" }
      end
      entry = { "receiver" => fill.(receiver), "args" => args.map(&fill), "kwargs" => kwargs.transform_values(&fill) }.compact
      if world
        made = records.keys.map { "@#{_1} = #{create.(_1)}" }
        entry = { "before" => { "ruby" => (made + [world]).join("; ") } }.merge(entry)
      end
      entry.delete("kwargs") if entry["kwargs"].empty?
      data = if draws.empty?
               { "inputs" => [entry.merge("note" => "drafted by holdfast")] }
             else
               product = draws.values.map { (_1["one_of"] || [true, false]).size }.inject(1, :*)
               { "generate" => [entry.merge("draws" => draws, "cases" => [product, 120].min, "note" => "drafted by holdfast")] }
             end
      Result.new(path: self.class.path(@change.root, @target.name), data:, holes:, basis:)
    end

    def write(result)
      FileUtils.mkdir_p(File.dirname(result.path))
      File.write(result.path, "#{JSON.pretty_generate(result.data)}\n")
    end

private

# The changed value a caller reads through a scope (Hold.open reads
# OPEN_STATUSES as `status`): one record of the scope's model, linked to
# each record argument it belongs to, with that column drawn over every
# value either side's list holds, one value neither holds, and no record
# at all. A method that tests the constant on an argument's attribute
# (`OPEN_STATUSES.include?(hold.status)`) gets that attribute drawn.
def world_for(node, records, draws, overrides, basis)
  r = @target.reads or return nil
  values = Array(r["values"]) + Array(r["outside"])
  return nil if values.empty?

  const = r["constant"].to_s.split("::").last
  walk(node) do |n|
    next unless n.is_a?(Prism::CallNode) && n.name == :include? && const_name(n.receiver) == const && n.arguments

    pa = param_attr(n.arguments.arguments.first, records.keys) or next
    draw = "#{pa[0]}_#{pa[1]}"
    draws[draw] = { "one_of" => values }
    overrides[pa[0]][pa[1]] = "%{#{draw}}"
    basis << "#{pa[0]}.#{pa[1]} over #{r["constant"]} on both sides"
  end
  return nil unless r["model"] && r["column"]

  factory = Holdfast.snake(r["model"].split("::").last)
  return nil unless factories.include?(factory)

  owners = file_text(model_file(r["model"])).scan(/^\s*belongs_to\s+:(\w+)/).flatten
  links = records.select { |param, f| param != "self" && owners.include?(f) }.map { |param, f| "#{f}: @#{param}" }
  draw = "#{factory}_#{r["column"]}"
  draws[draw] = { "one_of" => values + ["none"] }
  basis << "a #{r["model"]} whose #{r["column"]} is drawn over #{r["constant"]} (read through #{r["via"] || @target.name})"
  "FactoryBot.create(:#{factory}#{links.map { ", #{_1}" }.join}, #{r["column"]}: %{#{draw}}) unless %{#{draw}} == \"none\""
end

def const_name(n) = n.is_a?(Prism::ConstantReadNode) || n.is_a?(Prism::ConstantPathNode) ? n.name.to_s : nil

def model_file(model) = "app/models/#{model.split("::").map { Holdfast.snake(_1) }.join("/")}.rb"

def scope_node(source)
  call = Prism.parse(source.to_s).value.statements&.body&.first
  return nil unless call.is_a?(Prism::CallNode) && call.name == :scope && call.arguments

  call.arguments.arguments[1].then { _1.is_a?(Prism::LambdaNode) ? _1 : call.block.then { |b| b if b.is_a?(Prism::BlockNode) } }
end

    def method_node(source, name)
      found = nil
      walk(Prism.parse(source.to_s).value) { found ||= _1 if _1.is_a?(Prism::DefNode) && _1.name.to_s == name }
      found
    end

    def walk(node, &block)
      return unless node

      yield node
      node.compact_child_nodes.each { walk(_1, &block) }
    end

    def date_default?(src) = src.to_s.match?(/\A(Date\.(current|today)|Time\.(current|zone\.today))/)
    def date_name?(name) = name.match?(/\A(on|date|day)\z|_on\z/)

    def param_value(name, _default, records, holes)
      stem = name.delete_suffix("_id")
      # `request` names the one factory that ends with it (interlibrary_request).
      factory = factories.include?(stem) ? stem : factories.grep(/_#{Regexp.escape(stem)}\z/).then { _1.size == 1 ? _1.first : nil }
      if factory
        records[stem] = factory
        { "factory" => factory, "param" => stem, "suffix" => name.end_with?("_id") ? ".id" : nil }.compact
      else
        holes << name
        { "fill" => "#{name}: a value the method takes" }
      end
    end

    def receiver_for(const_name, kind, holes)
      return nil if kind == "."

      model = Holdfast.snake(const_name.split("::").last)
      return { "ruby" => "FactoryBot.create(:#{model})" } if factories.include?(model) && model_class?(const_name)

      if file_text(@target.file).match?(/^\s*module\s+#{Regexp.escape(const_name.split("::").last)}\b/) && !file_text(@target.file).match?(/^\s*class\s+#{Regexp.escape(const_name.split("::").last)}\b/)
        return { "ruby" => "Object.new.extend(#{const_name})" }
      end

      init = method_node(file_text(@target.file), "initialize")
      required = init && (Array(init.parameters&.requireds) + Array(init.parameters&.keywords).select { _1.is_a?(Prism::RequiredKeywordParameterNode) })
      if required.nil? || required.empty?
        { "ruby" => "#{const_name}.new" }
      else
        holes << "receiver"
        { "fill" => "#{const_name}.new(#{required.map(&:name).join(", ")}): the receiver" }
      end
    end

    def model_class?(const_name) = file_text(@target.file).match?(/class\s+#{const_name.split("::").last}\s*<\s*(ApplicationRecord|ActiveRecord::Base)/)

    # param => [[attr, [bounds]]] for each `param.attr` the method calls,
    # with the integer literals and constants a comparison sets it against.
    def attribute_reads(node, params)
      reads = Hash.new { |h, k| h[k] = [] }
      walk(node) do |n|
        next unless n.is_a?(Prism::CallNode)

        if COMPARE.include?(n.name) && n.receiver && n.arguments&.arguments&.size == 1
          [[n.receiver, n.arguments.arguments.first], [n.arguments.arguments.first, n.receiver]].each do |side, other|
            next unless (pa = param_attr(side, params))

            bound = integer_of(other)
            reads[pa[0]] << [pa[1], bound ? [bound] : []]
          end
        elsif (pa = param_attr(n, params))
          reads[pa[0]] << [pa[1], []]
        end
      end
      reads.transform_values { |list| list.group_by(&:first).map { |attr, rows| [attr, rows.flat_map(&:last).uniq] } }
    end

    def param_attr(n, params)
      return ["self", n.name.to_s] if params.include?("self") && n.is_a?(Prism::CallNode) && (n.receiver.nil? || n.receiver.is_a?(Prism::SelfNode)) && n.arguments.nil?
      return nil unless n.is_a?(Prism::CallNode) && n.receiver.is_a?(Prism::LocalVariableReadNode) && params.include?(n.receiver.name.to_s)

      [n.receiver.name.to_s, n.name.to_s]
    end

    def integer_of(n)
      case n
      when Prism::IntegerNode then n.value
      when Prism::ConstantReadNode then constants[n.name.to_s]
      end
    end

    def literals(node)
      found = []
      walk(node) do |n|
        next unless n.is_a?(Prism::CallNode) && COMPARE.include?(n.name) && n.arguments&.arguments&.size == 1

        [n.receiver, n.arguments.arguments.first].each { (v = integer_of(_1)) && found << v }
      end
      found.uniq
    end

    def constants = @constants ||= file_text(@target.file).scan(/^\s*([A-Z][A-Z0-9_]*)\s*=\s*(-?\d+)\s*$/).to_h { [_1, _2.to_i] }

    def factories
      @factories ||= git_files(%r{\A(spec|test)/(factories|support)/.*\.rb\z|\A(spec|test)/factories\.rb\z})
                     .flat_map { file_text(_1).scan(/^\s*factory\s+:(\w+)/).flatten }.uniq
    end

    def columns_of(factory)
      table = factory.sub(/y\z/, "ie").sub(/(s|sh|ch|x)\z/, '\1e') + "s"
      block = file_text("db/schema.rb")[/create_table "#{table}".*?^  end/m].to_s
      block.scan(/t\.(\w+)\s+"(\w+)"/).to_h { [_2, _1] }
    end

    def git_files(pattern) = Change.git(@change.root, "ls-tree", "-r", "--name-only", @rev).lines.map(&:strip).grep(pattern)

    def file_text(path)
      return "" unless path

      @files ||= {}
      @files[path] ||= (Open3.capture2("git", "show", "#{@rev}:#{path}", chdir: @change.root).then { |out, st| st.success? ? out : "" })
    end
  end
end
