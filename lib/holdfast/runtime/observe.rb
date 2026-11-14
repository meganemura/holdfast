# rbs_inline: enabled

# Loaded by holdfast's pin tests inside the app's own suite. It calls one
# method on one input and turns what it saw into plain JSON: the returned
# value (a record by its attributes, not its class), the error it raised,
# and the attributes of each record the call created or changed. A pin test
# compares that JSON with the JSON the base side produced, and names only the
# paths that differ.
require "json"
require "date"

module Holdfast
  module Observe
    # Ids, foreign keys and timestamps differ between two runs of the same
    # input, so they never decide a pin.
    VOLATILE = /\A(id|created_at|updated_at)\z|_id\z/ #: Regexp
    RECENT = 86_400 #: Integer
    NO_ARGS = Array.new.freeze #: Array[untyped]
    NO_KWARGS = Hash.new.freeze #: Hash[String, untyped]

    # @rbs module-self ActiveRecord::Base
    module Track
      #: (*untyped) -> untyped
      def _create_record(*)
        super.tap { (Thread.current[:holdfast_writes] ||= []) << [:created, self] if Thread.current[:holdfast_writes] }
      end

      #: (*untyped) -> untyped
      def _update_record(*)
        super.tap { (Thread.current[:holdfast_writes] ||= []) << [:updated, self] if Thread.current[:holdfast_writes] }
      end
    end
    ActiveRecord::Base.prepend(Track) if defined?(ActiveRecord::Base)

    module_function

    #: (untyped context, Hash[String, untyped] input, String target) -> Hash[String, untyped]?
    def observe(context, input, target)
      parts = target.match(/\A(.+?)([#.])(\w+[?!=]?)\z/) #: MatchData
      const_name, kind, name = parts.captures #: [String, String, String]
      const = Object.const_get(const_name)
      within_savepoint do
        run_ruby(context, input["before"]) if input["before"]
        receiver = if input.key?("receiver") then value(context, input["receiver"])
                   elsif kind == "." then const
                   else const.new(*value(context, input.fetch("new", NO_ARGS)))
                   end
        args = value(context, Array(input["args"]))
        kwargs = value(context, input.fetch("kwargs", NO_KWARGS)).transform_keys(&:to_sym) #: Hash[Symbol, untyped]
        Thread.current[:holdfast_writes] = []
        outcome = begin
          { "returns" => project(receiver.__send__(name, *args, **kwargs)) }
        rescue StandardError => e
          { "raises" => e.class.name, "message" => e.message.gsub(/\d{4,}/, "N").lines.first.to_s.strip }
        end
        writes = Thread.current[:holdfast_writes]
        outcome["writes"] = written(writes) unless writes.empty?
        outcome
      ensure
        Thread.current[:holdfast_writes] = nil
      end
    end

    # Paths whose values differ, as "path: base X, head Y" lines.
    #: (untyped expected, untyped actual, ?String path) -> Array[String]
    def differences(expected, actual, path = "")
      return [] if expected == actual

      if expected.is_a?(Hash) && actual.is_a?(Hash)
        (expected.keys | actual.keys).flat_map { differences(expected[_1], actual[_1], path.empty? ? _1.to_s : "#{path}.#{_1}") }
      elsif expected.is_a?(Array) && actual.is_a?(Array) && expected.size == actual.size
        expected.each_index.flat_map { differences(expected[_1], actual[_1], "#{path}[#{_1}]") }
      else
        ["#{path.empty? ? "value" : path}: base #{short(expected)}, head #{short(actual)}"]
      end
    end

    #: (untyped v) -> String
    def short(v) = (v.nil? ? "(none)" : v.is_a?(String) ? v : JSON.generate(v)).then { _1.size > 90 ? "#{_1[0, 87]}..." : _1 }

    #: [T] () { () -> T } -> T?
    def within_savepoint
      return yield unless defined?(ActiveRecord::Base)

      result = nil #: T?
      ActiveRecord::Base.transaction(requires_new: true) do
        result = yield
        raise ActiveRecord::Rollback
      end
      result
    end

    #: (untyped context, untyped code) -> untyped
    def run_ruby(context, code) = context.instance_eval(code.is_a?(Hash) ? code.fetch("ruby") : code.to_s)

    #: (untyped context, untyped v) -> untyped
    def value(context, v)
      case v
      when Hash then v.keys == ["ruby"] ? run_ruby(context, v) : v.to_h { [_1, value(context, _2)] }
      when Array then v.map { value(context, _1) }
      else v
      end
    end

    #: (Array[[Symbol, untyped]] writes) -> Array[Hash[String, untyped]]
    def written(writes)
      seen = {} #: Hash[[Symbol, String?, Integer], Hash[String, untyped]]
      writes.each do |how, record|
        key = [how, record.class.name, record.object_id] #: [Symbol, String?, Integer]
        if how == :created
          seen[key] = { "created" => record.class.name, "attributes" => attributes(record) }
        else
          changed = record.saved_changes.keys.grep_v(VOLATILE)
          next if changed.empty?

          entry = (seen[key] ||= { "updated" => record.class.name, "changed" => {} })
          changed.each { entry["changed"][_1] = project(record.public_send(_1)) }
        end
      end
      seen.values.sort_by { JSON.generate(_1) }
    end

    #: (untyped record) -> Hash[String, untyped]
    def attributes(record) = record.attributes.reject { |k, _| k.match?(VOLATILE) }.sort.to_h.transform_values { project(_1) }

    #: (untyped v, ?Integer depth) -> untyped
    def project(v, depth = 0)
      return v.class.name if depth > 3

      case v
      when nil, true, false, Integer, String then v
      when Float then v.round(6)
      when Symbol then ":#{v}"
      when Date then v.respond_to?(:hour) ? time(v) : "Date #{v.iso8601}"
      when Time then time(v)
      when ->(x) { defined?(ActiveSupport::TimeWithZone) && x.is_a?(ActiveSupport::TimeWithZone) } then time(v)
      when ->(x) { defined?(BigDecimal) && x.is_a?(BigDecimal) } then v.to_s("F")
      when ->(x) { defined?(ActiveRecord::Base) && x.is_a?(ActiveRecord::Base) }
        { "record" => v.class.name, "persisted" => v.persisted? }.merge(attributes(v))
      when ->(x) { defined?(ActiveRecord::Relation) && x.is_a?(ActiveRecord::Relation) } then v.to_a.first(20).map { project(_1, depth + 1) }
      when Array then v.first(50).map { project(_1, depth + 1) }
      when Hash then v.to_h { [_1.is_a?(Symbol) ? ":#{_1}" : _1.to_s, project(_2, depth + 1)] }
      when Data then { "data" => v.class.name }.merge(v.to_h.to_h { [_1.to_s, project(_2, depth + 1)] })
      when Struct then { "struct" => v.class.name }.merge(v.to_h.to_h { [_1.to_s, project(_2, depth + 1)] })
      else { "object" => v.class.name }
      end
    end

    # A time near now comes from the clock, not the input, so it is pinned
    # as recent only.
    #: (untyped t) -> String
    def time(t) = (Time.now.to_f - t.to_f).abs < RECENT ? "Time (now)" : "Time #{t.utc.iso8601}"
  end
end
