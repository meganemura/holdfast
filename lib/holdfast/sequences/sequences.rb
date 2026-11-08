# Runs generated sequences of an app's entry points
# against real PostgreSQL: random orders (shrunk by Hegel), two actions
# interleaved at a named pause point, and the same sequence replayed under
# other process time zones. The hunt stage loads it into the app's test
# process through SEQUENCES_LIB, so it needs hegeltest in that bundle.
require "hegel"
require "json"

module Sequences
  class Failure < StandardError
    attr_reader :log, :definition

    def initialize(message, log:, definition:)
      @log = log.map(&:dup)
      @definition = definition
      super(message)
    end

    def message
      "#{super}\n\n#{Report.narrative(@log)}\n\n#{Report.pasteable(@definition, @log)}"
    end
  end

  # The world could not be built, so no sequence ran. Not shrunk.
  class SetupError < StandardError; end

  # A replayed step whose record is missing: the run went another way.
  class Diverged < StandardError; end

  # A pause point is a method on a fake (or any class) where an action can be
  # held while another action runs.
  module Pause
    @points = {}
    class << self
      attr_reader :points

      def define(name, klass, method_name)
        return if @points.key?([name, klass, method_name])

        @points[[name, klass, method_name]] = true
        hook = Module.new do
          define_method(method_name) do |*args, **kw, &blk|
            gate = Thread.current[:sequences_gate]
            Sequences.reached_outside_call(Thread.current[:sequences_action], klass)
            if gate && gate[:point] == name && !gate[:passed]
              gate[:passed] = true
              gate[:paused].push(true)
              gate[:go].pop
            end
            super(*args, **kw, &blk)
          end
        end
        klass.prepend(hook)
      end
    end
  end

  # `pause_at: :batch_load` holds a job right after its first query that
  # returns rows (a find_each batch, a `to_a`), before it touches any of them:
  # the window where a desk action changes a row the job already holds.
  module BatchPause
    # Only the outermost load pauses: `includes(:copy)` loads the copies
    # inside the transfers' load, and holding there held the job on the
    # copies it preloads, not on the rows it acts on.
    def records
      depth = Thread.current[:sequences_load_depth].to_i
      Thread.current[:sequences_load_depth] = depth + 1
      rows = begin
        super
      ensure
        Thread.current[:sequences_load_depth] = depth
      end
      gate = Thread.current[:sequences_gate]
      if gate && gate[:point] == :batch_load && !gate[:passed] && depth.zero? && rows.any?
        gate[:passed] = true
        gate[:relation] = self
        gate[:loaded] = rows.select { it.is_a?(ActiveRecord::Base) }.map { [it.class, it.id, Sequences.state_of(it)] }
        gate[:paused].push(true)
        gate[:go].pop
      end
      rows
    end
  end
  ActiveRecord::Relation.prepend(BatchPause) if defined?(ActiveRecord::Relation)

  STATE_COLUMNS = %w[status state].freeze
  def self.state_of(record) = STATE_COLUMNS.find { record.has_attribute?(it) }&.then { [it, record[it]] }

  Action = Struct.new(:name, :params, :pause_at, :weight, :block, :failures, keyword_init: true)

  # An end drawn from its start: `ends_at: after(:starts_at, minutes: [...])`.
  # Drawn apart, nearly every pair broke a duration rule and the action was
  # only ever refused.
  After = Data.define(:from, :minutes) do
    def inspect = "after(:#{from}, minutes: #{minutes.inspect})"
  end

  class Definition
    attr_reader :name, :actions, :invariants, :refusal_classes, :pools, :zones, :clock_start, :ignore_columns, :tick_weight,
                :skipped, :failures, :twin_pairs

    def initialize(name, shared: true)
      @name = name
      @actions = {}
      @invariants = {}
      @pools = {}
      @refusal_classes = []
      @zones = []
      @clock_start = nil
      @ignore_columns = %w[created_at updated_at]
      @helpers = Module.new
      @skipped = {}
      @failures = {}
      @twin_pairs = []
      Sequences.shared.each { instance_exec(&it) } if shared
    end

    def setup(&block) = (@setup = block)
    def run_setup(ctx) = ctx.instance_exec(&@setup)
    def pool(name, &query) = (@pools[name] = query)
    def helpers(&block) = block ? @helpers.module_eval(&block) : @helpers

    # Every public method of these classes (the fakes of outside services) is
    # a pause point, so any action can be held at its first outside call.
    def outside_calls(*classes)
      Sequences.outside_classes_declared.merge(classes)
      classes.each do |klass|
        klass.public_instance_methods(false).each { Pause.define(:outside_call, klass, it) }
      end
      @default_pause = :outside_call
    end
    def refusals(*classes) = @refusal_classes.concat(classes)
    def invariant(name, &block) = (@invariants[name] = block)
    def ignore(*columns) = @ignore_columns.concat(columns.map(&:to_s))
    def after(from, minutes:) = After.new(from:, minutes:)

    # Two doors to one effect (a desk route and an API endpoint): run both
    # from the same state with the same inputs; the outcome and the rows of
    # +table+ must match.
    def twins(first, second, table:) = @twin_pairs << [first, second, table.to_s]

    # Starts the clock and turns on the boundary-biased tick rule and the
    # process time-zone replay.
    def clock(start:, zones: [], weight: 3.0)
      @clock_start = Time.utc(*start)
      @zones = zones
      @tick_weight = weight
    end

# An action with a :TODO param does not run; the report lists it with
# the params to fill, and the rest of the area still runs.
def action(name, pause_at: nil, weight: 1.0, failures: [], **params, &block)
  todo = params.select { |_, spec| spec == :TODO }.keys
  return @skipped[name] = "replace :TODO for #{todo.join(", ")}" if todo.any?

  @actions[name] = Action.new(name:, params:, pause_at:, weight:, block:, failures:)
  end

# How an outside service fails: the block arms the fake. An action that
# lists the failure runs once more as its own step with the fake armed.
def failure(name, &block) = (@failures[name] = block)

    def pausable = @actions.values.select { it.pause_at || @default_pause }
    def pause_point(action) = action.pause_at || @default_pause
  end

def self.define(name, &block)
  definition = Definition.new(name)
  definition.instance_exec(&block)
  registry[name] = definition
end

