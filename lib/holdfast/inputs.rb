# rbs_inline: enabled

module Holdfast
  # The pin inputs of one target, in branchout's format plus three keys of
  # holdfast's own: "change": true on an input the change is meant to alter,
  # "raises" for an intended error, and a "generate" list whose entries hegel
  # expands into concrete inputs. The expansion is derandomized with a fixed
  # seed, so base and head (and every rerun) see the same values.
  #
  #   {"generate": [{"receiver": {"ruby": "create(:loan, due_on: Date.new(2026, 1, 1) - %{days})"},
  #                  "args": [], "draws": {"days": {"integers": [0, 40]}},
  #                  "cases": 20, "change_when": "days > 10"}]}
  class Inputs
    Entry = Data.define(
      :input, #: json
      :change, #: bool
      :note #: String?
    )
    OWN_KEYS = %w[change raises change_when draws cases].freeze #: Array[String]
    SEED = 20_261_107

    #: (String root, String target) -> String
    def self.path(root, target) = File.join(Holdfast.dir(root), "evidence", "#{Holdfast.slug(target)}.inputs.json")

    #: (String root, String target, ?boundaries: Array[Integer]) -> Inputs?
    def self.read(root, target, boundaries: [])
      file = path(root, target)
      return nil unless File.file?(file)

      data = JSON.parse(File.read(file))
      new(file, data, boundaries)
    rescue JSON::ParserError => e
      raise Holdfast::Error, "#{file} is not JSON: #{e.message.lines.first.strip}"
    end

    attr_reader :file #: String
    attr_reader :raw #: json

    # @rbs @boundaries: Array[Integer]
    # @rbs @entries: Array[Entry]?

    #: (String file, json raw, Array[Integer] boundaries) -> void
    def initialize(file, raw, boundaries)
      @file, @raw, @boundaries = file, raw, boundaries
    end

    #: () -> Array[Entry]
    def entries
      @entries ||= Array(raw["inputs"]).map { Entry.new(input: _1.except(*OWN_KEYS), change: _1["change"] == true, note: _1["note"]) } +
                   Array(raw["generate"]).each_with_index.flat_map { |spec, i| generated(spec, i) }
    end

    #: () -> Array[String]
    def declared_errors = Array(raw["inputs"]).filter_map { _1["raises"] }
    #: () -> Integer
    def generated_count = entries.count { _1.note.to_s.start_with?("drawn ") }

    private

    #: (json spec, Integer index) -> Array[Entry]
    def generated(spec, index)
      draws = spec.fetch("draws") { raise Holdfast::Error, "#{file} generate[#{index}] has no \"draws\"" }
      values = drawn_values(draws, spec.fetch("cases", 20), SEED + index)
      values.uniq.map do |names|
        input = fill(spec.except(*OWN_KEYS), names) #: json
        change = spec["change_when"] ? condition_holds?(spec["change_when"], names) : spec["change"] == true
        note = "drawn #{names.map { "#{_1}=#{_2.inspect}" }.join(", ")}"
        Entry.new(input: input.merge("note" => note), change:, note:)
      end
    end

    # hegel draws the values; integer ranges also get each boundary literal of
    # the target, one below it and one above it, so every side of a
    # comparison the method makes gets at least one input.
    #: (Hash[String, json] draws, Integer cases, Integer seed) -> Array[Hash[String, json_value]]
    def drawn_values(draws, cases, seed)
      finite = draws.values.map { _1["one_of"] || (_1["booleans"] && [true, false]) }
      # A small finite space is listed whole; a random draw from it repeats.
      if finite.all? && finite.map(&:size).inject(1, :*) <= [cases, 120].max
        return finite.first.product(*finite.drop(1)).map { draws.keys.zip(_1).to_h }
      end

      require "hegel"
      found = [] #: Array[Hash[String, json_value]]
      Hegel.test(test_cases: cases, derandomize: true, seed:, verbosity: :quiet) do |tc|
        found << draws.to_h { |name, kind| [name, tc.draw(generator(kind))] }
      end
      edges = draws.select { _2.key?("integers") }.flat_map do |name, kind|
        low, high = kind["integers"]
        @boundaries.flat_map { [_1 - 1, _1, _1 + 1] }.select { (low..high).cover?(_1) }.map { |value| [name, value] }
      end #: Array[[String, Integer]]
      found + edges.map { |name, value| (found.first || {}).merge(name => value) }
    end

    #: (json kind) -> Hegel::Generator
    def generator(kind)
      g = Hegel::Generators
      case kind.keys.first
      when "integers" then g.integers(min_value: kind["integers"][0], max_value: kind["integers"][1])
      when "booleans" then g.booleans
      when "one_of" then g.sampled_from(kind["one_of"])
      else raise Holdfast::Error, "#{file}: unknown draw #{kind.keys.first}; use integers, booleans or one_of"
      end
    end

    # A JSON value of any shape, with each draw filled in.
    #: (json_value value, Hash[String, json_value] names) -> json_value
    def fill(value, names)
      case value
      when Hash
        return names.fetch(value["draw"]) if value.keys == ["draw"]

        value.transform_values { fill(_1, names) }
      when Array then value.map { fill(_1, names) }
      when String then value.gsub(/%\{(\w+)\}/) { names.fetch(Regexp.last_match(1)).inspect }
      else value
      end
    end

    #: (String condition, Hash[String, json_value] names) -> bool
    def condition_holds?(condition, names)
      scope = Object.new
      names.each { |name, v| scope.define_singleton_method(name) { v } }
      scope.instance_eval(condition) ? true : false
    end
  end
end
