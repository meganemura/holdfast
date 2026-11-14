# rbs_inline: enabled

# Drafts sequence definitions for a Rails app: an action
# per write route, Grape endpoint and job, a pool per model they take, a world
# built from the factories, the fakes the specs install, and each fake's
# failure modes. A short random walk (the probe) records which tables each
# action writes and which fakes it calls; areas are grouped by it.
#
# The hunt stage runs it from the app root with the app's bundle:
#   ruby propose.rb --all [--force]   one file per write area in SEQUENCES_OUT, plus invariants.rb
#   ruby propose.rb AREA [AREA...]    one draft on stdout; an AREA is a regexp over paths and job names
ENV["RAILS_ENV"] = "test" # the probe needs the test database and the factories
$LOAD_PATH.unshift(File.expand_path("spec", Dir.pwd))
require "rspec/core"
require "rails_helper"
require_relative "sequences"
require "prism"

module Propose
  MAX_ACTIONS = 10 #: Integer
  FAILURE_NAME = /fail|time_?out|declin|refus|reject|unavailable|error/i #: Regexp

  Draft = Data.define(
    :name, #: Symbol
    :params, #: Hash[Symbol, untyped]
    :body, #: String
    :kind, #: Symbol
    :resource, #: String?
    :file #: String?
  )
  Failure = Data.define(
    :name, #: Symbol
    :code, #: String
    :service #: String
  )
  # One money rule (see money_rules). It sits above `module_function`
  # because rbs-inline reads that as applying to every method after it in
  # the file, this class's too.
  MoneyRule = Data.define(
    :model, #: untyped
    :amount, #: String
    :settled, #: Array[String]
    :assoc, #: untyped
    :child, #: untyped
    :paid, #: String
    :captured, #: Array[String]
    :kind #: String
  )
  # Reopened rather than given as a block: rbs-inline reads no methods
  # inside a `Data.define` block.
  class MoneyRule
    #: () -> String
    def name = "#{model.model_name.singular}_#{amount}_matches_#{assoc.name}_captured"
    #: () -> Symbol?
    def owner = child.reflect_on_all_associations(:belongs_to).find { it.foreign_key.to_s == assoc.foreign_key.to_s }&.name
  end

  # The models, routes, factories and source files this reads are the app's,
  # so their values are untyped.
  # @rbs!
  #   self.@models: Array[untyped]
  #   self.@lookup_columns: Hash[[String, Symbol], String]
  #   self.@param_lookups: Hash[Symbol, [untyped, String]]
  #   self.@owned_pools: Hash[Symbol, String]
  #   self.@drafts: Array[Draft]
  #   self.@controller_envs: Array[String]
  #   self.@api_auth: Hash[Symbol, untyped]
  #   self.@factories: Array[untyped]
  #   self.@grape_mounts: Hash[untyped, String]
  #   self.@fakes: Array[[String, String]]
  #   self.@http_services: Array[String]
  #   @grape_mounts: Hash[untyped, String]
  #   @fakes: Array[[String, String]]
  #   @http_services: Array[String]
  #   @models: Array[untyped]
  #   @lookup_columns: Hash[[String, Symbol], String]
  #   @param_lookups: Hash[Symbol, [untyped, String]]
  #   @owned_pools: Hash[Symbol, String]
  #   @drafts: Array[Draft]
  #   @controller_envs: Array[String]
  #   @api_auth: Hash[Symbol, untyped]
  #   @factories: Array[untyped]
  #   self.@failures: Array[Failure]
  #   @failures: Array[Failure]
  #   self.@controller_auth: Hash[untyped, { params: Hash[Symbol, String], headers: Hash[String, String] }]
  #   @controller_auth: Hash[untyped, { params: Hash[Symbol, String], headers: Hash[String, String] }]
  #   self.@session_sign_in: Hash[Symbol, untyped]?
  #   @session_sign_in: Hash[Symbol, untyped]?
  #   self.@app_text: String
  #   @app_text: String
  #   self.@static: Hash[String?, Array[String]]
  #   @static: Hash[String?, Array[String]]
  #   self.@money_rules: Array[MoneyRule]
  #   @money_rules: Array[MoneyRule]

  module_function

  # The model a param or path word names: `loan_id` is a Loan,
  # `pickup_branch_id` a Branch (by a belongs_to of that name), `request_id`
  # an InterlibraryRequest (the one model whose name ends in Request).
  #: (String | Symbol | nil word) -> untyped
  def model_for(word)
    stem = word.to_s.sub(/_id\z/, "")
    found = stem.classify.safe_constantize
    return found if found.is_a?(Class) && found < ActiveRecord::Base

    by_assoc = models.flat_map { it.reflect_on_all_associations(:belongs_to) }.find { it.name.to_s == stem && !it.polymorphic? }
    return by_assoc.klass if by_assoc

    suffix = models.select { it.name.underscore.end_with?("_#{stem}") }
    suffix.first if suffix.one?
  end

  #: (untyped model) -> Symbol
  def pool_name(model) = model.model_name.plural.to_sym

  # A string param named like an identifying column (a code, a barcode, an
  # ISBN) reads it from a record the world has: `barcode` from a Copy.
  # A status or a reason is free text instead: copying one from an unrelated
  # table draws from an empty pool.
  IDENTIFIER = /code|barcode|isbn|token|email|ref\z|reference\z/ #: Regexp
  #: (String | Symbol key, Array[untyped] models) -> [untyped, String]?
  def column_source(key, models)
    # A param named like a record (`branch`, `pickup_branch`) sends its identifying column.
    if (model = model_for(key)) && (column = model.columns.find { it.type == :string && it.name.match?(IDENTIFIER) })
      return [model, column.name]
    end
    # `carnet_code` sends a carnet's code.
    if (m = key.to_s.match(/\A(\w+?)_(\w+)\z/)) && m[2].match?(IDENTIFIER) && (model = model_for(m[1])) && model.columns_hash[m[2]]&.type == :string
      return [model, m[2]]
    end
    return unless key.to_s.match?(IDENTIFIER)

    seeded = models.sort_by { FactoryBot.factories.registered?(it.model_name.singular) ? 0 : 1 }
    seeded.each { |m| return [m, key.to_s] if m.column_names.include?(key.to_s) && m.columns_hash[key.to_s].type == :string }
    nil
  end

  # Guessed draws for an untyped numeric param, marked in the draft.
  PERCENTS = [0, 50, 100, 101, -1].freeze #: Array[Integer]
  COUNTS = { /minutes|duration/ => [0, 15, 30, 60, 120, 240, 600], /size|count|attendees|seats|quantity|number|days/ => [0, 1, 2, 4, 12, -1],
             /amount|price|total|fee|cost/ => ["0", "1", "12.50", "100", "-5", "0.01"] }.freeze #: Hash[Regexp, Array[Integer | String]]

  #: () -> Array[untyped]
  def models
    @models ||= ActiveRecord::Base.descendants.reject { it.abstract_class? || it.name.nil? }.select(&:table_exists?)
  end

  # What a controller action reads from params: key => [model, attribute],
  # [:date], [:nested, keys] for `require(:k).permit(...)`, [:upload], or [:value].
  #: (untyped controller, String | Symbol action) -> Hash[Symbol, Array[untyped]]
  def controller_params(controller, action)
    file = controller.instance_method(action).source_location&.first or return {}
    found = {} #: Hash[Symbol, Array[untyped]]
    nest = lambda do |key, attrs|
      found[key] = [:nested, ((found[key]&.first == :nested ? found[key].last : Array.new) + attrs).uniq]
    end #: ^(Symbol, Array[Symbol]) -> untyped
    # Prism nodes of any kind pass through, so the walk reads them untyped.
    walk = lambda do |node, stack|
      # Rails 8's `params.expect(membership: [:plan_id])` and
      # `params.dig(:membership, :starts_on)` read a nested form too.
      if node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :params && node.name == :expect
        Array(node.arguments&.arguments).grep(Prism::KeywordHashNode).flat_map(&:elements).each do |pair|
          next unless pair.key.is_a?(Prism::SymbolNode) && pair.value.is_a?(Prism::ArrayNode)

          nest.(pair.key.unescaped.to_sym, pair.value.elements.grep(Prism::SymbolNode).map { it.unescaped.to_sym })
        end
      elsif node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :params && node.name == :dig &&
            (keys = Array(node.arguments&.arguments)).size == 2 && keys.all?(Prism::SymbolNode)
        nest.(keys.first.unescaped.to_sym, [keys.last.unescaped.to_sym])
      elsif node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :params &&
         %i[require [] fetch].include?(node.name) && (first = node.arguments&.arguments&.first).is_a?(Prism::SymbolNode)
        key = first.unescaped.to_sym
        at = stack.rindex { it.is_a?(Prism::CallNode) && %i[find find_by find_by!].include?(it.name) && it.receiver.is_a?(Prism::ConstantReadNode) }
        pair = at && stack.drop(at).reverse.find { it.is_a?(Prism::AssocNode) }
        model = at && stack[at].receiver.name.to_s.safe_constantize
        dated = stack.last.is_a?(Prism::CallNode) && %i[to_date to_time].include?(stack.last.name)
        outer = (stack.last if stack.last.is_a?(Prism::CallNode) && stack.last.receiver.equal?(node)) #: untyped
        # `params.require(:tickets).map { it.permit(:kind, ...) }` is a list of forms.
        each_permit = if %i[map each filter_map flat_map].include?(outer&.name) && outer.block
                        found_permit = nil
                        todo = [outer.block]
                        while (n = todo.pop)
                          found_permit = n if n.is_a?(Prism::CallNode) && n.name == :permit && n.receiver
                          todo.concat(n.compact_child_nodes)
                        end
                        found_permit
                      end #: untyped
        found[key] ||= if outer&.name == :permit
                         [:nested, Array(outer.arguments&.arguments).grep(Prism::SymbolNode).map { it.unescaped.to_sym }]
                       elsif each_permit
                         [:nested_list, Array(each_permit.arguments&.arguments).grep(Prism::SymbolNode).map { it.unescaped.to_sym }]
                       elsif %i[read original_filename path].include?(outer&.name) then [:upload]
                       elsif model then [model, pair ? pair.key.unescaped.to_sym : :id]
                       elsif dated then [:date]
                       elsif model_for(key) then [model_for(key), :id]
                       else [:value]
                       end
      end
      node.compact_child_nodes.each { walk.(it, stack + [node]) }
    end #: ^(untyped, Array[untyped]) -> untyped
    tree = Prism.parse_file(file).value
    defn = tree.breadth_first_search { it.is_a?(Prism::DefNode) && it.name == action.to_sym }
    defn&.then { walk.(it, []) }
    # The usual `member_params` helper holds the form's keys, so a method of
    # the same file the action calls with no receiver is read too.
    if defn
      called = [] #: Array[Symbol]
      stack = [defn] #: Array[untyped]
      while (n = stack.pop)
        called << n.name if n.is_a?(Prism::CallNode) && n.receiver.nil? && n.arguments.nil?
        stack.concat(n.compact_child_nodes)
      end
      called.uniq.each do |name|
        next if name == action.to_sym

        tree.breadth_first_search { it.is_a?(Prism::DefNode) && it.name == name && it.receiver.nil? }&.then { walk.(it, []) }
      end
    end
    # `file = params[:file]` and then `file.read`: the local is the upload.
    if defn
      locals = {} #: Hash[Symbol, Symbol]
      seen = [] #: Array[untyped]
      stack = [defn] #: Array[untyped]
      while (n = stack.pop)
        seen << n
        stack.concat(n.compact_child_nodes)
      end
      seen.grep(Prism::LocalVariableWriteNode).each do |w|
        v = w.value
        next unless v.is_a?(Prism::CallNode) && v.receiver.is_a?(Prism::CallNode) && v.receiver.name == :params && (first = v.arguments&.arguments&.first).is_a?(Prism::SymbolNode)

        locals[w.name] = first.unescaped.to_sym
      end
      seen.grep(Prism::CallNode).each do |c|
        next unless %i[read original_filename path].include?(c.name) && c.receiver.is_a?(Prism::LocalVariableReadNode) && (key = locals[c.receiver.name])

        found[key] = [:upload]
      end
    end
    found
  end

  # Path segments become pool records: `/loans/:id/renew` takes a Loan. In a
  # nested path the parent is read from the child (`closure.branch_id`), so
  # the two always match.
  #: (String path, Hash[Symbol, untyped] params, ?lookups: Hash[Symbol, Array[untyped]]) -> String
  def path_params(path, params, lookups: {})
    resource = path.split("/").reject { it.empty? || it.start_with?(":") }
    segments = path.scan(/:(\w+)/).flatten.map do |key|
      key = key.to_sym
      [key, key == :id ? model_for(resource.reverse.find { model_for(it) }) : model_for(key)]
    end
    path.gsub(/:(\w+)/) do
      word = $1 #: String
      key = word.to_sym
      if (choices = lookups[key])
        # One file finds `:id` as a patient under /patients and as an
        # appointment under /appointments: the segment before the param says which.
        before = path[%r{([a-z_]+)/:#{key}\b}, 1]
        found = choices.find { it[0].table_name == before || pool_name(it[0]).to_s == before } || choices.first
        var = found[0].model_name.singular
        params[var.to_sym] = found[2] || pool_name(found[0])
        next "\#{#{var}.#{found[1]}}"
      end
      segment = segments.assoc(key) #: [Symbol, untyped]
      model = segment[1]
      child = segments.map(&:last).compact.find do |m|
        m != model && model && m.reflect_on_all_associations(:belongs_to).any? { !it.polymorphic? && it.klass == model }
      end
      if child
        fk = child.reflect_on_all_associations(:belongs_to).find { it.klass == model }.foreign_key
        "\#{#{child.model_name.singular}.#{fk}}"
      elsif model
        var = model.model_name.singular
        params[var.to_sym] = pool_name(model)
        "\#{#{var}.#{lookup_columns[[model.name, key]] || "id"}}"
      elsif (source = column_source(key, models))
        var = source[0].model_name.singular
        params[var.to_sym] = pool_name(source[0])
        "\#{#{var}.#{source[1]}}"
      else
        params[key] = :TODO
        "\#{#{key}}"
      end
    end
  end

  # A controller that finds a path's record by another column
  # (`Location.find_by!(code: params[:location_id])`) answers 404 to an id.
  # Keyed by model and param, from every controller.
  #: () -> Hash[[String, Symbol], String]
  def lookup_columns
    table = {} #: Hash[[String, Symbol], String]
    @lookup_columns ||= Dir[Rails.root.join("app/controllers/**/*.rb")].each_with_object(table) do |file, found|
      Prism.parse_file(file).value.breadth_first_search do |c|
        # @type var c: untyped
        next false unless c.is_a?(Prism::CallNode) && %i[find_by find_by!].include?(c.name) && c.receiver.is_a?(Prism::ConstantReadNode)

        hashes = c.arguments&.arguments&.grep(Prism::KeywordHashNode) #: Array[untyped]?
        hashes&.flat_map(&:elements)&.each do |pair|
          v = pair.value
          next unless pair.key.is_a?(Prism::SymbolNode) && v.is_a?(Prism::CallNode) && v.name == :[] &&
                      v.receiver.is_a?(Prism::CallNode) && v.receiver.name == :params && (first = v.arguments&.arguments&.first).is_a?(Prism::SymbolNode)

          found[[c.receiver.name.to_s, first.unescaped.to_sym]] ||= pair.key.unescaped
        end
        false
      end
    end
  end

  # A body param a controller finds a record by
  # (`Member.find_by!(email: params.expect(guest: [:host_email])[:host_email])`)
  # is drawn from that record: free text names no member.
  #: () -> Hash[Symbol, [untyped, String]]
  def param_lookups
    table = {} #: Hash[Symbol, [untyped, String]]
    @param_lookups ||= Dir[Rails.root.join("app/{controllers,api}/**/*.rb")].each_with_object(table) do |file, found|
      Prism.parse_file(file).value.breadth_first_search do |c|
        # @type var c: untyped
        next false unless c.is_a?(Prism::CallNode) && %i[find_by find_by!].include?(c.name)

        # A scope may stand between: `Service.online.find_by!(code: ...)`.
        root = c.receiver
        root = root.receiver while root.is_a?(Prism::CallNode) && root.receiver
        next false unless root.is_a?(Prism::ConstantReadNode)

        hashes = c.arguments&.arguments&.grep(Prism::KeywordHashNode) #: Array[untyped]?
        hashes&.flat_map(&:elements)&.each do |pair|
          next unless pair.key.is_a?(Prism::SymbolNode) && pair.value.slice.include?("params")

          key = pair.value.slice.scan(/\[:(\w+)\]/).flatten.last or next
          model = root.name.to_s.safe_constantize
          found[key.to_sym] ||= [model, pair.key.unescaped] if model.is_a?(Class) && model < ActiveRecord::Base
        end
        false
      end
    end
  end

  # How an endpoint file finds a path's record: `Invoice.find(params[:id])`,
  # `current_member.invoices.find_by!(number: params[:number])`. Grape names
  # `/guests/:id` after the URL, not the model it finds.
  #: (String? file) -> Hash[Symbol, Array[untyped]]
  def endpoint_lookups(file)
    return {} unless file && File.file?(file)

    text = File.read(file)
    found = [] #: Array[[String, String, String, String?]]
    text.scan(/(?:(current_\w+)\.)?([A-Za-z_]\w*)(?:\([^)]*\))?(?:\.\w+)*?(?:\.where\([^)]*\))?\.find_by!?\((\w+):\s*params\[:(\w+)\]\)/) { |owner, word, col, key| found << [key, word, col, owner] }
    text.scan(/(?:(current_\w+)\.)?([A-Za-z_]\w*)\.find\(params\[:(\w+)\]\)/) { |owner, word, key| found << [key, word, "id", owner] }
    found.filter_map do |key, word, col, owner|
      model = word.match?(/\A[A-Z]/) ? word.safe_constantize : model_for(word.singularize) #: untyped
      next unless model.is_a?(Class) && model < ActiveRecord::Base && model.column_names.include?(col)

      # `current_patient.appointments.find(params[:id])` finds only the
      # caller's own records: any other answers 404.
      row = [key.to_sym, [model, col, (owned_pool(owner, word, model) if owner)]] #: [Symbol, Array[untyped]]
      row
    end.group_by(&:first).transform_values { it.map(&:last).uniq }
  end

  # A pool of the API caller's own records, named `<table>_of_caller`, with
  # the expression that finds them.
  #: (String owner, String assoc, untyped model) -> Symbol?
  def owned_pool(owner, assoc, model)
    caller = model_for(owner.delete_prefix("current_")) or return
    made = api_own_records.find { |_, line, _| line.start_with?("create(:#{factories.find { it.build_class == caller }&.name},") } or return
    finder = "#{caller}.find_by(#{made[1][/(\w+: "#{made[2]}")\)\z/, 1]})"
    name = :"#{pool_name(model)}_of_caller"
    owned_pools[name] = "#{finder}.#{assoc}"
    name
  end

  #: () -> Hash[Symbol, String]
  def owned_pools = @owned_pools ||= {}

  # The table a pool draws from: `appointments_of_caller` draws appointments.
  #: (Symbol | String pool) -> String
  def pool_table(pool) = pool.to_s.delete_suffix("_of_caller")

  # The values a model's `inclusion: { in: [...] }` accepts for a column of
  # this name, when every model that validates it accepts the same list.
  #: (String | Symbol key) -> Array[String | Integer]?
  def inclusion_values(key)
    lists = models.filter_map do |m|
      v = m.validators_on(key.to_sym).grep(ActiveModel::Validations::InclusionValidator).first or next
      list = v.options[:in] || v.options[:within]
      list = list.to_a if list.is_a?(Range) && list.size.to_i <= 20
      list if list.is_a?(Array) && !list.empty? && list.all? { it.is_a?(String) || it.is_a?(Integer) }
    end.uniq
    lists.first if lists.size == 1
  end

  # One body entry for a param: the value expression, with its spec added to
  # +params+.
  #: (String | Symbol key, String? type, Hash[Symbol, untyped] params) -> String
  def value_for(key, type, params)
    key = key.to_s
    if !key.end_with?("_id") && (found = param_lookups[key.to_sym]) && found[1] != key
      var = :"#{key}_from"
      params[var] = pool_name(found[0])
      "#{key}: #{var}.#{found[1]}"
    elsif key.end_with?("_id") && (model = model_for(key))
      var = model.model_name.singular.to_sym
      var = key.delete_suffix("_id").to_sym if params.key?(var) && params[var] != pool_name(model)
      params[var] = pool_name(model)
      "#{key}: #{var}.id"
    elsif type == "Date" || key.end_with?("_on") || %w[on date day].include?(key)
      var = key.end_with?("_on") ? key : "#{key}_on"
      params[var.to_sym] = :local_date
      "#{key}: #{var}.iso8601"
    elsif %w[Time DateTime].include?(type) || key.end_with?("_at")
      var = key.end_with?("_at") ? key : "#{key}_at"
      params[var.to_sym] = :local_time
      "#{key}: #{var}.iso8601"
    elsif type == "Integer"
      params[key.to_sym] = 0..5
      "#{key}:"
    elsif %w[BigDecimal Float Numeric].include?(type) && COUNTS.none? { |pattern, _| key.match?(pattern) }
      params[key.to_sym] = ["0", "1", "12.5", "-1"]
      "#{key}:"
    elsif key.end_with?("_ids") && (model = model_for(key.delete_suffix("_ids")))
      # A list of ids sends one record's id: text there is refused or finds nothing.
      var = model.model_name.singular.to_sym
      params[var] = pool_name(model)
      "#{key}: [#{var}.id]"
    elsif type&.start_with?("Array") || type&.match?(/\A\[\w+\]\z/)
      # `Array[String]` refuses a bare word and an empty list alike.
      params[key.to_sym] = :text
      "#{key}: [#{key}]"
    elsif type == "Hash"
      # A Hash with no declared keys refuses text; empty is the one safe draw.
      "#{key}: {}"
    elsif %w[Boolean Grape::API::Boolean].include?(type)
      params[key.to_sym] = 0..1
      "#{key}: #{key} == 1"
    elsif (source = column_source(key, models))
      var = :"#{key}_from"
      params[var] = pool_name(source[0])
      "#{key}: #{var}.#{source[1]}"
    elsif (listed = inclusion_values(key))
      params[key.to_sym] = listed + [listed.first.is_a?(String) ? "holdfast text" : -1]
      "#{key}:"
    elsif (counts = COUNTS.find { |pattern, _| key.match?(pattern) }&.last)
      params[key.to_sym] = counts
      "#{key}:"
    else
      params[key.to_sym] = :text
      "#{key}:"
    end
  end

  # A form field of a model's column is drawn by the column's type: text in
  # an integer capacity or a time zone refused every draw. A string the
  # model refuses as free text (a known time zone, a code format) is drawn
  # from the factory's value, free text and blank.
  COLUMN_TYPES = { integer: "Integer", boolean: "Boolean", date: "Date", datetime: "Time", decimal: "BigDecimal", float: "Float" }.freeze #: Hash[Symbol, String]
  #: (untyped model, String | Symbol key, Hash[Symbol, untyped] params) -> String
  def form_value(model, key, params)
    col = model&.columns_hash&.[](key.to_s)
    # A unique column drawn from records already there collides every time:
    # the factory makes a new value per call.
    factory = factories.find { it.build_class == model } if col
    if factory && model.validators_on(key.to_sym).grep(ActiveRecord::Validations::UniquenessValidator).any? &&
       (FactoryBot.attributes_for(factory.name)[key.to_sym] rescue nil).is_a?(String)
      return "#{key}: FactoryBot.attributes_for(:#{factory.name})[:#{key}]"
    end
    foreign = model&.reflect_on_all_associations(:belongs_to)&.any? { it.foreign_key.to_s == key.to_s }
    return value_for(key, nil, params) if foreign
    # A percentage is drawn at and past its ends: 0..5 never asks whether
    # 101 percent off is refused.
    if col && %i[integer decimal float].include?(col.type) && key.to_s.include?("percent")
      params[key.to_sym] = PERCENTS
      return "#{key}:"
    end
    if col&.type == :integer && col.null
      params[key.to_sym] = [nil, 0, 1, 2, 5]
      return "#{key}:"
    end
    return value_for(key, COLUMN_TYPES[col&.type], params) unless col && %i[string text].include?(col.type) && !column_source(key.to_s, models)

    fixed = factory_value(model, key.to_s) or return value_for(key, nil, params)
    params[key.to_sym] = [fixed, "holdfast text", ""]
    "#{key}:"
  end

  #: (untyped model, String key) -> String?
  def factory_value(model, key)
    factory = factories.find { it.build_class == model } or return nil
    record = FactoryBot.build(factory.name)
    value = record[key]
    return nil unless value.is_a?(String) && record.valid?

    record[key] = "holdfast text"
    record.valid?
    value if record.errors[key.to_sym].any?
  rescue StandardError
    nil
  end

  # An end time drawn apart from its start broke a duration rule at nearly
  # every draw; draw it as minutes after the start instead.
  DURATIONS = [30, 60, 90, 120, 180, 15, 0, -30, 240, 600].freeze #: Array[Integer]
  #: (Hash[Symbol, untyped] params) -> Hash[Symbol, untyped]
  def pair_ends!(params)
    params.keys.each do |key|
      stem = key.to_s[/\A(.*?)(ends?|finish(?:es)?|until|to)_at\z/, 1] or next
      start = params.keys.find { it.to_s.match?(/\A#{Regexp.escape(stem)}(starts?|begins?|from)_at\z/) } or next
      params[key] = Sequences::After.new(from: start, minutes: DURATIONS) if params[start] == :local_time && params[key] == :local_time
    end
    params
  end

  #: (Hash[Symbol, untyped] params, String call) -> String
  def block_for(params, call)
    params.empty? ? "{ #{call} }" : "{ |#{params.keys.map { "#{it}:" }.join(", ")}| #{call} }"
  end

  #: () -> Array[Draft]
  def route_drafts
    Rails.application.routes.routes.filter_map do |route|
      verb = route.verb
      path = route.path.spec.to_s.sub("(.:format)", "")
      next if verb.empty? || verb == "GET" || route.defaults[:controller].nil?

      controller = "#{route.defaults[:controller].camelize}Controller".safe_constantize or next
      action = route.defaults[:action]
      params = {} #: Hash[Symbol, untyped]
      url = path_params(path, params)
      segments = path.scan(/:(\w+)/).flatten.map(&:to_sym)
      auth = controller_auth(controller)
      body = controller_params(controller, action).filter_map do |key, (kind, attribute)|
        next if segments.include?(key)
        next "#{key}: ENV[#{auth[:params][key].inspect}]" if auth[:params][key]

        if kind == :nested
          form = model_for(key)
          "#{key}: { #{attribute.map { form_value(form, it, params) }.join(", ")} }"
        elsif kind == :nested_list
          form = model_for(key)
          "#{key}: [{ #{attribute.map { form_value(form, it, params) }.join(", ")} }]"
        elsif kind == :upload
          # Drawn text sent as a file, so the action runs past its upload.
          params[key] = :text
          %(#{key}: Rack::Test::UploadedFile.new(StringIO.new(#{key}.to_s), "text/plain", original_filename: "#{key}.txt"))
        elsif kind.is_a?(Class)
          model = kind #: untyped
          var = model.model_name.singular.to_sym
          var = key.to_s.delete_suffix("_id").to_sym if params.key?(var)
          params[var] = pool_name(model)
          "#{key}: #{var}.#{attribute}"
        else
          value_for(key, kind == :date ? "Date" : nil, params)
        end
      end
      # The sign-in action itself sends the known credentials.
      sign_in = session_sign_in
      body = sign_in[:body] if sign_in && route.defaults[:controller] == sign_in[:controller] && action == sign_in[:action]
      pair_ends!(params)
      headers = auth[:headers].map { |h, expr| "#{h.inspect} => #{expr}" }
      call = %(http.#{verb.downcase} "#{url}"#{", params: { #{body.join(", ")} }" unless body.empty?}#{", headers: { #{headers.join(", ")} }" unless headers.empty?})
      call = "desk_sign_in; #{call}" if sign_in && (session_reader?(controller) && route.defaults[:controller] != sign_in[:controller])
      Draft.new(name: :"#{route.defaults[:controller].tr("/", "_")}_#{action}", params:, body: block_for(params, call),
                kind: :route, resource: route.defaults[:controller].tr("/", "_"), file: "#{controller.instance_method(action).source_location&.first}##{action}")
    end
  end

  #: () -> Array[Draft]
  def api_drafts
    return [] unless defined?(Grape::API)

    Grape::API.descendants.select { it.respond_to?(:routes) }.flat_map { |api| api.routes.map { [api, it] } }.uniq { |_, r| [r.request_method, r.path] }.filter_map do |api, route|
      next if route.request_method == "GET"

      # An API the app mounts under a prefix (`mount DeskAPI => "/v1"`) answers
      # only under it; Grape's own path leaves the prefix out.
      path = grape_mounts.fetch(api, "") + route.path.sub("(.json)", "").sub(":version", route.version.to_s)
      # A mounted API lists its routes once more without the root's prefix.
      next if path.include?("(")

      params = {} #: Hash[Symbol, untyped]
      url = path_params(path, params, lookups: endpoint_lookups(route.app.source&.source_location&.first))
      # Grape lists a nested param as "lines[sku]" beside "lines"; the draft
      # sends the parent as one Hash (an Array of one Hash when its type is
      # Array), each child drawn under a name of its own.
      top = route.params.reject { |k, _| path.include?(":#{k}") || k.to_s.include?("[") }
      children = route.params.select { |k, _| k.to_s.include?("[") }.group_by { |k, _| k.to_s[/\A[^\[]+/] }
      body = top.map do |key, spec|
        kids = children.delete(key.to_s)
        unless kids
          expr = grape_value(key, spec, params)
          next expr unless spec.is_a?(Hash) && spec[:required] == false

          # An optional param is sent or left out: a code drawn from any
          # record is refused whenever it is sent, and leaving it out is
          # the call most clients make.
          params[:"#{key}_sent"] = 0..1
          value = expr.sub(/\A#{key}:\s*/, "")
          next "**(#{key}_sent == 1 ? { #{key}: #{value.empty? ? key : value} } : {})"
        end

        inner = kids.filter_map do |k, s|
          leaf = k.to_s[/\[([^\[\]]+)\]\z/, 1] or next
          next if k.to_s.count("[") > 1
          if s.is_a?(Hash) && s[:values].is_a?(Array)
            next "#{leaf}: #{grape_value("#{key}_#{leaf}", s, params).sub(/\A#{key}_#{leaf}:\s*/, "").then { it.empty? ? "#{key}_#{leaf}" : it }}"
          end

          # A child that is a column of the parent's model is drawn as the
          # desk form draws it: `kind` from the values the model accepts.
          form = model_for(key.to_s)
          if form&.columns_hash&.key?(leaf)
            drawn = {} #: Hash[Symbol, untyped]
            expr = form_value(form, leaf, drawn).sub(/\A#{leaf}:\s*/, "")
            if expr.empty?
              params[:"#{key}_#{leaf}"] = drawn.delete(leaf.to_sym)
              expr = "#{key}_#{leaf}"
            end
            params.merge!(drawn)
            next "#{leaf}: #{expr}"
          end
          expr = value_for("#{key}_#{leaf}", s.is_a?(Hash) ? s[:type].to_s : nil, params).sub(/\A#{key}_#{leaf}:\s*/, "")
          "#{leaf}: #{expr.empty? ? "#{key}_#{leaf}" : expr}"
        end
        hash = "{ #{inner.join(", ")} }"
        "#{key}: #{spec.is_a?(Hash) && spec[:type].to_s.start_with?("Array") ? "[#{hash}]" : hash}"
      end
      children.each_key do |orphan|
        params[orphan.to_sym] = :TODO
        body << "#{orphan}:"
      end
      params[:caller] = pool_name(api_caller_model) if api_caller_model
      pair_ends!(params)
      rest = path.sub(%r{\A/api/v\d+/}, "")
      name = :"api_#{route.request_method.downcase}_#{rest.gsub(/[^a-z]+/, "_").delete_suffix("_")}"
      call = %(http.#{route.request_method.downcase} "#{url}"#{", params: { #{body.join(", ")} }" unless body.empty?}, headers: auth_for(#{"caller" if api_caller_model}))
      words = rest.split("/").reject { it.start_with?(":") }.slice_after { model_for(it.singularize) }.first #: Array[String]
      Draft.new(name:, params:, body: block_for(params, call), kind: :api, resource: "api_#{words.join("_")}",
                file: route.app.source&.source_location&.first)
    end
  end

  # A Grape param with `values: [...]` draws each listed value and one it
  # refuses; any other param is drawn by its type.
  #: (String | Symbol key, untyped spec, Hash[Symbol, untyped] params) -> String
  def grape_value(key, spec, params)
    values = spec[:values] if spec.is_a?(Hash)
    return value_for(key, spec.is_a?(Hash) ? spec[:type].to_s : nil, params) unless values.is_a?(Array) && values.all? { it.is_a?(String) || it.is_a?(Integer) }

    params[key.to_sym] = values + [values.first.is_a?(String) ? "holdfast text" : -1]
    "#{key}:"
  end

  #: () -> Hash[untyped, String]
  def grape_mounts
    table = {} #: Hash[untyped, String]
    @grape_mounts ||= Rails.application.routes.routes.each_with_object(table) do |r, out|
      app = r.app.respond_to?(:app) ? r.app.app : r.app
      next unless app.is_a?(Class) && app < Grape::API

      out[app] = r.path.spec.to_s.sub(/\(.*\)\z/, "").delete_suffix("/")
    end
  end

  #: () -> Array[Draft]
  def job_drafts
    ActiveJob::Base.descendants.filter_map do |job|
      next if job.name.nil? || job.name == "ApplicationJob"
      # Rails' own jobs (ActionMailer::MailDeliveryJob, Active Storage's)
      # take framework arguments no pool can draw.
      next unless job.instance_method(:perform).source_location&.first.to_s.start_with?(Rails.root.join("app").to_s)

      required = job.instance_method(:perform).parameters.select { it.first == :req }.map(&:last)
      params = {} #: Hash[Symbol, untyped]
      args = required.map do |arg|
        if arg.to_s.match?(/\A(on|date|day)\z|_(on|date)\z/)
          params[arg] = :local_date
          next arg.to_s
        elsif arg.to_s.match?(/\A(at|time|now)\z|_at\z/)
          params[arg] = :local_time
          next arg.to_s
        end
        if (model = model_for(arg))
          var = model.model_name.singular.to_sym
          params[var] = pool_name(model)
          arg.to_s.end_with?("_id") ? "#{var}.id" : var.to_s
        else
          value_for(arg, nil, params).sub(/\A#{arg}: ?/, "").then { it.empty? ? arg.to_s : it }
        end
      end
      Draft.new(name: job.name.underscore.to_sym, params:, body: block_for(params, "#{job.name}.perform_now(#{args.join(", ")})"),
                kind: :job, resource: nil, file: job.instance_method(:perform).source_location&.first)
    end
  end

  #: () -> Array[Draft]
  def drafts = @drafts ||= route_drafts + api_drafts + job_drafts

  # The fakes the specs install, as [client setter, fake class].
  #: () -> Array[[String, String]]
  def fakes
    @fakes ||= Rails.root.glob("spec/support/**/*.rb").flat_map do |file|
      File.read(file).scan(/^\s*config\.before.*?(\w+(?:::\w+)*)\.client\s*=\s*(Fake\w+)\.new/m)
    end.uniq
  end

  # App modules that talk HTTP themselves (`Net::HTTP.start` inside
  # `LockerApi.register`) rather than through a `.client` a spec replaces:
  # the hunt refuses their real calls, so a person writes the fake.
  #: () -> Array[String]
  def http_services
    @http_services ||= (Rails.root.glob("app/**/*.rb") + Rails.root.glob("lib/**/*.rb")).filter_map do |file|
      text = File.read(file)
      next unless text.match?(/\bNet::HTTP\b|\bFaraday\b|\bHTTParty\b|\bHTTP\.(get|post|put|patch|delete)\b/)

      text[/^\s*(?:module|class)\s+([A-Z][\w:]*)/, 1]
    end.uniq
  end

  #: (Array[Draft] selected) -> Array[String]
  def network_note(selected)
    names = selected.map { it.name.to_s }
    seen = Sequences.network_calls.select { |_, actions| (actions & names).any? }.keys
    services = http_services.select { |service| selected.any? { static_constants(it.file).include?(service) } }
    return [] if seen.empty? && services.empty?

    ["TODO: #{services.any? ? services.join(", ") : "an action here"} calls a real host#{" (#{seen.join(", ")} in the probe)" if seen.any?}; the hunt refuses real network calls.",
     "Replace its methods with a fake before setup, list the fake in outside_calls, and arm its failures (see the skill)."]
  end

  # Methods a fake has and the real client does not, named like a failure:
  # each becomes a `failure`. One with a required argument needs a person
  # to say which record it fails for.
  #: () -> Array[Failure]
  def failures
    @failures ||= fakes.flat_map do |service, fake_name|
      fake = fake_name.constantize #: untyped
      real = "#{service}::Client".safe_constantize #: untyped
      (fake.public_instance_methods(false) - (real ? real.public_instance_methods : Array.new)).grep(FAILURE_NAME).map do |method|
        # The probe prepends a pause hook; read the fake's own signature under it.
        original = fake.instance_method(method)
        original = original.super_method while original.owner != fake
        required = original.parameters.select { it.first == :req }.map(&:last)
        name = :"#{service.underscore}_#{method}"
        code = required.empty? ? "failure(:#{name}) { #{service}.client.#{method} }" :
                                 "# TODO: failure(:#{name}) { #{service}.client.#{method}(#{required.join(", ")}) } # which #{required.join(", ")}?"
        Failure.new(name:, code:, service: fake_name)
      end
    end
  end

  # How an API caller signs in: a header looked up as a record's column, or
  # compared with an ENV value the setup sets.
  # Each lookup is [header, model, column, literal conditions, bearer]: a
  # header read straight into find_by, or first into a local (`token =
  # headers["Authorization"].delete_prefix("Bearer ")`), with the record's
  # other conditions (`kind: "staff"`). A lookup with conditions or a bearer
  # prefix gets a record of its own in the setup, with a known token.
  #: () -> Hash[Symbol, untyped]
  def api_auth
    @api_auth ||= begin
      text = Rails.root.glob("app/api/**/*.rb").map { File.read(it) }.join("\n")
      chunks = text.split(/^\s*def /)
      # A helper that reads the header (`def bearer_token = headers["Authorization"]...`)
      # stands for it where a lookup calls the helper.
      readers = chunks.filter_map { |c| (h = c[/headers\["([^"]+)"\]/, 1]) && [c[/\A(\w+)/, 1], [h, c.include?("Bearer")]] }.to_h
      lookups = chunks.flat_map do |chunk|
        locals = chunk.scan(/^\s*(\w+)\s*=\s*[^=\n]*headers\["([^"]+)"\]/).to_h
        bearer = chunk.include?("Bearer")
        # A scope may stand between the model and the lookup (`StaffMember.active.find_by`).
        chunk.scan(/([A-Z]\w*)((?:\.\w+(?:\([^)]*\))?)*?)\.find_by!?\(([^)]*)\)/).filter_map do |model, chain, args|
          where = chain[/\.where\(([^)]*)\)/, 1]
          pairs = "#{where}, #{args}".scan(/(\w+):\s*([^,]+)/)
          header, column = pairs.filter_map { |col, expr| (h = expr[/headers\["([^"]+)"\]/, 1] || locals[expr.strip] || readers[expr.strip[/\A(\w+)/, 1]]&.first) && [h, col] }.first
          next unless header

          bearer ||= readers.values.include?([header, true])

          literal = pairs.select { |_, expr| expr.strip.match?(/\A("[^"]*"|\d+)\z/) }.to_h { |k, v| [k, v.strip] }
          [header, model.safe_constantize, column, literal, bearer]
        end
      end
      envs = chunks.flat_map do |chunk|
        env = chunk[/ENV\.fetch\("(\w+)"/, 1] or next []
        chunk.scan(/headers\["([^"]+)"\]/).flatten.map { [it, env, chunk.include?("Bearer")] }
      end
      plain, own = lookups.select { it[1] }.uniq.partition { it[3].empty? && !it[4] }
      { lookups: plain + own, envs: envs.uniq }
    end
  end

  #: () -> untyped
  def api_caller_model = api_auth[:lookups].find { it[3].empty? && !it[4] }&.dig(1)

  # The record a bearer or conditioned lookup finds, made in the setup.
  #: () -> Array[[String, String, String]]
  def api_own_records
    api_auth[:lookups].reject { it[3].empty? && !it[4] }.filter_map do |header, model, column, literal, _|
      factory = factories.find { it.build_class == model } or next
      token = "sequences-#{header.downcase.gsub(/[^a-z]+/, "-")}"
      [header, "create(:#{factory.name}, #{[*role_traits(factory), *literal.map { "#{_1}: #{_2}" }, "#{column}: #{token.inspect}"].join(", ")})", token]
    end
  end

  # How a controller lets a caller in, read from its own source and its app
  # ancestors': HTTP Basic or token auth whose secrets come from ENV or a
  # literal, a param or a header compared with an ENV value. Each ENV name
  # is set by every area's setup (controller_envs), so the draft sends the
  # value the app expects instead of a drawn word it always refuses.
  ENV_READ = /ENV(?:\.fetch\(|\[)\s*["'](\w+)["']/ #: Regexp
  #: (untyped controller) -> { params: Hash[Symbol, String], headers: Hash[String, String] }
  def controller_auth(controller)
    @controller_auth ||= Hash.new
    @controller_auth[controller] ||= begin
      files = controller.ancestors.grep(Class).filter_map { Object.const_source_location(it.name)&.first if it.name }
                        .select { it.to_s.start_with?(Rails.root.join("app/controllers").to_s) }.uniq
      text = files.map { File.read(it) }.join("\n")
      secret = ->(src) { (env = src[ENV_READ, 1]) ? (controller_envs << env; "ENV[#{env.inspect}]") : src[/["'][^"']*["']/] }
      out = { params: {}, headers: {} } #: { params: Hash[Symbol, String], headers: Hash[String, String] }
      if (m = text.match(/http_basic_authenticate_with\s+name:\s*([^,]+),\s*password:\s*([^,\n]+)/))
        out[:headers]["Authorization"] = "ActionController::HttpAuthentication::Basic.encode_credentials(#{secret.(m[1])}, #{secret.(m[2])})"
      end
      text.split(/^\s*def /).each do |chunk|
        envs = chunk.scan(ENV_READ).flatten
        next if envs.empty?

        if chunk.match?(/(authenticate_or_request_with|authenticate_with)_http_basic/) && envs.size >= 2
          controller_envs.concat(envs.first(2))
          out[:headers]["Authorization"] = "ActionController::HttpAuthentication::Basic.encode_credentials(ENV[#{envs[0].inspect}], ENV[#{envs[1].inspect}])"
        elsif chunk.match?(/(authenticate_or_request_with|authenticate_with)_http_token/)
          controller_envs << envs.first
          out[:headers]["Authorization"] = "ActionController::HttpAuthentication::Token.encode_credentials(ENV[#{envs.first.inspect}])"
        end
        compared = chunk.lines.grep(/secure_compare|==/).join
        compared.scan(/params(?:\[:|\.(?:require|fetch)\(:)(\w+)/).flatten.each { |k| controller_envs << envs.first; out[:params][k.to_sym] = envs.first }
        compared.scan(/request\.headers\[["']([^"']+)["']\]/).flatten.each { |h| controller_envs << envs.first; out[:headers][h] = "ENV[#{envs.first.inspect}]" }
      end
      out
    end
  end

  #: () -> Array[String]
  def controller_envs = @controller_envs ||= []

  # A desk page that answers "Sign in first" unless the session holds a
  # staff id: the action that writes that session key (sessions#create) is
  # the sign-in, its params are drafted like any route's, and a record it
  # looks up by literal conditions (`kind: "staff"`) is made in the setup.
  # Every route of a controller whose before_action reads the key signs in
  # first, through one helper.
  #: (String text) -> String?
  def session_key(text) = text[/session\[:(\w+)\]/, 1]

  #: (untyped controller) -> bool
  def session_reader?(controller)
    controller._process_action_callbacks.any? do |cb|
      next false unless cb.kind == :before && cb.filter.is_a?(Symbol) && (controller.method_defined?(cb.filter) || controller.private_method_defined?(cb.filter))

      key = session_key(reads_through(controller, cb.filter))
      sign_in = session_sign_in
      key && sign_in && key == sign_in[:key]
    end
  rescue NameError
    false
  end

  # A method's body and the bodies of the controller methods it calls, one
  # call deep: `require_staff` reads the session through `current_staff`.
  #: (untyped controller, String | Symbol name, ?Integer depth) -> String
  def reads_through(controller, name, depth = 1)
    loc = controller.instance_method(name).source_location or return ""
    body = Prism.parse_file(loc[0]).value.breadth_first_search { it.is_a?(Prism::DefNode) && it.name == name.to_sym && it.location.start_line == loc[1] }&.slice.to_s
    return body if depth.zero?

    called = body.scan(/\b([a-z_]\w*[?!]?)/).flatten.uniq.select { |m| m != name.to_s && (controller.method_defined?(m) || controller.private_method_defined?(m)) }
    called.reject { |m| controller.instance_method(m).source_location.nil? || !controller.instance_method(m).source_location[0].start_with?(Rails.root.to_s) }
          .map { reads_through(controller, it, depth - 1) }.unshift(body).join("\n")
  rescue NameError
    ""
  end

  # Desk staff that sign in with a password: the setup makes the record with
  # a known one, and the sign-in sends it.
  DESK_PASSWORD = "sequences-password" #: String

  #: () -> Hash[Symbol, untyped]?
  def session_sign_in
    return @session_sign_in if defined?(@session_sign_in)

    @session_sign_in = Rails.application.routes.routes.lazy.filter_map do |route|
      next unless route.verb == "POST" && route.defaults[:controller]

      controller = "#{route.defaults[:controller].camelize}Controller".safe_constantize or next
      action = route.defaults[:action]
      loc = controller.instance_method(action).source_location rescue next
      tree = Prism.parse_file(loc[0]).value.breadth_first_search { it.is_a?(Prism::DefNode) && it.name.to_s == action } or next
      # The action writes the key itself, or through a helper (`sign_in(staff)`).
      text = reads_through(controller, action)
      key = text[/session\[:(\w+)\]\s*=[^=]/, 1] or next
      # A scope may stand between the model and the lookup (`StaffMember.active.find_by`).
      line = text.lines.find { it.match?(/[A-Z]\w*(?:\.\w+(?:\([^)]*\))?)*?\.find_by!?\(/) }
      named = line && line[/([A-Z]\w*)(?:\.\w+(?:\([^)]*\))?)*?\.find_by/, 1]
      model = named&.safe_constantize
      literal = line ? line.scan(/(\w+):\s*("[^"]*"|\d+)/).to_h : Hash.new #: Hash[String, String]
      # A param a lookup column reads (`email: params[:email]`) gets a known
      # value the setup gives the record too.
      by_param = line ? line.scan(/(\w+):\s*params(?:\[:|\.(?:require|fetch)\(:)(\w+)/).to_h { |col, k| [k.to_sym, col] } : Hash.new #: Hash[Symbol, String]
      # The secret is checked by `authenticate(params[:password])` or by a
      # predicate of the record's own (`staff.pin_matches?(params[:pin])`);
      # the setup gives the record that secret through its writer.
      password = text[/authenticate\(params(?:\[:|\.(?:require|fetch)\(:)(\w+)/, 1]&.to_sym
      secret = password ? :password : (password = text[/\.\w+\?\(params(?:\[:|\.(?:require|fetch)\(:)(\w+)/, 1]&.to_sym)
      password = nil unless model&.method_defined?(:"#{secret}=")
      known = by_param.to_h { |k, col| [k, col.include?("email") ? "desk@sequences.test" : "sequences-#{col.tr("_", "-")}"] }
      auth = controller_auth(controller)
      found = model ? model.where(literal.transform_values { it.delete('"') }) : nil #: untyped
      keys = controller_params(controller, action).keys | known.keys | [password].compact
      body = keys.map do |k|
        kind, attribute = controller_params(controller, action)[k]
        if auth[:params][k] then "#{k}: ENV[#{auth[:params][k].inspect}]"
        elsif known[k] then "#{k}: #{known[k].inspect}"
        elsif k == password then "#{k}: #{DESK_PASSWORD.inspect}"
        elsif kind.is_a?(Class) then "#{k}: #{kind.name}.where(#{literal.map { "#{_1}: #{_2}" }.join(", ")}).order(:id).first&.#{attribute}.to_s"
        else "#{k}: \"\""
        end
      end
      factory = model && factories.find { it.build_class == model && it.name.to_s == model.model_name.singular }
      attrs = literal.map { "#{_1}: #{_2}" } + by_param.map { |k, col| "#{col}: #{known[k].inspect}" } + (password ? ["#{secret}: #{DESK_PASSWORD.inspect}"] : [])
      setup = factory && attrs.any? ? "create(:#{factory.name}, #{[*role_traits(factory), *attrs].join(", ")})" : nil
      { key:, action:, controller: route.defaults[:controller], path: route.path.spec.to_s.sub("(.:format)", ""), body:, setup:, found: found&.to_sql }
    end.first
  end

  #: () -> Array[untyped]
  def factories
    @factories ||= FactoryBot.factories.to_a
  end

  # The traits that give a signed-in record a role the app checks
  # (`trait :supervisor` with `current_staff.supervisor?` in a guard), so the
  # caller reaches every action instead of only the ones open to all.
  #: (untyped factory) -> Array[String]
  def role_traits(factory)
    @app_text ||= Dir[Rails.root.join("app/{controllers,api}/**/*.rb")].map { File.read(it) }.join("\n")
    factory.defined_traits.map(&:name).select do |t|
      factory.build_class.method_defined?(:"#{t}?") && @app_text.match?(/\.#{Regexp.escape(t)}\?/)
    end.map { ":#{it}" }
  end

  # A factory the setup may call: every association it declares is a bare
  # name, so the world can hand it records it already made. A factory that
  # derives one (`copy { association :copy, status: "on_loan" }`) encodes a
  # state the app should reach through its own actions.
  #: (untyped factory) -> Array[Symbol]?
  def seedable(factory)
    names = factories.map(&:name)
    decls = factory.definition.declarations.to_a
    assocs = decls.select { names.include?(it.name) || it.is_a?(FactoryBot::Declaration::Association) }
    derived = assocs.reject { it.is_a?(FactoryBot::Declaration::Implicit) || plain_association?(it) }
    return nil if derived.any? { encodes_state?(it) }

    # A parent the factory makes with an identity of its own (a staff
    # member whose role is "practitioner") is left to the factory.
    (assocs - derived).map(&:name)
  end

  #: (untyped decl) -> bool
  def encodes_state?(decl)
    text = case decl
           when FactoryBot::Declaration::Association then decl.instance_variable_get(:@overrides).keys.join(" ") + " " + decl.instance_variable_get(:@traits).join(" ")
           when FactoryBot::Declaration::Dynamic
             file, line = decl.instance_variable_get(:@block)&.source_location
             file && File.file?(file) ? File.readlines(file)[line - 1].to_s : "status"
           else "status"
           end
    text.match?(/status|state/)
  end

  # `branch { association :branch }` and `association :branch` name the
  # record as a bare `branch` does: the world can hand it one it made. Only
  # an override or a trait (`association :copy, status: "on_loan"`) encodes
  # a state.
  #: (untyped decl) -> bool
  def plain_association?(decl)
    case decl
    when FactoryBot::Declaration::Association
      decl.instance_variable_get(:@overrides).empty? && decl.instance_variable_get(:@traits).empty? &&
        decl.instance_variable_get(:@factory_name) == decl.name
    when FactoryBot::Declaration::Dynamic
      block = decl.instance_variable_get(:@block)
      file, line = block&.source_location
      text = file && File.file?(file) ? File.readlines(file)[line - 1].to_s : ""
      text.match?(/\b#{decl.name}\s*\{\s*association\s*\(?\s*:#{decl.name}\s*\)?\s*\}/)
    else false
    end
  end

  # The world each area starts from: two of each root record, members three,
  # and each child made from records already there, every pairing once.
  #: (Array[String] inserted, Array[String] wanted) -> Array[String]
  def setup_lines(inserted, wanted)
    made = {} #: Hash[Symbol, Integer]
    lines = [] #: Array[String]
    needed = Set.new #: Set[Symbol]
    deps = ->(f) { Array(seedable(f)) | named_parents(f) }
    grow = ->(f) { needed.add?(f.name) && deps.(f).each { |a| factories.find { it.name == a }&.then { grow.(it) } } }
    factories.select { seedable(it) && wanted.include?(it.build_class.table_name) }.each { grow.(it) }
    pending = factories.select { seedable(it) && needed.include?(it.name) }
    until pending.empty?
      ready = pending.select { |f| deps.(f).all? { made.key?(it) } }
      break if ready.empty?

      ready.each do |factory|
        pending.delete(factory)
        model = factory.build_class
        assocs = seedable(factory) #: Array[Symbol]
        next if assocs.any? && inserted.include?(model.table_name)

        var = factory.name.to_s.pluralize
        limits = capacity_args(model, factory) + distinct_times(model)
        sizes = assocs.map { made[it] }
        if assocs.empty? && limits.empty?
          traits = factory.definition.defined_traits.map(&:name)
          # Each trait in turn (a host, then a manager), so an action only
          # one kind of record may take is reached.
          lines << (traits.empty? ? "#{var} = create_list(:#{factory.name}, world_size(:#{var}, #{root_sizes(factory)}))" :
                    "#{var} = Array.new(world_size(:#{var}, #{root_sizes(factory)})) { |i| create(:#{factory.name}, *#{[Array.new, *traits.map { [it.to_sym] }].inspect}[i % #{traits.size + 1}]) }")
        else
          most = sizes.inject(1) { |a, b| a * b }.clamp(2, 6)
          # Strides from the sizes drawn this case, and no more children than
          # parent pairings, so each child pairs its parents once.
          picks = assocs.each_with_index.map do |a, i|
            stride = assocs.first(i).map { "#{it.to_s.pluralize}.size" }.join(" * ").presence || "1"
            "#{a}: #{a.to_s.pluralize}[i / (#{stride}) % #{a.to_s.pluralize}.size]"
          end
          # A parent a unique index holds to one child (one open membership
          # per member) is used once: each child takes the next parent, and
          # there are no more children than parents.
          held = conn_unique_columns(model)
          once = assocs.select { held.include?(model.reflect_on_association(it)&.foreign_key.to_s) }
          # A parent that `has_one` of these takes one only if it has none
          # yet: a trait (an insured patient) may have made it one already.
          single = assocs.select do |a|
            parent = model.reflect_on_association(a)&.klass rescue nil
            parent&.reflect_on_all_associations(:has_one)&.any? { !it.through_reflection? && !it.options[:as] && (it.klass rescue nil) == model }
          end
          single.each do |a|
            fk = model.reflect_on_association(a).foreign_key
            lines << "free_#{a.to_s.pluralize} = #{a.to_s.pluralize}.reject { #{model.name}.exists?(#{fk}: it.id) }"
          end
          once |= single
          list = ->(a) { single.include?(a) ? "free_#{a.to_s.pluralize}" : a.to_s.pluralize }
          once.each do |a|
            at = assocs.index(a) #: Integer
            picks[at] = "#{a}: #{list.(a)}[i]"
          end
          # A payment of kind "invoice" belongs to an invoice, and to that
          # invoice's patient: a world where it has neither is one the app
          # never makes.
          named_parents(factory).each do |n|
            pick = "#{n.to_s.pluralize}[i % #{n.to_s.pluralize}.size]"
            parent = model.reflect_on_association(n).klass
            assocs.each_with_index { |a, j| picks[j] = "#{a}: #{pick}.#{a}" if parent.reflect_on_association(a)&.macro == :belongs_to }
            picks << "#{n}: #{pick}"
          end
          range = assocs.empty? ? root_sizes(factory) : "1..#{most}"
          count = "world_size(:#{var}, #{range})"
          count = "[#{count}, #{(once.any? ? once : assocs).map { "#{list.(it)}.size" }.join(once.any? ? ", " : " * ")}].min" if assocs.any?
          lines << "#{var} = Array.new(#{count}) { |i| create(:#{factory.name}, #{(picks + limits).join(", ")}) }"
          lines.concat(settle_lines(var, model, made.keys.map { it.to_s.pluralize }))
        end
        # The largest each can be: a child pairs with every parent up to it.
        largest = assocs.empty? ? root_sizes(factory).max : sizes.inject(1) { |a, b| a * b }.clamp(2, 6) #: Integer
        made[factory.name] = largest
      end
    end
    lines
  end

  # The optional parents a factory's own values name (kind "invoice" and
  # `belongs_to :invoice, optional: true`), which the setup fills.
  #: (untyped factory) -> Array[Symbol]
  def named_parents(factory)
    values = (FactoryBot.attributes_for(factory.name) rescue Hash.new).values.grep(String)
    names = factories.map(&:name)
    factory.build_class.reflect_on_all_associations(:belongs_to)
           .select { it.options[:optional] && !it.polymorphic? && values.include?(it.name.to_s) && names.include?(it.name) }.map(&:name)
  end

  # World sizes are drawn per case, so capacity pressure and an empty
  # waitlist both happen: members 2 to 8, other roots 1 to 3.
  #: (untyped factory) -> Range[Integer]
  def root_sizes(factory) = factory.name == :member ? (2..8) : (1..3)

  # A capacity column (seats, capacity, a limit) drawn 1 to 3 per record.
  # A capacity column some records must leave blank (seats only on a team
  # plan) would make every drafted record invalid, so it is drawn only when
  # the factory's record stays valid with it set.
  #: (untyped model, untyped factory) -> Array[String]
  def capacity_args(model, factory)
    model.columns.select { it.type == :integer && it.name.match?(/capacity|seats|limit|\Amax_|slots|quota/) }
         .select { |col| (FactoryBot.build(factory.name, col.name => 1).valid? rescue true) }
         .map { "#{it.name}: world_size(:\"#{model.model_name.plural}.#{it.name}\", 1..3)" }
  end

  # The columns a unique index holds alone, partial ones included: a
  # partial index still forbids two rows its condition selects, and the
  # factory's defaults usually meet that condition.
  #: (untyped model) -> Array[String]
  def conn_unique_columns(model)
    indexes = ActiveRecord::Base.connection.indexes(model.table_name).select(&:unique)
    alone = indexes.select { Array(it.columns).size == 1 }.map { Array(it.columns).first }
    # One parent with a day or a kind (`member_id, visited_on`): the factory
    # gives every record the same day, so each parent is used once.
    shared = indexes.filter_map { |i| ids = Array(i.columns).grep(/_id\z/); ids.first if Array(i.columns).size > 1 && ids.one? }
    (alone + shared).uniq
  end

  # A time column a unique index or an exclusion constraint holds (one start
  # per member) collides when every record takes the factory's one default,
  # and a collision in the world is the setup's, not the app's. Each record
  # gets its own hour instead.
  #: (untyped model) -> Array[String]
  def distinct_times(model)
    conn = ActiveRecord::Base.connection
    held = conn.indexes(model.table_name).select(&:unique).flat_map { Array(it.columns) }
    held += conn.exclusion_constraints(model.table_name).flat_map { it.expression.scan(/\w+/) } if conn.respond_to?(:exclusion_constraints)
    times = model.columns.select { %i[datetime timestamp].include?(it.type) && held.include?(it.name) }
    # An end held with its start is left to the factory, which derives it
    # from the start (`starts_at + service.duration`); the same hour for both
    # makes an empty slot.
    times = times.reject { it.name.match?(/\A(.*_)?(ends?|finish(es)?|until|to)_at\z/) } if times.size > 1
    times.map { "#{it.name}: Time.current.beginning_of_hour + (i + 1).hours" }
  end

  # Tables an action of the area inserts into as its own resource (its name
  # names the table, as loans_create names loans). Those the setup leaves to
  # the app. A table inserted only as a side effect of another resource's
  # action (a kiosk return that requests a transfer) is seeded too: that
  # action needs a world of its own first, so without seeding, the actions
  # that draw from the table would never run.
  #: (Array[Draft] selected, Hash[Symbol, untyped] stats) -> Array[String]
  def made_by_own_actions(selected, stats)
    selected.flat_map do |a|
      stats[a.name][:writes].keys.grep(/\Ainsert /).map { it.split.last }
                          .select { |t| a.name.to_s.include?(t) || a.name.to_s.include?(t.singularize) }
    end.uniq - copied_from(selected)
  end

  # A table an action draws a record or a value from (`practitioner:
  # :practitioners`, `guest_email_from: :guest_passes`)
  # is made in the setup even when the area inserts into it: an empty pool
  # leaves the action never drawn.
  #: (Array[Draft] selected) -> Array[String]
  def copied_from(selected) = selected.flat_map { |d| d.params.values.grep(Symbol).map { pool_table(it) } }.uniq

  #: (Array[Draft] selected) -> Array[String]
  def pool_tables(selected) = selected.flat_map { it.params.values }.grep(Symbol).map { pool_table(it) }

  # What the actions read in the probe (a member's active membership) is
  # made too, or each check-in is refused for a record the area never has.
  #: (Array[Draft] selected, Hash[Symbol, untyped] stats) -> Array[String]
  def setup_tables(selected, stats) = pool_tables(selected) | selected.flat_map { stats.dig(it.name, :reads)&.keys || [] }

  #: (Array[Draft] selected) -> Hash[Symbol, Hash[Symbol, untyped]]
  def probe(selected)
    source = definition_source("probe", selected, {}, refusals: [], failures: [], setup: setup_lines([], models.map(&:table_name)))
    definition = Sequences::Definition.new("probe", shared: false)
    inside = source.lines[1..-2] #: Array[String]
    definition.instance_eval(inside.join)
    Sequences.probe(definition)
  end

  # The table a resource is about: `room_bookings` -> room_bookings,
  # `api_staff_closures` -> closures; nil for `api_kiosk` or a webhook.
  #: (String? resource) -> String?
  def primary(resource)
    word = resource.to_s.split("_").each_index.lazy.map { |i| resource.to_s.split("_").drop(i).join("_") }.find { model_for(it.singularize) }
    word && model_for(word.singularize).table_name
  end

  # Constants a source file names, directly or in an app class it names (one
  # hop): where the probe saw no write or no outside call, this places a job
  # or an endpoint and says which fakes it can reach.
  # A route's file is `path#action`: only that method is read.
  #: (String? file) -> Array[String]
  def static_constants(file)
    path, method = file.to_s.split("#", 2)
    return [] unless File.exist?(path.to_s)

    @static ||= Hash.new
    @static[file] ||= begin
      names = ->(p) { Array.new.tap { |acc| walk_constants(Prism.parse_file(p).value, acc) } } #: ^(String) -> Array[String]
      tree = Prism.parse_file(path.to_s).value #: untyped
      tree = tree.breadth_first_search { it.is_a?(Prism::DefNode) && it.name.to_s == method } || tree if method
      direct = Array.new.tap { walk_constants(tree, it) } #: Array[String]
      hop = direct.uniq.filter_map { it.safe_constantize }.select { it.is_a?(Module) && !(it.is_a?(Class) && it < ActiveRecord::Base) }
                  .filter_map { Object.const_source_location(it.name)&.first }.select { it.start_with?(Rails.root.join("app").to_s) }
      (direct + hop.uniq.flat_map(&names)).uniq
    end
  end

  #: (String? file) -> Hash[String, Integer]
  def static_tables(file)
    static_constants(file).filter_map { it.safe_constantize }.select { it.is_a?(Class) && it < ActiveRecord::Base && !it.abstract_class? }
                          .map(&:table_name).tally
  end

  #: (untyped node, Array[String] acc) -> void
  def walk_constants(node, acc)
    acc << node.slice if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    node.compact_child_nodes.each { walk_constants(it, acc) } unless node.is_a?(Prism::ConstantPathNode)
  end

  # Areas: resources about the same table form one area (`holds` and
  # `api_holds`). A resource about no table joins the area whose table it
  # writes most (or names most, when the probe saw it write nothing). Each
  # area then gets the actions that make the records its pools take, and is
  # filled, jobs first, with the actions that write its table, up to
  # MAX_ACTIONS.
  #: (Hash[Symbol, untyped] stats) -> Array[[String, Array[Draft], Array[String]]]
  def areas(stats)
    written = ->(d) { stats[d.name][:writes].keys.map { it.split.last }.uniq } #: ^(Draft) -> Array[String]
    inserts = ->(d, t) { stats[d.name][:writes]["insert #{t}"] } #: ^(Draft, String) -> Integer
    touches = ->(d) { written.(d).then { it.empty? || d.kind == :job ? it | static_tables(d.file).keys : it } } #: ^(Draft) -> Array[String]
    seeds = drafts.select(&:resource).group_by { primary(it.resource) || "~#{it.resource}" }
    areas = seeds.reject { |k, _| k.start_with?("~") }.map { |table, ds| [table, ds.dup] }.to_h
    seeds.select { |k, _| k.start_with?("~") }.each do |key, ds|
      counts = ds.flat_map(&written).tally
      counts = ds.map { static_tables(it.file) }.inject(Hash.new) { |a, b| a.merge(b) { |_, x, y| x + y } } if counts.empty?
      target = counts.select { |t, _| areas.key?(t) }.max_by { |t, n| [n, t] }&.first
      if target then areas[target].concat(ds)
      else areas[key.delete_prefix("~")] = ds.dup
      end
    end
    seeded = factories.select { seedable(it) }.map { it.build_class.table_name }
    # The action that made the most rows of each pool no factory seeds, so a
    # pool of loans has a loans_create to fill it.
    makers = lambda do |selected|
      needed = selected.flat_map { it.params.values }.grep(Symbol).map { pool_table(it) }.uniq - seeded
      needed.filter_map do |pool|
        next if selected.any? { inserts.(it, pool).positive? }

        best = drafts.max_by { inserts.(it, pool) } #: Draft
        best if inserts.(best, pool).positive?
      end.uniq
    end
    # An action the probe saw refused for a state ("Only a checked in
    # appointment can be completed") never runs in an area that cannot reach
    # the state. The action whose name the refusal says (check_ins) joins it.
    stem = ->(word) { word.downcase.sub(/(ed|ing|s)\z/, "") }
    enablers = lambda do |chosen|
      records = chosen.flat_map { it.params.values }.grep(Symbol).map { stem.(pool_table(it).singularize) }
      # The probe walks every action at once, so it may have reached the state
      # there: any refusal it saw counts.
      texts = chosen.flat_map { stats[it.name][:refusals] || [] }
      texts.flat_map do |text|
        said = text.downcase.scan(/[a-z]+/).map(&stem)
        drafts.reject { chosen.include?(it) }.select do |d|
          next false unless stats[d.name][:outcomes].keys.any? { !it.include?("refused") }

          tokens = d.kind == :api ? d.name.to_s.split("_id_", 2)[1].to_s.split("_") : d.resource.to_s.split("_")
          (tokens.map(&stem) - records).reverse.take_while { said.include?(it) }.any? { it.size >= 4 }
        end
      end.uniq
    end
    placed = drafts
    result = areas.map do |table, ds|
      selected = ds + makers.(ds)
      others = drafts.reject { selected.include?(it) }.select { touches.(it).include?(table) }
      others = others.sort_by { |d| [d.kind == :job ? 0 : 1, -stats[d.name][:writes].select { |k, _| k.end_with?(" #{table}") }.values.sum, d.name.to_s] }
      others.each do |d|
        break if selected.size >= MAX_ACTIONS

        selected += [d] + makers.(selected + [d])
      end
      selected += enablers.(selected)
    [table, selected, ([table] + selected.flat_map(&written)).uniq] #: [String, Array[Draft], Array[String]]
  end
  # An action no area took (a job that only reaches a table no resource is
  # about) joins the area that writes most of what it touches.
  placed.each do |d|
    next if result.any? { |_, ds, _| ds.include?(d) }

    best = result.max_by { |_, _, own| (touches.(d) & own).size }
    best[1] << d if best && (touches.(d) & best[2]).any?
  end
  result
end

  # A desk route and an API endpoint that make or change the same record:
  # `holds_create` and POST /api/v1/holds, `fines_pay` and POST
  # /api/v1/fines/:id/pay. Matched by the table both are about and the verb:
  # the probe often sees one of the two only refused, so writes miss pairs.
  #: (Draft d) -> Symbol?
  def door_key(d)
    if d.kind == :route
      action = d.name.to_s.delete_prefix("#{d.resource}_")
      { "create" => :create, "destroy" => :destroy }.fetch(action, action.to_sym)
    else
      verb, last = d.name.to_s[/\Aapi_(\w+?)_/, 1], d.body[%r{"/api/v\d+/[^"]*?([a-z_]+)"}, 1]
      # `POST /appointments/:id/visit` makes a visit, not an appointment.
      made = model_for(last.to_s.singularize)
      verb == "delete" ? :destroy : (made && made.table_name == primary(d.resource) ? :create : last&.to_sym)
    end
  end

  #: (Array[Draft] selected, Hash[Symbol, untyped] stats) -> Array[[Symbol, Symbol, String]]
  def twins(selected, stats)
    return [] if stats.empty? # the probe itself
    selected.select { it.kind == :route }.flat_map do |desk|
      table = primary(desk.resource) or next []
      selected.select { it.kind == :api && primary(it.resource) == table && door_key(it) == door_key(desk) }
              .map { [desk.name, it.name, table] }
    end
  end

  #: (String name, Array[Draft] selected, Hash[Symbol, untyped] stats, refusals: Array[String], failures: Array[Failure], ?setup: Array[String], ?note: String?) -> String
  def definition_source(name, selected, stats, refusals:, failures:, setup: [], note: nil)
    pools = selected.flat_map { it.params.values }.grep(Symbol).reject { %i[TODO local_date local_time text].include?(it) }.uniq
    reached = ->(d) { (stats.dig(d.name, :outside) || []) | fakes.select { |service, _| static_constants(d.file).include?(service) }.map(&:last) }
    armed = failures.select { |f| f.code.start_with?("failure") && selected.any? { reached.(it).include?(f.service) } }
    out = +"Sequences.define(#{name.inspect}) do\n"
    out << "  # #{note}\n" if note
    network_note(selected).each { out << "  # #{it}\n" }
    out << "  setup do\n"
    fakes.each { |service, fake| out << "    #{service}.client = #{fake}.new\n" }
    (api_auth[:envs].map { it[1] } | controller_envs).uniq.each { |env| out << "    ENV[#{env.inspect}] = \"sequences-#{env.downcase.tr("_", "-")}\"\n" }
    sign_in = session_sign_in
    signs_in = sign_in && selected.any? { it.body.include?("desk_sign_in") || it.body.include?(sign_in[:path].inspect) }
    out << "    #{sign_in[:setup]}\n" if sign_in && signs_in && sign_in[:setup]
    # The caller's own record heads the list of its kind when the setup
    # makes one, so the records made from that list (its membership, its
    # appointments) always include one of its own.
    own = selected.any? { it.kind == :api } ? api_own_records : Array.new
    setup = setup.flat_map do |line|
      joined = own.select { |_, made, _| line.start_with?("#{made[/create\(:(\w+)/, 1].pluralize} = ") }
      own -= joined
      [line, *joined.map { |_, made, _| "#{made[/create\(:(\w+)/, 1].pluralize}.unshift(#{made})" }]
    end
    own.each { out << "    #{it[1]}\n" }
    setup.each { out << "    #{it}\n" }
    out << "  end\n\n"
    pools.each { out << "  pool(:#{it}) { #{owned_pools[it] || pool_table(it).classify}.order(:id) }\n" }
    out << "\n"
    unless refusals.empty?
      out << "  # Errors the probe saw an action raise on purpose (classes the app defines).\n"
      out << "  # Delete one that must never escape; any other error fails the run.\n"
      out << "  refusals #{refusals.join(", ")}\n\n"
    end
    out << "  outside_calls #{fakes.map(&:last).join(", ")}\n" unless fakes.empty?
    out << "  clock start: [2026, 3, 7, 10, 0, 0], zones: [\"Pacific/Auckland\", \"America/Los_Angeles\"]\n\n"
    helper_lines = [] #: Array[String]
    if selected.any? { it.kind == :api }
      own = api_own_records
      headers = api_auth[:lookups].filter_map do |h, model, col, literal, bearer|
        next if own.any? { it[0] == h }

        "#{h.inspect} => #{model == api_caller_model ? "caller" : "#{model}.order(:id).first"}&.#{col}.to_s"
      end
      headers += own.map { |h, _, token| "#{h.inspect} => #{(api_auth[:lookups].find { it[0] == h }&.last ? "Bearer #{token}" : token).inspect}" }
      headers += api_auth[:envs].map { |h, env, bearer| "#{h.inspect} => #{bearer ? "\"Bearer \#{ENV[#{env.inspect}]}\"" : "ENV[#{env.inspect}]"}" }
      headers.uniq! { it[/\A"[^"]+"/] }
      helper_lines << "    def auth_for(caller = nil) = { #{headers.join(", ")} }"
    end
    if sign_in && signs_in
      helper_lines << "    # The desk pages need a staff session; #{sign_in[:path]} makes one."
      helper_lines << "    def desk_sign_in = http.post(#{sign_in[:path].inspect}, params: { #{sign_in[:body].join(", ")} })"
    end
    out << "  helpers do\n#{helper_lines.join("\n")}\n  end\n\n" unless helper_lines.empty?
    shown = failures.select { |f| selected.any? { reached.(it).include?(f.service) } }
    shown.each { out << "  #{it.code}\n" }
    out << "\n" unless shown.empty?
    twins(selected, stats).each { |a, b, t| out << "  twins :#{a}, :#{b}, table: :#{t}\n" }
    selected.each do |d|
      spec = d.params.map { |k, v| "#{k}: #{v.is_a?(Symbol) ? ":#{v}" : v.inspect}" }
      fs = armed.select { reached.(d).include?(it.service) }.map(&:name)
      spec << "failures: %i[#{fs.join(" ")}]" unless fs.empty?
      spec << "pause_at: :batch_load" if d.kind == :job
      fresh = d.body.to_s.scan(/(\w+): FactoryBot\.attributes_for/).flatten.uniq
      spec << "fresh: %i[#{fresh.join(" ")}]" if fresh.any?
      out << "  action(#{[":#{d.name}", *spec].join(", ")}) #{d.body}\n"
    end
    out << "end\n"
  end

  #: (Hash[Symbol, untyped] stats, Array[Draft] selected) -> Array[String]
  def app_refusals(stats, selected)
    selected.flat_map { stats[it.name][:errors].keys }.uniq.select do |name|
      klass = name.safe_constantize
      klass.is_a?(Class) && klass < StandardError && Object.const_source_location(name)&.first.to_s.start_with?(Rails.root.join("app").to_s)
    end.sort
  end

  #: (String name, String source) -> String
  def spec_file(name, source)
    <<~RUBY
      require "rails_helper"
      require ENV.fetch("SEQUENCES_LIB")
      require_relative "invariants"

      # Drafted by propose.rb. Edit freely: the setup world, a pool (for
      # example `Loan.active`), a TODO. Invariants for every area go in invariants.rb.
      #{source.chomp}

      RSpec.describe "#{name} sequences" do
        self.use_transactional_tests = false

        it "holds its invariants in any order, interleaving and time zone" do
          Sequences.explore(Sequences[#{name.inspect}], test_cases: Integer(ENV.fetch("SEQ_CASES", "100")), seed: ENV["SEQ_SEED"]&.to_i)
        end
      end
    RUBY
  end

  #: (untyped model) -> Array[String]
  def statuses(model)
    return [] unless model.column_names.include?("status")

    inclusion = model.validators_on(:status).grep(ActiveModel::Validations::InclusionValidator).first&.options&.[](:in)
    Array(inclusion || (model.const_get(:STATUSES, false) if model.const_defined?(:STATUSES, false))).map(&:to_s)
  end

  SETTLED = /\A(paid|settled|completed?|captured|succeeded)\z/ #: Regexp
  AMOUNT = /_cents\z|\Aamount\z/ #: Regexp

  # Money conserved: a record with an amount and a status, and its payments
  # (or charges) with an amount and a status. What a settled record says it
  # took must be what was captured for it, and nothing for any other status.
  #: () -> Array[MoneyRule]
  def money_rules
    @money_rules ||= models.flat_map do |model|
      amount = model.column_names.find { it.match?(AMOUNT) } or next []
      settled = statuses(model).grep(SETTLED)
      next [] if settled.empty?

      model.reflect_on_all_associations(:has_many).filter_map do |assoc|
        next unless assoc.name.to_s.match?(/payment|charge|capture|transaction/) && !assoc.options[:through]

        child = assoc.klass
        paid = child.column_names.find { it.match?(AMOUNT) }
        captured = statuses(child).grep(SETTLED)
        next if paid.nil? || captured.empty?

        # Payments of several kinds (a deposit and a fee) answer for
        # different amounts; the rule compares one kind with the amount it
        # pays, and is not drafted when nothing says which kind that is.
        kind = kind_filter(model, amount, child) or next
        MoneyRule.new(model:, amount:, settled:, assoc:, child:, paid:, captured:, kind:)
      end
    end
  end

  #: () -> Array[String]
  def money_invariants
    money_rules.map do |r|
      # A payment of one kind (a deposit) may be taken at booking, before the
      # record reaches a settled status, and a desk booking may take none:
      # for it only "never more than the amount" holds in every status.
      rule, check =
        if r.kind.empty?
          ["a #{r.settled.join("/")} #{r.model.model_name.human.downcase} took its #{r.amount} through #{r.assoc.name} #{r.captured.join("/")}; any other status took nothing.",
           "taken == (#{r.settled.inspect}.include?(record.status) ? record.#{r.amount} : 0)"]
        else
          ["no #{r.model.model_name.human.downcase} took more than its #{r.amount} through #{r.assoc.name} #{r.captured.join("/")}.",
           "taken <= record.#{r.amount}"]
        end
      <<~RUBY.chomp
        # drafted, check it is a real rule: #{rule}
        invariant(:#{r.name}) do
          bad = #{r.model.name}.all.reject do |record|
            taken = #{r.child.name}.where(#{r.assoc.foreign_key}: record.id, status: #{r.captured.inspect}#{r.kind}).sum(:#{r.paid})
            #{check}
          end
          bad.empty? || "#{r.model.model_name.plural} \#{bad.map(&:id)}: #{r.amount} and the #{r.assoc.name} captured for them differ"
        end
      RUBY
    end
  end

  # Factories make each record alone: an open invoice and a succeeded
  # payment for it break the money rule before any action runs. After the
  # payments are made, each record with a captured one is marked settled at
  # the amount captured, so the hunt starts from a world the rule allows.
  #: (String child_var, untyped child_model, Array[String] made_vars) -> Array[String]
  def settle_lines(child_var, child_model, made_vars)
    money_rules.filter_map do |r|
      next unless r.child == child_model && r.kind.empty? && r.owner

      parent_var = r.owner.to_s.pluralize
      next unless made_vars.include?(parent_var)

      "#{child_var}.select { #{r.captured.inspect}.include?(it.status) }.group_by(&:#{r.owner}).each { |record, taken| record.update_columns(status: #{r.settled.first.inspect}, #{r.amount}: taken.sum(&:#{r.paid})) } # keeps #{r.name}"
    end
  end

  KIND_COLUMN = /\A(kind|purpose|category|payment_type|charge_type)\z/ #: Regexp

  # "" when the payments have one kind; ", kind: record.kind" when both
  # sides name the kind; ", kind: \"deposit\"" when the amount column names
  # one (deposit_cents); nil when nothing says which payments count.
  #: (untyped model, String amount, untyped child) -> String?
  def kind_filter(model, amount, child)
    col = child.column_names.find { it.match?(KIND_COLUMN) } or return ""
    return ", #{col}: record.#{col}" if model.column_names.include?(col)

    values = child.validators_on(col.to_sym).grep(ActiveModel::Validations::InclusionValidator).first&.options&.[](:in)
    values ||= %W[#{col.upcase}S KINDS].filter_map { child.const_get(it, false) if child.const_defined?(it, false) }.first
    stem = amount.delete_suffix("_cents")
    found = Array(values).map(&:to_s).find { stem != "amount" && (stem.include?(it) || it.include?(stem)) }
    found && ", #{col}: #{found.inspect}"
  end
  # Order kept: a waiting status (waitlisted, queued, pending) that some code
  # reads in timestamp order. Rows alike in all but when they entered it must
  # leave it in that order.
  #: () -> Array[String]
  def order_invariants
    code = Rails.root.glob("app/**/*.rb").map { File.read(it) }.join("\n")
    models.flat_map do |model|
      all = statuses(model)
      all.grep(/wait|queue|pend/).filter_map do |from|
        plural = model.model_name.plural
        ordered = code.lines.find do |line|
          line.match?(/\.order\(:?\w*_at\b|order\(created_at|order\(:created_at/) &&
            (line.match?(/scope :#{from}\b/) || line.match?(/\b#{plural}\.#{from}\b/) || line.include?("status: \"#{from}\""))
        end or next
        to = all - [from] - all.grep(/cancel|expire|withdr|delet|reject|fail|declin|refund/)
        next if to.empty?

        call = code[/(\w+)\.#{plural}\.#{from}\b/, 1]
        group = ["#{call}_id"].find { model.column_names.include?(it) }
        name = "#{plural}_leave_#{from}_in_entry_order"
        <<~RUBY.chomp
          # drafted, check it is a real rule: read in timestamp order at
          #   #{ordered.strip[0, 100]}
          # Rows alike in every column but ids and times leave #{from} in the order they entered it.
          invariant(:#{name}) do
            Sequences.order_kept(#{model.name}, from: #{from.inspect}, to: #{to.inspect}#{", group: :#{group}" if group})
          end
        RUBY
      end
    end
  end

  # One child each: a `has_one` the database does not hold to one row (no
  # unique index on its key) is held by the code alone, and two requests at
  # once can leave two, of which the app then reads either.
  #: () -> Array[String]
  def one_child_invariants
    models.flat_map do |model|
      model.reflect_on_all_associations(:has_one).filter_map do |assoc|
        next if assoc.through_reflection? || assoc.options[:as] || (assoc.scope && assoc.scope.arity != 0)

        child = assoc.klass rescue next
        fk = assoc.foreign_key.to_s
        next unless child.table_exists? && child.column_names.include?(fk)
        next if child.connection.indexes(child.table_name).any? { it.unique && it.columns.is_a?(Array) && it.columns.first == fk && it.columns.size == 1 && it.where.nil? }

        rows = assoc.scope ? "#{model.name}.reflect_on_association(:#{assoc.name}).then { it.klass.instance_exec(&it.scope) }" : child.name
        <<~RUBY.chomp
          # drafted, check it is a real rule: #{model.name} has_one :#{assoc.name}, and no unique index holds it to one row.
          invariant(:#{model.model_name.singular}_has_one_#{assoc.name}) do
            bad = #{rows}.where.not(#{fk}: nil).group(:#{fk}).having("COUNT(*) > 1").count.keys
            bad.empty? || "#{model.model_name.plural} \#{bad}: more than one #{assoc.name}"
          end
        RUBY
      end
    end
  end

  # Bounds a column name states: what is left never goes below zero, a
  # count never passes its max, and a percentage stays within 0..100.
  #: () -> Array[String]
  def bound_invariants
    models.flat_map do |model|
      cols = model.columns.select { %i[integer decimal float].include?(it.type) }.map(&:name)
      plural = model.model_name.plural
      rules = cols.grep(/(\A|_)(left|remaining)\z/).map do |col|
        ["#{plural}_#{col}_not_negative", "#{col} is never below zero", "#{model.name}.where(\"#{col} < 0\")"]
      end
      rules += cols.grep(/\Amax_(\w+)\z/).filter_map do |max|
        stem = max.delete_prefix("max_")
        count = cols.find { it == "#{stem}_count" } or next
        ["#{plural}_#{count}_within_#{max}", "#{count} never passes #{max}", "#{model.name}.where(\"#{max} IS NOT NULL AND #{count} > #{max}\")"]
      end
      rules += cols.grep(/percent/).map do |col|
        ["#{plural}_#{col}_within_0_100", "#{col} stays within 0..100", "#{model.name}.where(\"#{col} < 0 OR #{col} > 100\")"]
      end
      rules.map do |name, says, query|
        <<~RUBY.chomp
          # drafted, check it is a real rule: #{model.name}##{says}.
          invariant(:#{name}) do
            bad = #{query}.pluck(:id)
            bad.empty? || "#{plural} \#{bad} break the rule: #{says}"
          end
        RUBY
      end
    end
  end

  #: () -> Array[String]
  def drafted_invariants = money_invariants + order_invariants + one_child_invariants + bound_invariants

  # The drafted rules are live; the TODOs ask for the rest. A run with no
  # invariants still checks errors, 5xx, zones, offsets and doors.
  #: () -> String
  def invariants_file
    stateful = models.select { it.column_names.include?("status") }
    <<~RUBY
      # Rules that hold after every step, in every area. Each block returns true
      # (or nil) when the rule holds, or a message naming the rows that break it.
      # Keep `\#{...}` inside a plain double-quoted string; a block is Ruby, not a heredoc.
      Sequences.everywhere do
      #{drafted_invariants.join("\n\n").gsub(/^(?=.)/, "  ")}

        # invariant(:copy_on_loan_has_one_active_loan) do
        #   bad = Copy.where(status: "on_loan").reject { Loan.active.where(copy_id: it.id).count == 1 }
        #   bad.empty? || "copies \#{bad.map(&:id)} on loan without exactly one active loan"
        # end
      #{stateful.map { "  # TODO invariant over #{it.name}.status: what must hold for each value?" }.join("\n")}
      end
    RUBY
  end

  # An invariants.rb that exists keeps the agent's rules; a drafted rule it
  # does not name yet goes in before its last `end`.
  #: (untyped path) -> Array[String]
  def add_drafted(path)
    text = File.read(path)
    missing = drafted_invariants.reject { text.include?(it[/invariant\(:(\w+)\)/, 1].to_s) }
    return [] if missing.empty?

    at = text.rindex(/^end\b/) or return []
    head = text[0...at] #: String
    tail = text[at..] #: String
    File.write(path, head + missing.join("\n\n").gsub(/^(?=.)/, "  ") + "\n" + tail)
    missing.map { it[/invariant\(:(\w+)\)/, 1].to_s }
  end

  #: (String name, Array[Draft] selected, Hash[Symbol, untyped] stats, Array[String] own) -> String
  def summarize(name, selected, stats, own)
    reached = selected.select { |d| stats[d.name][:outcomes].keys.any? { !it.include?("refused") } }
    "#{name}: #{selected.size} actions (#{reached.size} succeeded in the probe), writes #{own.first(6).join(", ")}"
  end

  #: (Array[String] argv) -> void
  def main(argv)
    Rails.application.eager_load!
    force = argv.delete("--force")
    json_path = (i = argv.index("--probe-json")) && argv.slice!(i, 2)&.last
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if argv.delete("--all")
      stats = probe(drafts)
      File.write(json_path, JSON.pretty_generate(stats)) if json_path
      dir = Pathname(ENV.fetch("SEQUENCES_OUT", Rails.root.join("spec/sequences").to_s))
      dir.mkpath
      invariants = dir.join("invariants.rb")
      if invariants.exist?
        added = add_drafted(invariants)
        $stderr.puts "added drafted invariants to #{invariants}: #{added.join(", ")}" unless added.empty?
      else
        File.write(invariants, invariants_file)
        $stderr.puts "wrote #{invariants} with #{drafted_invariants.size} drafted invariants (check each is a real rule)"
      end
      areas(stats).each do |name, selected, own|
        inserted = made_by_own_actions(selected, stats)
        source = definition_source(name, selected, stats, refusals: app_refusals(stats, selected), failures:,
                                                          setup: setup_lines(inserted, setup_tables(selected, stats)), note: "writes #{own.join(", ")}")
        path = dir.join("#{name}.rb")
        if path.exist? && !force
          $stderr.puts "kept #{path.relative_path_from(Rails.root)} (exists; --force replaces it)"
        else
          File.write(path, spec_file(name, source))
          $stderr.puts "wrote #{path.relative_path_from(Rails.root)}  #{summarize(name, selected, stats, own)}"
        end
      end
      errors = stats.select { |_, st| st[:errors].any? }
      $stderr.puts "probe errors (an app class becomes a refusal; any other fails the run):" unless errors.empty?
      errors.each { |name, st| $stderr.puts "  #{name}: #{st[:errors].map { |k, n| "#{k} #{n}" }.join(", ")}" }
      untouched = drafts.select { |d| stats[d.name][:runs].zero? }
      $stderr.puts "never drawn in the probe (a pool was empty): #{untouched.map(&:name).join(", ")}" unless untouched.empty?
    else
      patterns = argv.map { Regexp.new(it, Regexp::IGNORECASE) }
      abort "usage: bundle exec ruby propose.rb --all | AREA [AREA...]" if patterns.empty?
      selected = drafts.select { |d| patterns.any? { d.name.to_s.match?(it) || d.body.match?(it) } }
      stats = probe(selected)
      inserted = made_by_own_actions(selected, stats)
      name = argv.join("_").gsub(/[^a-z0-9_]+/i, "")
      puts spec_file(name, definition_source(name, selected, stats, refusals: app_refusals(stats, selected), failures:, setup: setup_lines(inserted, setup_tables(selected, stats))))
    end
    $stderr.puts "propose: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)} s"
  end
end

Propose.main(ARGV.dup) if $PROGRAM_NAME == __FILE__