def self.registry = (@registry ||= {})
def self.[](name) = registry.fetch(name)

  # Days and hours the tick rule jumps to: the edges of a day in each zone,
  # month ends, and the 2026 daylight-saving changes.
  # Mid-day times too: with only day edges, an action that needs opening
  # hours was refused at every draw.
  BOUNDARY_TIMES = [[0, 0, 0], [0, 0, 1], [23, 59, 59], [12, 0, 0], [1, 30, 0], [9, 30, 0], [15, 0, 0]].freeze
  # The other ways to write the same instant, for the offset replay.
  OFFSETS = ["Z", "-08:00", "+13:00"].freeze
  ZONES_FOR_DAY_EDGES = ["UTC", "Pacific/Auckland", "America/Los_Angeles", "Asia/Tokyo"].freeze
  TEXTS = ["Sample text", "", "Ä 漢字 #{"x" * 40}"].freeze

  # What an action body sees as self: the world helpers and an HTTP session.
  class Context
    include ActiveSupport::Testing::TimeHelpers
    include FactoryBot::Syntax::Methods

    attr_reader :definition
    attr_accessor :sizer

    # How many of a record the world starts with, drawn per case (and shrunk).
    def world_size(name, range) = @sizer ? @sizer.call(name, range) : range.max

    def initialize(definition)
      @definition = definition
      extend(definition.helpers)
    end

    def http
      Thread.current[:sequences_http] ||= ActionDispatch::Integration::Session.new(Rails.application)
    end

    def records(pool) = @definition.pools.fetch(pool).call.to_a

    # A factory call that fails in `setup` names itself and its line.
    %i[create create_list build].each do |factory_call|
      define_method(factory_call) do |*args, **kw, &blk|
        super(*args, **kw, &blk)
      rescue SetupError
        raise
      rescue StandardError => e
        where = caller_locations.find { it.path.start_with?(Rails.root.to_s) && !it.path.start_with?(__dir__) && !it.path.include?("/spec/support/") }
        # A record's whole inspect pushed the error itself off the one line a
        # report shows, so a record is named by its class and id.
        show = ->(v) { v.is_a?(ActiveRecord::Base) ? "#<#{v.class.name} #{v.id || "new"}>" : v.inspect }
        call = (args.map(&show) + kw.map { |k, v| "#{k}: #{show.(v)}" }).join(", ")
        raise SetupError, "#{factory_call}(#{call}) at #{where&.path&.sub("#{Rails.root}/", "")}:#{where&.lineno} failed: #{e.class}: #{e.message}"
      end
    end
end

  # Draws parameter values (or reads them back from a log on replay).
  class Draw
    def initialize(tc) = (@tc = tc)

    def index(size) = int(0..size - 1)
    def int(range) = @tc.draw(Hegel::Generators::IntegerGenerator.new(min_value: range.min, max_value: range.max))
    def assume(ok) = @tc.assume(ok)
  end

  class Runner
    attr_reader :log

    def initialize(definition)
      @definition = definition
      @ctx = Context.new(definition)
      @log = []
      @clock = definition.clock_start
      @tracked = {}
    end

    # Builds the world. +sizes+ replays the world sizes a log recorded; +draw+
    # draws them; with neither, each size is its largest.
    def reset!(sizes: nil, draw: nil)
      Sequences.empty_tables
      FactoryBot.rewind_sequences if defined?(FactoryBot)
      queue = sizes&.dup
      world = []
      @ctx.sizer = lambda do |name, range|
        n = queue ? (queue.shift || range.min) : draw ? draw.int(range) : range.max
        n.clamp(range.min, range.max).tap { world << [name, it] }
      end
      begin
        at_clock { @definition.run_setup(@ctx) }
      rescue SetupError
        raise
      rescue StandardError => e
        where = e.backtrace.find { it.include?("/spec/") && !it.include?("/spec/support/") } || e.backtrace.first
        raise SetupError, "setup failed at #{where.sub("#{Rails.root}/", "")}: #{e.class}: #{e.message}"
      end
      @log = []
      @log << { step: :world, args: world.map(&:last), label: world.map { "#{_1} #{_2}" }.join(", ") } unless world.empty?
      check_invariants("after setup")
    end

    # Resolves an action's declared params with +draw+ (index into a pool, or
    # an integer), returning both the recorded choice and the value.
    def choose(action, draw)
      choice = {}
      action.params.each do |key, spec|
        case spec
        when :local_time, :local_date
          choice[key] = { zone: draw.int(0..ZONES_FOR_DAY_EDGES.size - 1), days: draw.int(-2..40),
                          time: draw.int(0..BOUNDARY_TIMES.size - 1) }
        when :text
          choice[key] = draw.int(0..TEXTS.size - 1)
        when After
          choice[key] = draw.index(spec.minutes.size)
        when Symbol
          rows = @ctx.records(spec)
          draw.assume(!rows.empty?)
          choice[key] = draw.index(rows.size)
        when Range
          choice[key] = draw.int(spec)
        when Array
          choice[key] = draw.index(spec.size)
        end
      end
      choice
    end

    # +offset+ writes every :local_time value as the same instant in another
    # UTC offset ("Z", "-08:00", ...).
    def resolve(action, choice, offset: nil)
      action.params.each_with_object({}) do |(key, spec), out|
        out[key] = case spec
                   when :local_time
                     time = local_time(choice[key])
                     offset.nil? ? time : offset == "Z" ? time.utc : time.getlocal(offset)
                   when :local_date then local_time(choice[key]).to_date
                   when :text then TEXTS.fetch(choice[key])
                   when After then out.fetch(spec.from) + spec.minutes.fetch(choice[key]).minutes
                   when Symbol
                     rows = @ctx.records(spec)
                     rows.fetch(choice[key]) { raise Diverged, "step #{@log.size + 1} (#{action.name}) needs #{spec} row #{choice[key] + 1}, and there are #{rows.size}" }
                   when Array then spec.fetch(choice[key])
                   else choice[key]
                   end
      end
    end

    # A wall-clock time in one of the zones, at a day edge, some days from now:
    # the input a member in another time zone would send.
    def local_time(choice)
      zone = ActiveSupport::TimeZone[ZONES_FOR_DAY_EDGES.fetch(choice[:zone])]
      day = (@clock || Time.current).in_time_zone(zone).to_date + choice[:days]
      h, m, sec = BOUNDARY_TIMES.fetch(choice[:time])
      zone.local(day.year, day.month, day.day, h, m, sec)
    end

    def describe(action, choice, offset: nil)
      resolve(action, choice, offset:).map do |k, v|
        "#{k}=#{v.is_a?(ActiveRecord::Base) ? "#{v.class.name}##{v.id}" : v.respond_to?(:iso8601) && !v.is_a?(Date) ? v.iso8601 : v}"
      end.join(" ")
    end

    # Runs the block and rolls back what it wrote: the rows, the id counters,
    # and the state of the fakes, so the step after it runs as if it had not.
    # The outer transaction is not joinable, so the app's own transactions
    # become savepoints, as under transactional tests.
    def trial
      saved = Sequences.save_outside_state
      result = nil
      ActiveRecord::Base.transaction(joinable: false) do
        result = yield
        raise ActiveRecord::Rollback
      end
      result
    ensure
      Sequences.restore_outside_state(saved) if saved
    end

    # What a step did, to compare two ways of running it: accepted or refused,
    # and the rows of +tables+ (every table when nil) without ids, times and
    # random tokens.
    def effect(outcome, tables = nil)
      rows = snapshot(tables).transform_values do |list|
        list.map { |row| row.reject { |col, _| col == "id" || col.match?(NOISE_COLUMN) } }
      end
      { accepted: !Sequences.kind(outcome).match?(/refused|HTTP 4/), outcome:, rows: }
    end

    NOISE_COLUMN = /(\A|_)(token|digest|uuid|nonce|secret|salt|key)\z|_at\z/

    # The same step with each :local_time param written as the same instant
    # in another UTC offset must answer and write the same.
    def offset_step(name, choice, offset)
      action = @definition.actions.fetch(name)
      label = "#{name}(#{describe(action, choice)}), then the same instant written as #{offset}: #{describe(action, choice, offset:)}"
      entry = { step: :offset, args: { action: name, args: choice, offset: }, at: @clock&.iso8601, label: }
      @log << entry
      at_clock do
        other = trial { effect(perform_with(action, resolve(action, choice, offset:))) }
        mine = effect(perform(action, choice))
        entry[:outcome] = mine[:outcome]
        Sequences.tally(:"#{name} [other offset]", mine[:outcome])
        compare!("the same instant in another UTC offset changed the result", mine, other, "as drawn", "as #{offset}")
      end
      check_invariants("after #{name} [other offset]")
    end

    # A desk action and an API action that make the same record, from the
    # same state with the same inputs, must agree.
    def twins_step(first_name, first_choice, second_name, second_choice, table)
      first = @definition.actions.fetch(first_name)
      second = @definition.actions.fetch(second_name)
      label = "#{first_name}(#{describe(first, first_choice)}) vs #{second_name}(#{describe(second, second_choice)}) from the same state"
      entry = { step: :twins, args: { first: first_name, first_args: first_choice, second: second_name, second_args: second_choice, table: },
                at: @clock&.iso8601, label: }
      @log << entry
      at_clock do
        one = trial { effect(perform(first, first_choice), [table]) }
        two = effect(perform(second, second_choice), [table])
        entry[:outcome] = "#{first_name} => #{one[:outcome]}; #{second_name} => #{two[:outcome]}"
        # A door that turned the caller away (not signed in, no token) never
        # reached the code; the pair compares nothing, and the report says
        # the pair was not reached.
        if [one, two].any? { Sequences.turned_away?(it[:outcome]) }
          Sequences.tally(:"#{first_name} = #{second_name}", "refused: turned away")
          next
        end
        Sequences.tally(:"#{first_name} = #{second_name}", one[:accepted] || two[:accepted] ? "ok" : "refused: both")
        # Rows only: a desk can answer a refusal with a notice where the API
        # answers 409, and both wrote nothing.
        compare!("two doors to #{table} disagree", one, two, first_name, second_name, outcome: false)
      end
      check_invariants("after #{first_name} = #{second_name}")
    end

    # The second door's inputs: a param of the same name and kind, or the one
    # param of the first that draws from the same pool, takes the same choice.
    # A pool param with no match (the API's caller) takes the owner of a
    # record the first door was given: the API acts as that record's member.
    def same_inputs(first, first_choice, second, draw)
      fresh = choose(second, draw)
      values = resolve(first, first_choice)
      given = values.values.grep(ActiveRecord::Base)
      second.params.to_h do |key, spec|
        # Same name, other draw list (attendees 0..5 and [0, 1, 2, 4, 12]), or
        # an end drawn from the start where the desk takes minutes: send the
        # same value, or skip this draw when the second door cannot.
        same = first.params.key?(key) ? key : (first.params.keys.find { it.to_s.match?(/minutes|duration/) } if spec.is_a?(After))
        if same && first.params[same] != spec
          mapped = choice_for(spec, values[same], values)
          draw.assume(!mapped.nil?)
          next [key, mapped]
        end
        from = first.params[key] == spec ? key : (first.params.select { |_, s| s == spec && s.is_a?(Symbol) }.keys.then { it.one? ? it.first : nil })
        next [key, first_choice[from]] if from
        next [key, fresh[key]] unless spec.is_a?(Symbol)

        rows = @ctx.records(spec)
        owner = given.flat_map do |record|
          record.class.reflect_on_all_associations(:belongs_to).reject(&:polymorphic?)
                .select { rows.first.is_a?(it.klass) }.map { record.public_send(it.foreign_key) }
        end.first
        at = owner && rows.index { it.id == owner }
        [key, at || fresh[key]]
      end
    end

    def choice_for(spec, value, values)
      case spec
      when Range then value if value.is_a?(Integer) && spec.cover?(value)
      when Array then spec.index(value)
      when After
        minutes = value.is_a?(Integer) ? value : ((value - values.fetch(spec.from)) / 60).round
        spec.minutes.index(minutes)
      end
    end

    def compare!(what, a, b, a_name, b_name, outcome: true)
      if outcome && a[:accepted] != b[:accepted]
        raise Failure.new("#{what}: #{a_name} #{a[:accepted] ? "accepted" : "refused"} (#{a[:outcome]}), #{b_name} #{b[:accepted] ? "accepted" : "refused"} (#{b[:outcome]})",
                          log: @log, definition: @definition)
      end
      diff = Sequences.diff(a[:rows], b[:rows], Set.new)
      return if diff.empty?

      raise Failure.new("#{what}: rows differ (#{a_name} => #{a[:outcome]}; #{b_name} => #{b[:outcome]})\n#{diff.first(6).map { it[:text] }.join("\n")}",
                        log: @log, definition: @definition)
    end

    def step(name, choice, failure: nil)
      action = @definition.actions.fetch(name)
      entry = { step: name, args: choice, at: @clock&.iso8601, label: describe(action, choice) }
      entry.merge!(failure:, label: "[#{failure}] #{entry[:label]}") if failure
      @log << entry
      $stderr.puts "  step #{entry[:step]} #{entry[:label]}" if ENV["SEQ_DEBUG"]
      entry[:outcome] = at_clock do
        @ctx.instance_exec(&@definition.failures.fetch(failure)) if failure
        perform(action, choice)
      end
      Sequences.tally(failure ? :"#{name} [#{failure}]" : name, entry[:outcome])
      check_invariants("after #{name}")
    end

    # Dates and times the app stored (due dates, deadlines, pauses), where a
    # day-boundary bug would show.
    # One query over every date column: a query per column on each tick
    # took a quarter of the run.
    def stored_dates
      conn = ActiveRecord::Base.connection
      @dates_sql ||= (conn.tables - %w[schema_migrations ar_internal_metadata]).flat_map do |table|
        conn.columns(table).select { %i[date datetime].include?(it.type) && !@definition.ignore_columns.include?(it.name) }.map do |column|
          "SELECT DISTINCT CAST(#{conn.quote_column_name(column.name)} AS date) AS d FROM #{conn.quote_table_name(table)} WHERE #{conn.quote_column_name(column.name)} IS NOT NULL"
        end
      end.join(" UNION ")
      return [] if @dates_sql.empty?

      conn.select_values(@dates_sql).map { it.respond_to?(:to_date) ? it.to_date : Date.parse(it.to_s) }.uniq.sort
    end

    def tick(choice)
      zone = ActiveSupport::TimeZone[ZONES_FOR_DAY_EDGES.fetch(choice[:zone])]
      dates = choice[:stored] ? stored_dates : []
      local = if dates.empty? then @clock.in_time_zone(zone).to_date + choice[:days]
              else dates.fetch(choice[:stored] % dates.size) + (choice[:days] % 3) - 1
              end
      h, m, s = BOUNDARY_TIMES.fetch(choice[:time])
      target = zone.local(local.year, local.month, local.day, h, m, s).utc
      target = @clock + 1 if target <= @clock
      @log << { step: :tick, args: choice, at: @clock&.iso8601, label: "clock -> #{target.iso8601} (#{zone.name} #{target.in_time_zone(zone).strftime("%F %T")})" }
      @clock = target
    end

    # Runs +first+ until it reaches its pause point, then runs +second+ to the
    # end (or until it blocks on a database lock), then lets +first+ finish.
    def interleave(first_name, first_choice, second_name, second_choice)
      first = @definition.actions.fetch(first_name)
      second = @definition.actions.fetch(second_name)
      entry = { step: :interleave, args: { first: first_name, first_args: first_choice, second: second_name, second_args: second_choice },
                at: @clock&.iso8601,
                label: "#{first_name}(#{describe(first, first_choice)}) paused at #{@definition.pause_point(first)}, then #{second_name}(#{describe(second, second_choice)})" }
      @log << entry
      $stderr.puts "  step #{entry[:step]} #{entry[:label]}" if ENV["SEQ_DEBUG"]
      # Records are resolved on the main thread, before either action runs.
      first_label, second_label = describe(first, first_choice), describe(second, second_choice)
      first_args = resolve(first, first_choice)
      second_args = resolve(second, second_choice)
      gate = { point: @definition.pause_point(first), paused: Queue.new, go: Queue.new, passed: false }
      outcomes = {}
      at_clock do
        t1 = Thread.new do
          Thread.current[:sequences_gate] = gate
          ActiveRecord::Base.connection_pool.with_connection { outcomes[:first] = perform_with(first, first_args) }
        ensure
          gate[:paused].push(:done)
        end
        reached = gate[:paused].pop
        second_args = onto_loaded(second_args, gate[:loaded]) if reached == true && gate[:loaded]
        t2 = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { outcomes[:second] = perform_with(second, second_args) }
        end
        blocked = t2.join(0.5).nil?
        between = !blocked && reached == true && gate[:loaded] ? current_states(gate[:loaded]) : nil
        gate[:go].push(true)
        [t1, t2].each { raise Failure.new("deadlock or hang in interleaving", log: @log, definition: @definition) unless it.join(10) }
        $stderr.puts "  interleave reached=#{reached.inspect} blocked=#{blocked} second=#{outcomes[:second].inspect} loaded=#{gate[:loaded].inspect} between=#{between.inspect}" if ENV["SEQ_DEBUG"] && reached == true
        stale_overwrite!(first_name, second_name, gate, between, outcomes[:second]) if between
        entry[:outcome] = { first: outcomes[:first], second: outcomes[:second],
                            paused: reached == true, second_blocked: blocked }
        Sequences.tally(:"interleave, first #{first_name}", reached == true ? (blocked ? "paused, second waited on a lock" : "paused") : "no outside call")
        # The first action never reached an outside call, so the two ran one
        # after the other. The entry stays an interleave so the repro resolves
        # both records before either runs, as this run did.
        unless reached == true
          entry[:label] = "#{first_name}(#{first_label}), then #{second_name}(#{second_label}); no outside call, so no pause"
          entry[:outcome] = { first: outcomes[:first], second: outcomes[:second] }
        end
      end
      check_invariants("after interleave")
    end

    # A job held after its batch load races only on the rows it loaded, so a
    # second action's record of the same class is moved onto one of them
    # (the first loaded, so a replay picks the same row).
    def onto_loaded(args, loaded)
      args.to_h do |key, value|
        row = value.is_a?(ActiveRecord::Base) && loaded.none? { |k, id, _| value.is_a?(k) && value.id == id } &&
              loaded.find { |k, _, _| value.is_a?(k) }
        [key, row ? row[0].unscoped.find_by(id: row[1]) || value : value]
      end
    end

    def current_states(loaded)
      loaded.to_h { |klass, id, _| [[klass, id], klass.unscoped.find_by(id:)&.then { Sequences.state_of(it) }] }
    end

    # A job that loaded a row before another action set its status must not
    # write a status over it that the job's own query would not have picked
    # the row for: that is the job acting on what it read, not on what is
    # there. The query is asked inside a rolled-back trial, with the row put
    # back at the status the other action set.
    def stale_overwrite!(job, other, gate, between, other_outcome)
      return if Sequences.kind(other_outcome).match?(/refused|HTTP 4/)

      gate[:loaded].each do |klass, id, (column, loaded)|
        next unless column

        set = between[[klass, id]]&.last
        now = klass.unscoped.find_by(id:)&.[](column)
        next if set.nil? || set == loaded || now == set

        picked = trial do
          klass.unscoped.where(id:).update_all(column => set)
          gate[:relation].except(:limit, :offset, :order).where(id:).exists?
        end
        next if picked

        raise Failure.new("#{job} loaded #{klass.name}##{id} with #{column} #{loaded.inspect}; #{other} set it to #{set.inspect} " \
                          "while #{job} held it; #{job} then wrote #{now.inspect}, though its own query does not select a row whose #{column} is #{set.inspect}",
                          log: @log, definition: @definition)
      end
    end

    def perform(action, choice) = perform_with(action, resolve(action, choice))

    def perform_with(action, args)
      Thread.current[:sequences_action] = action.name
      result = begin
        @ctx.instance_exec(**args, &action.block)
      ensure
        Thread.current[:sequences_action] = nil
      end
      return "ok" unless result.is_a?(Integer) && result.between?(100, 599)
      raise Failure.new("#{action.name} answered HTTP #{result}", log: @log, definition: @definition) if result >= 500

      # A flash set by the request before is still readable here, marked for
      # discard; only an alert this request set counts.
      flash = @ctx.http.flash if result.between?(300, 399)
      alert = flash[:alert] if flash && !flash.instance_variable_get(:@discard).include?("alert")
      body = @ctx.http.response&.body.to_s if result >= 400
      # The plain error page says only "400 Bad Request"; the exception the
      # request raised names the param.
      raised = @ctx.http.request&.env&.[]("action_dispatch.exception") if result >= 400
      body = raised.respond_to?(:param) ? "missing param #{raised.param}" : "#{raised.class.name}: #{raised.message}" if raised
      # An HTML error page says what went wrong in its title.
      body = body[%r{<title>(.*?)</title>}m, 1] || body if body&.lstrip&.start_with?("<")
      alert ||= body.strip[0, 80] if body && !body.strip.empty?
      alert ? "HTTP #{result} refused: #{alert}" : "HTTP #{result}"
    rescue *@definition.refusal_classes => e
      "refused: #{e.class.name}: #{e.message}"
    rescue Failure
      raise
    rescue StandardError => e
      raise Failure.new("#{action.name} raised #{e.class}: #{e.message}\n  #{e.backtrace.grep(%r{/app/}).first(3).join("\n  ")}", log: @log, definition: @definition)
    end

    def at_clock(&block)
      return yield unless @clock

      @ctx.travel_to(@clock, &block)
    end

    def check_invariants(where)
      Thread.current[:sequences_runner] = self
      @definition.invariants.each do |name, block|
        ok = at_clock { @ctx.instance_exec(&block) }
        next if ok == true || ok.nil?

        raise Failure.new("invariant #{name} broken #{where}: #{ok.inspect}", log: @log, definition: @definition)
      end
    end

    # Every row of every table, minus the columns the definition ignores, so
    # two runs of the same steps can be compared.
    # Rows that leave +from+ for one of +to+ leave it in the order they
    # entered it, as this run saw them enter (not as a column says). Only rows
    # alike in every column but ids and times are compared: any other
    # column (a party size, a pause date) can be a reason to skip a row.
    def order_kept(model, from:, to:, group: nil)
      table = model.table_name
      before = @tracked[table]
      now = model.unscoped.order(:id).map(&:attributes)
      @tracked[table] = now.to_h do |row|
        was = before&.[](row["id"])
        [row["id"], { status: row["status"], since: was && was[:status] == row["status"] ? was[:since] : @log.size, row: }]
      end
      return true unless before

      group = group&.to_s
      alike = model.column_names.reject { it == "id" || it == "status" || it.end_with?("_at") || (it.end_with?("_id") && it != group) || @definition.ignore_columns.include?(it) }
      broken = before.filter_map do |id, was|
        moved = @tracked[table][id]
        next unless was[:status] == from && moved && Array(to).include?(moved[:status])

        skipped = @tracked[table].find do |other_id, other|
          other_id != id && other[:status] == from && other[:since] < was[:since] &&
            (group.nil? || other[:row][group] == was[:row][group]) && alike.all? { other[:row][it] == was[:row][it] }
        end
        next unless skipped

        "#{table} #{id} (#{from} since step #{was[:since]}) became #{moved[:status]} while #{table} #{skipped[0]} " \
          "(#{from} since step #{skipped[1][:since]}, alike in #{alike.join(", ").presence || "every column"}) still waits"
      end
      broken.empty? || broken.join("; ")
    end

    def snapshot(only = nil)
      conn = ActiveRecord::Base.connection
      (only || (conn.tables - %w[schema_migrations ar_internal_metadata])).sort.to_h do |table|
        rows = conn.select_all("SELECT * FROM #{conn.quote_table_name(table)} ORDER BY id").to_a
        [table, rows.map { |row| row.except(*@definition.ignore_columns) }]
      end
    end

    def replay(entries)
      entries.each do |entry|
        @clock = Time.iso8601(entry[:at]) if entry[:at] && @clock
        case entry[:step]
        when :world then next
        when :tick then tick(entry[:args])
        when :offset then offset_step(entry[:args][:action], entry[:args][:args], entry[:args][:offset])
        when :twins
          a = entry[:args]
          twins_step(a[:first], a[:first_args], a[:second], a[:second_args], a[:table])
        when :interleave
          a = entry[:args]
          interleave(a[:first], a[:first_args], a[:second], a[:second_args])
        else step(entry[:step], entry[:args], failure: entry[:failure])
        end
      end
    end
  end

  module Report
    module_function

    def narrative(log)
      lines = log.each_with_index.map do |e, i|
        "  #{i + 1}. [#{e[:at]}] #{e[:step]} #{e[:label]}#{"  => #{e[:outcome]}" if e[:outcome] && e[:outcome] != "ok"}"
      end
      "Shortest sequence found:\n#{lines.join("\n")}"
    end

    def pasteable(definition, log)
      steps = log.map { |e| "      #{e.slice(:step, :args, :at, :failure).inspect}," }
      <<~RUBY
        Paste into the target's sequence spec to keep this case:

          it "keeps the case #{definition.name} found" do
            Sequences.replay(Sequences[#{definition.name.inspect}], [
        #{steps.join("\n")}
            ])
          end
      RUBY
    end
  end

  def self.machine_for(definition, runner)
    Class.new(Hegel::StateMachine) do
      definition.actions.each_value do |action|
        rule(action.name, weight: action.weight) do |tc|
          runner.step(action.name, runner.choose(action, Draw.new(tc)))
        end
      end
      definition.actions.each_value do |action|
        action.failures.select { definition.failures.key?(it) }.each do |failure|
          rule(:"#{action.name} [#{failure}]", weight: action.weight) do |tc|
            runner.step(action.name, runner.choose(action, Draw.new(tc)), failure:)
          end
        end
      end
      definition.actions.each_value do |action|
        next unless action.params.value?(:local_time)

        rule(:"#{action.name} [other offset]", weight: action.weight) do |tc|
          draw = Draw.new(tc)
          runner.offset_step(action.name, runner.choose(action, draw), OFFSETS.fetch(draw.index(OFFSETS.size)))
        end
      end
      definition.twin_pairs.each do |first_name, second_name, table|
        first = definition.actions[first_name] or next
        second = definition.actions[second_name] or next
        rule(:"#{first_name} = #{second_name}", weight: 1.0) do |tc|
          draw = Draw.new(tc)
          first_choice = runner.choose(first, draw)
          runner.twins_step(first_name, first_choice, second_name, runner.same_inputs(first, first_choice, second, draw), table)
        end
      end
      if definition.clock_start
        rule(:tick, weight: definition.tick_weight) do |tc|
          draw = Draw.new(tc)
          stored = draw.int(0..1).zero? ? nil : draw.int(1..1000)
          runner.tick(zone: draw.int(0..ZONES_FOR_DAY_EDGES.size - 1), days: draw.int(0..40),
                      time: draw.int(0..BOUNDARY_TIMES.size - 1), stored:)
        end
      end
      unless definition.pausable.empty?
        rule(:interleave, weight: 2.0) do |tc|
          draw = Draw.new(tc)
          # Hold first an action seen reaching an outside call, and run second
          # an action on the same record, so the race has something to race on.
          seen = definition.pausable.select { Sequences.outside_callers.include?(it.name) }
          firsts = (seen + definition.pausable.select { it.pause_at == :batch_load }).uniq
          firsts = definition.pausable if firsts.empty?
          first = firsts.fetch(draw.index(firsts.size))
          shared = definition.actions.values.select { (it.params.values & first.params.values).any? { |p| p.is_a?(Symbol) } }
          # A job held after its batch load races an action on one of the
          # rows it loaded, so the second is drawn from the record actions.
          shared = definition.actions.values.select { |a| a.params.values.any? { it.is_a?(Symbol) && definition.pools.key?(it) } } if first.pause_at == :batch_load
          seconds = draw.int(0..3).zero? || shared.empty? ? definition.actions.values : shared
          second = seconds.fetch(draw.index(seconds.size))
          first_choice = runner.choose(first, draw)
          second_choice = runner.choose(second, draw)
          second.params.each do |key, pool|
            first_key = first.params.key(pool)
            second_choice[key] = first_choice[first_key] if first_key && pool.is_a?(Symbol) && draw.int(0..3).positive?
          end
          runner.interleave(first.name, first_choice, second.name, second_choice)
        end
      end
    end
  end

  # Blocks every definition runs first: the invariants and refusals that
  # hold in every area, written once in spec/sequences/invariants.rb.
  COLLISION = /ExclusionViolation|UniqueViolation|RecordNotUnique|conflicting key value|duplicate key/
  TURNED_AWAY = /HTTP 40[13]|sign in|log in|signed in|unauthori[sz]ed|forbidden/i
  def self.turned_away?(outcome) = outcome.to_s.match?(TURNED_AWAY)

  def self.collision?(error) = error.message.match?(COLLISION)

  def self.shared = (@shared ||= [])
  def self.everywhere(&block) = shared << block

  # The RSpec entry point: generate sequences, shrink a failure, and fail the
  # example with the shortest sequence as a pasteable spec. SEQ_SEEDS=1,2,3
  # runs one seed after another and stops at the first failure.
  def self.explore(definition, **opts)
    ENV["SEQ_OBSERVE"] ? observe(definition, out: ENV["SEQ_OBSERVE"]) : explore_cases(definition, **opts)
  end

  def self.explore_cases(definition, test_cases: 100, step_count: 12, seed: nil)

    Rails.application.eager_load!
    quiet_errors
    seeds = ENV["SEQ_SEEDS"]&.split(",")&.map { Integer(it) } || [seed || Random.new_seed % 2**31]
    report = { area: definition.name, cases: test_cases, seeds: [], skipped: definition.skipped, actions: checks(definition),
              params: definition.actions.transform_values { it.params.keys } }
    # The world is built once before any case, so a broken setup stops here,
    # unshrunk, naming its line.
    begin
      Runner.new(definition).then { |runner| with_zone("UTC") { runner.reset! } }
    rescue SetupError => e
      raise unless collision?(e)
    end
    seeds.each do |current|
      report[:seeds] << explore_seed(definition, test_cases, step_count, current)
    end
    report[:verdict] = "clean"
  rescue SetupError => e
    report[:verdict] = "unchecked"
    report[:reason] = e.message
    raise
  rescue Exception => e # rubocop:disable Lint/RescueException
    report[:verdict] = "failure"
    report[:reason] = e.message.strip
    raise
  ensure
    tallies = @tallies&.transform_values(&:dup) || {}
    $stderr.puts coverage_report
    report[:reached] = tallies.transform_keys(&:to_s)
    report[:refused_with] = (@examples || {}).group_by { it[0][0] }.transform_values { |pairs| pairs.map(&:last).first(2) }
    @examples = nil
    File.write(ENV["SEQ_REPORT"], JSON.pretty_generate(report)) if ENV["SEQ_REPORT"]
    reset_database
  end

  # A behavior diff from inputs, not from changed methods: every ordering of
  # the area's actions up to SEQ_OBSERVE_LENGTH (3) steps, as many as
  # SEQ_OBSERVE_CAP (240) allows, each from the same world with arguments
  # drawn from a seed of its own. Each step writes one line: how it ended,
  # the rows it added, changed or removed (by attributes, no ids or times),
  # and the outside fakes whose state it changed. Run on base and on head,
  # the two files differ exactly where behavior does; nothing here judges.
  OBSERVE_NOISE = /\A(created_at|updated_at)\z|(\A|_)(token|digest|uuid|nonce|secret|salt)\z/

  def self.observe(definition, out:)
    Rails.application.eager_load!
    quiet_errors
    length = Integer(ENV.fetch("SEQ_OBSERVE_LENGTH", "3"))
    cap = Integer(ENV.fetch("SEQ_OBSERVE_CAP", "240"))
    names = definition.actions.keys.sort
    orders = (1..length).flat_map { |n| names.repeated_permutation(n).to_a }
    if orders.size > cap
      short = orders.select { it.size < length }
      orders = short.first(cap) + orders.select { it.size == length }.sample([cap - short.size, 0].max, random: Random.new(7))
    end
    File.open(out, "w") do |io|
      orders.each_with_index do |order, i|
        random = Random.new(1000 + i)
        runner = Runner.new(definition)
        begin
          with_zone("UTC") { runner.reset! }
        rescue SetupError => e
          io.puts JSON.generate({ area: definition.name, seq: order, index: i, step: 0, action: "(setup)", outcome: "setup failed: #{e.message.lines.first.strip}" })
          next
        end
        order.each_with_index do |name, k|
          action = definition.actions.fetch(name)
          choice = catch(:sequences_skip) { runner.choose(action, RandomDraw.new(random)) }
          line = { area: definition.name, seq: order, index: i, step: k + 1, action: name }
          if choice.nil?
            io.puts JSON.generate(line.merge(outcome: "skipped: a pool was empty"))
            next
          end
          before = runner.snapshot
          fakes = outside_digest
          line[:args] = (runner.describe(action, choice) rescue "?")
          line[:outcome] = begin
            with_zone("UTC") { runner.step(name, choice) && runner.log.last[:outcome] }
            runner.log.last[:outcome].to_s
          rescue Failure => e
            "failed: #{e.message.lines.first.strip}"
          rescue Diverged, StandardError => e
            "raised #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
          line[:writes] = row_changes(before, runner.snapshot)
          after = outside_digest
          line[:outside] = after.select { |id, (_, state)| fakes.key?(id) && fakes[id][1] != state }.map { it[1][0] }.uniq.sort
          io.puts JSON.generate(line)
        end
      end
    end
  ensure
    reset_database
  end

  # object id => [class name, state]. Keyed by object, not by class: fakes
  # of earlier cases stay in ObjectSpace until a GC, so a class key picked
  # an instance by heap order and the same step differed between two runs.
  def self.outside_digest
    outside_classes_declared.flat_map { |klass| ObjectSpace.each_object(klass).to_a }.to_h do |fake|
      [fake.object_id, [fake.class.name, fake.instance_variables.to_h { [it, fake.instance_variable_get(it).inspect] }.inspect]]
    end
  end

  # table => {"added" => [...], "changed" => [...], "removed" => [...]}, rows
  # by their non-volatile columns; ids appear only as the row they name.
  def self.row_changes(before, after)
    clean = ->(row) { row.reject { |c, _| OBSERVE_NOISE.match?(c) } }
    after.each_with_object({}) do |(table, rows), out|
      old = before.fetch(table, []).to_h { [it["id"], clean.(it)] }
      now = rows.to_h { [it["id"], clean.(it)] }
      added = now.reject { |id, _| old.key?(id) }.values
      removed = old.reject { |id, _| now.key?(id) }.values
      changed = now.filter_map do |id, row|
        next unless old.key?(id) && old[id] != row

        { "id" => id }.merge(row.select { |c, v| old[id][c] != v }.to_h { |c, v| [c, [old[id][c], v]] })
      end
      next if added.empty? && removed.empty? && changed.empty?

      out[table] = { "added" => added, "changed" => changed, "removed" => removed }.reject { _2.empty? }
    end
  end

  def self.explore_seed(definition, test_cases, step_count, seed)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count = 0
    first_failure = nil
    noise = Set.new
    shrink = !ENV["SEQ_NO_SHRINK"]
    Hegel.test(test_cases:, seed:, verbosity: :quiet,
               phases: shrink ? nil : %i[generate],
               suppress_health_check: %i[too_slow filter_too_much]) do |tc|
      count += 1
      begin
        run_case(definition, tc, step_count, noise)
      rescue Failure
        first_failure ||= [count, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
        raise
      end
    end
    { seed:, runs: count, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) }
  ensure
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    $stderr.puts "sequences #{definition.name} seed #{seed}: #{count} runs in #{elapsed.round(1)} s"
    if first_failure
      $stderr.puts "first failure at run #{first_failure[0]} after #{first_failure[1].round(1)} s" +
                   (shrink ? "; the rest shrank it" : "; not shrunk (SEQ_NO_SHRINK)")
    end
  end

  def self.run_case(definition, tc, step_count, noise)
    runner = Runner.new(definition)
    begin
      with_zone("UTC") { runner.reset!(draw: Draw.new(tc)) }
    rescue SetupError => e
      raise unless collision?(e)

      # Two drafted records met a unique index or an exclusion constraint:
      # the world's draw, not the app. The case is drawn again.
      tally(:setup, "collided, drawn again")
      tc.assume(false)
    end
    begin
      with_zone("UTC") { Hegel::Stateful.run(machine_for(definition, runner).new, tc, step_count:) }
    rescue Exception => e
      $stderr.puts "  case ended: #{e.class}: #{e.message[0, 200]} #{e.backtrace.first(6).join(" | ")}" if ENV["SEQ_DEBUG"]
      raise
    end
    return if definition.zones.empty?

    base = runner.snapshot
    zone = definition.zones.fetch(tc.draw(Hegel::Generators::IntegerGenerator.new(min_value: 0, max_value: definition.zones.size - 1)))
    # Under another zone an earlier step can end differently, so a later step
    # finds no record to act on. That is the zone changing the result.
    replayed = begin
      replay_snapshot(definition, runner.log, zone)
    rescue Diverged => e
      raise Failure.new("process time zone changed the result: TZ=UTC vs TZ=#{zone}\n#{e.message}", log: runner.log, definition:)
    end
    diff = diff(base, replayed, noise)
    return if diff.empty?

    # A column that differs between two UTC runs of the same steps (a random
    # token, a fake's charge id) says nothing about time zones.
    diff(base, replay_snapshot(definition, runner.log, "UTC"), Set.new).each { noise << it[:column] }
    diff = diff.reject { noise.include?(it[:column]) }
    return if diff.empty?

    raise Failure.new("process time zone changed the result: TZ=UTC vs TZ=#{zone}\n#{diff.first(6).map { it[:text] }.join("\n")}",
                      log: runner.log, definition: definition)
  end

  # What a clean verdict has to have reached: every action, its offset
  # replay, and each pair of doors.
  def self.checks(definition)
    definition.actions.keys +
      definition.actions.values.select { it.params.value?(:local_time) }.map { :"#{it.name} [other offset]" } +
      definition.twin_pairs.select { |a, b, _| definition.actions.key?(a) && definition.actions.key?(b) }.map { |a, b, _| :"#{a} = #{b}" }
  end

  # For a drafted invariant: see Runner#order_kept.
  def self.order_kept(model, **options) = Thread.current[:sequences_runner].order_kept(model, **options)

  def self.reached_outside_call(action, klass)
    return unless action

    outside_callers << action
    (@outside_classes ||= Hash.new { |h, k| h[k] = Set.new })[action] << klass
  end

  def self.outside_callers = (@outside_callers ||= Set.new)
  def self.outside_classes = (@outside_classes ||= Hash.new { |h, k| h[k] = Set.new })

  # What the run reached, so a clean result says what it covered: an action
  # that was only ever refused, or never drawn, checked nothing.
  def self.tally(name, outcome)
    kind = kind(outcome)
    (@tallies ||= Hash.new { |h, k| h[k] = Hash.new(0) })[name][kind] += 1
    (@examples ||= {})[[name.to_s, kind]] ||= outcome.to_s[0, 160] if kind.include?("refused")
  end

  def self.kind(outcome)
    kind = outcome.to_s[/\A(refused: [\w:]+|HTTP \d\d\d refused|HTTP \d|ok|paused, second waited on a lock|paused|no outside call)/] || outcome.to_s[0, 30]
    kind.sub(/HTTP (\d)(\d\d)?/, 'HTTP \1xx')
  end

  # Plain random draws for the probe: no shrinking, no Hegel.
  class RandomDraw
    def initialize(random) = (@random = random)
    def index(size) = @random.rand(size)
    def int(range) = @random.rand(range)
    def assume(ok) = ok || throw(:sequences_skip)
  end

  # A random walk over every action with no invariants: the tables each
  # action writes, the outside services it calls, and how it ends. propose.rb
  # groups actions into areas by it.
  def self.probe(definition, walks: 60, steps: 20, seed: 1)
    Rails.application.eager_load!
    quiet_errors
    random = Random.new(seed)
    stats = Hash.new { |h, k| h[k] = { writes: Hash.new(0), outcomes: Hash.new(0), errors: Hash.new(0), runs: 0 } }
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      name = Thread.current[:sequences_action] or next
      verb, table = payload[:sql].match(/\A\s*(INSERT INTO|UPDATE|DELETE FROM)\s+"?(\w+)"?/i)&.captures
      stats[name][:writes]["#{verb.split.first.downcase} #{table}"] += 1 if table
    end
    actions = definition.actions.values
    walks.times do
      runner = Runner.new(definition)
      with_zone("UTC") { runner.reset!(draw: RandomDraw.new(random)) }
      steps.times do
        if definition.clock_start && random.rand(5).zero?
          runner.tick(zone: random.rand(ZONES_FOR_DAY_EDGES.size), days: random.rand(0..20), time: random.rand(BOUNDARY_TIMES.size), stored: nil)
          next
        end
        # The first action, in random order, whose pools hold a record.
        action, choice = nil
        actions.shuffle(random:).each do |candidate|
          drawn = catch(:sequences_skip) { runner.choose(candidate, RandomDraw.new(random)) }
          next unless drawn

          action, choice = candidate, drawn
          break
        end
        next unless action

        begin
          stats[action.name][:runs] += 1
          with_zone("UTC") { runner.step(action.name, choice) }
          stats[action.name][:outcomes][kind(runner.log.last[:outcome])] += 1
        rescue Failure => e
          stats[action.name][:errors][e.cause ? e.cause.class.name : e.message.lines.first.strip[0, 80]] += 1
        end
      end
    end
    stats.each { |name, st| st[:outside] = outside_classes[name].map(&:name).sort }
    actions.each { stats[it.name] }
    stats
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
    @tallies = nil
    reset_database
  end

  def self.coverage_report
    return "" unless @tallies

    lines = @tallies.sort_by { |k, _| k.to_s }.map { |name, kinds| "  #{name}: #{kinds.map { |k, n| "#{k} #{n}" }.join(", ")}" }
    @tallies = nil
    return "" if lines.empty?
    "steps reached (outcome count):\n#{lines.join("\n")}"
  end

  def self.world_sizes(log) = log.find { it[:step] == :world }&.dig(:args) || []

  # The fakes are plain objects that remember charges and failures armed; a
  # trial's rollback must undo those too.
  def self.save_outside_state
    seqs = ActiveRecord::Base.connection.select_rows(sequence_state_sql)
    fakes = outside_classes_declared.flat_map { |klass| ObjectSpace.each_object(klass).to_a }.map do |fake|
      [fake, fake.instance_variables.to_h { [it, Marshal.load(Marshal.dump(fake.instance_variable_get(it)))] }]
    rescue TypeError
      nil
    end
    [seqs, fakes.compact]
  end

  def self.restore_outside_state((seqs, fakes))
    conn = ActiveRecord::Base.connection
    conn.execute(seqs.map { |name, value, called| "SELECT setval(#{conn.quote(name)}, #{Integer(value)}, #{called})" }.join("; ")) unless seqs.empty?
    fakes.each { |fake, ivars| ivars.each { fake.instance_variable_set(_1, _2) } }
  end

  def self.sequence_state_sql
    @sequence_state_sql ||= begin
      conn = ActiveRecord::Base.connection
      names = conn.select_values("SELECT sequencename FROM pg_sequences WHERE schemaname = current_schema()")
      names.map { "SELECT #{conn.quote(it)}, last_value, is_called FROM #{conn.quote_table_name(it)}" }.join(" UNION ALL ")
    end
  end

  def self.outside_classes_declared = (@outside_classes_declared ||= Set.new)

  def self.replay(definition, entries)
    Rails.application.eager_load!
    runner = Runner.new(definition)
    runner.reset!(sizes: world_sizes(entries))
    runner.replay(entries)
  ensure
    reset_database
  end

  def self.reset_database = empty_tables

  # A 404 or 422 renders the plain error page, not the developer page:
  # building that page (source extracts, error highlight) took a third of
  # the run. The status the action answers is unchanged.
  def self.quiet_errors = Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false

  # Empties every table and restarts its ids, so two runs of the same steps
  # get the same ids. DELETE in foreign-key order (children first) took 1 ms
  # on this app's few rows where TRUNCATE ... RESTART IDENTITY took 72 ms.
  # A schema whose keys form a cycle falls back to TRUNCATE.
  def self.empty_tables
    conn = ActiveRecord::Base.connection
    @empty_sql ||= begin
      tables = conn.tables - %w[schema_migrations ar_internal_metadata]
      parents = tables.to_h { |t| [t, conn.foreign_keys(t).map(&:to_table) - [t]] }
      order = []
      left = tables.dup
      until left.empty?
        leaves = left.reject { |t| left.any? { |other| parents[other].include?(t) } }
        break if leaves.empty?

        order.concat(leaves)
        left -= leaves
      end
      seqs = conn.select_rows("SELECT pg_get_serial_sequence(quote_ident(t), 'id') FROM unnest(ARRAY[#{tables.map { conn.quote(it) }.join(",")}]::text[]) t").flatten.compact
      if left.empty?
        (order.map { "DELETE FROM #{conn.quote_table_name(it)}" } + seqs.map { "SELECT setval(#{conn.quote(it)}, 1, false)" }).join("; ")
      else
        "TRUNCATE #{tables.map { conn.quote_table_name(it) }.join(", ")} RESTART IDENTITY CASCADE"
      end
    end
    conn.execute(@empty_sql)
  end


  def self.with_zone(zone)
    old = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    ENV["TZ"] = old
  end

def self.replay_snapshot(definition, log, zone)
  runner = Runner.new(definition)
  with_zone(zone) do
    runner.reset!(sizes: world_sizes(log))
    runner.replay(log)
    runner.snapshot
  end
end

def self.diff(a, b, noise)
  a.flat_map do |table, rows|
    other = b.fetch(table)
    next [{ column: table, text: "#{table}: #{rows.size} rows vs #{other.size} rows" }] if rows.size != other.size

    rows.zip(other).flat_map do |x, y|
      x.filter_map do |col, v|
        next if v == y[col] || noise.include?("#{table}.#{col}")

        { column: "#{table}.#{col}", text: "#{table}##{x["id"]}.#{col}: #{v.inspect} vs #{y[col].inspect}" }
      end
    end
  end
end
end
