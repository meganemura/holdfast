# Written by `holdfast check` next to the specs it generates
# (spec/holdfast/<branch>/holdfast_check.rb), so a kept spec needs nothing else.
# A suspicion example builds its world from the app's factories, runs one
# action (or two, interleaved), and fails when `expect` does not hold. When
# HOLDFAST_CHECK_OUT is set it also writes what it saw there as JSON, so
# holdfast can tell a failed expectation from a world it could not build.
require "json"

module HoldfastCheck
  # The world or the action could not be run; nothing was checked. +absent+
  # names the method, constant, attribute or route that does not exist, so a
  # base that predates a feature reads as that, not as a failure.
  class CouldNotRun < StandardError
    attr_reader :phase, :absent

    def initialize(phase, message, absent: nil)
      @phase = phase
      @absent = absent
      super(message)
    end
  end

  # The points a race can hold its first action at. A named point holds the
  # first time the held action passes it; `Class#method` is the fifth kind.
  POINTS = {
    "batch_load" => "its first query that returns rows",
    "outside_call" => "its first call to an outside-service client, or to a module method the suspicion stubs",
    "row_lock" => "its first with_lock or lock!, before the lock is taken",
    "first_write" => "its first INSERT, UPDATE or DELETE"
  }.freeze
  # With no pause named, or batch_load named and never reached, these are
  # tried in turn until one breaks `expect` in a way no serial order does.
  FALLBACKS = %w[outside_call row_lock first_write].freeze

  def self.hold(gate, point, at)
    return unless gate && gate[:point] == point && !gate[:passed]

    gate[:passed] = true
    gate[:held_at] = at
    gate[:paused].push(true)
    gate[:go].pop
  end

  def self.gate = Thread.current[:holdfast_gate]

  module BatchGate
    def records
      depth = Thread.current[:holdfast_load_depth].to_i
      Thread.current[:holdfast_load_depth] = depth + 1
      rows = begin
        super
      ensure
        Thread.current[:holdfast_load_depth] = depth
      end
      HoldfastCheck.hold(HoldfastCheck.gate, "batch_load", "#{klass.name} load (#{rows.size} rows)") if depth.zero? && rows.any?
      rows
    end
  end
  ActiveRecord::Relation.prepend(BatchGate)

  module LockGate
    def with_lock(...)
      HoldfastCheck.hold(HoldfastCheck.gate, "row_lock", "#{self.class.name}##{id} with_lock")
      super
    end

    def lock!(...)
      HoldfastCheck.hold(HoldfastCheck.gate, "row_lock", "#{self.class.name}##{id} lock!")
      super
    end
  end
  ActiveRecord::Base.prepend(LockGate)

  module WriteGate
    %i[insert update delete].each do |verb|
      define_method(verb) do |arel, name = nil, *rest, **kw, &blk|
        HoldfastCheck.hold(HoldfastCheck.gate, "first_write", "#{verb.to_s.upcase} (#{name || "sql"})")
        super(arel, name, *rest, **kw, &blk)
      end
    end
  end

  def self.watch_writes
    adapter = ActiveRecord::Base.connection.class
    adapter.prepend(WriteGate) unless adapter <= WriteGate
  end

  # The outside-service fakes: a module that holds a client
  # (`PaymentGateway.client = FakePaymentGateway.new`).
  def self.client_holders
    ObjectSpace.each_object(Module).select { _1.name && _1.instance_variable_defined?(:@client) && _1.instance_variable_get(:@client) }
  end

  # Each order of a race starts from the same outside fakes: each client
  # gets its instance variables back as they were before the first.
  def self.clients
    client_holders.filter_map do |mod|
      client = mod.instance_variable_get(:@client)
      [client, client.instance_variables.to_h { [_1, Marshal.dump(client.instance_variable_get(_1))] }]
    rescue TypeError
      nil
    end
  end

  def self.restore(saved) = saved.each { |client, ivars| ivars.each { client.instance_variable_set(_1, Marshal.load(_2)) } }

  def self.watch_outside_calls
    client_holders.each do |mod|
      client = mod.instance_variable_get(:@client)
      next if client.singleton_class.include?(OutsideGate)

      verbs = client.class.public_instance_methods(false)
      label = client.class.name
      gate = Module.new do
        verbs.each do |verb|
          define_method(verb) do |*args, **kw, &blk|
            HoldfastCheck.hold(HoldfastCheck.gate, "outside_call", "#{label}##{verb}")
            super(*args, **kw, &blk)
          end
        end
      end
      client.singleton_class.include(OutsideGate)
      client.singleton_class.prepend(gate)
    end
  end
  OutsideGate = Module.new

  # A service the suspicion stubs on a module (`allow(LockerApi).to
  # receive(:register)`) is an outside call too, and `pause:
  # LockerApi.register` names it. RSpec's stub sits in front of any hook
  # prepended to the module, so the hold is on the stub's own invocation.
  module StubGate
    private

    def invoke_incrementing_actual_calls_by(*args, &block)
      if orig_object.is_a?(Module) && orig_object.name
        gate = HoldfastCheck.gate
        HoldfastCheck.hold(gate, "outside_call", "#{orig_object.name}.#{message}")
        HoldfastCheck.hold(gate, "#{orig_object.name}.#{message}", "#{orig_object.name}.#{message}")
      end
      super
    end
  end
  # rspec-mocks loads when the first example runs, after this file.
  def self.watch_stubs
    return unless defined?(RSpec::Mocks::MessageExpectation)

    RSpec::Mocks::MessageExpectation.prepend(StubGate) unless RSpec::Mocks::MessageExpectation <= StubGate
  end

  def self.method_gate(point)
    @method_gates ||= {}
    return if @method_gates[point]

    owner, sep, name = point.rpartition(/[#.]/)
    raise CouldNotRun.new("pause", "pause #{point.inspect}: name it as #{POINTS.keys.join(", ")}, Class#method or Class.method") if owner.empty?

    klass = Object.const_get(owner)
    target = sep == "." ? klass.singleton_class : klass
    hook = Module.new do
      define_method(name) do |*args, **kw, &blk|
        HoldfastCheck.hold(HoldfastCheck.gate, point, point)
        super(*args, **kw, &blk)
      end
    end
    target.prepend(hook)
    @method_gates[point] = true
  rescue NameError => e
    raise CouldNotRun.new("pause", "pause #{point.inspect}: #{e.message}", absent: HoldfastCheck.absent(e))
  end

  # A NameError for a missing constant or method on a real object, an
  # unknown attribute or column, or a route that does not exist: what a tree
  # shows when it predates the feature the suspicion is about. A method
  # called on nil is a bug, not an absence. The attribute errors come first:
  # both are NoMethodErrors with no name and no receiver.
  def self.absent(error)
    case error
    when ActionController::RoutingError then "no route: #{error.message.lines.first.strip}"
    when ActiveModel::UnknownAttributeError then "no column #{error.attribute} on #{error.record.class.name}"
    when ActiveModel::MissingAttributeError
      # Only a write: "missing attribute" on a read is a column the query did
      # not select, which the tree has.
      name = error.message[/\Acan't write unknown attribute [`'"]?(\w+)/, 1]
      "no column #{name}#{" on #{error.instance_variable_get(:@holdfast_owner)}" if error.instance_variable_get(:@holdfast_owner)}" if name
    when NoMethodError
      receiver = begin
        error.receiver
      rescue ArgumentError
        NO_RECEIVER
      end
      if error.name && !receiver.equal?(NO_RECEIVER)
        "no method #{error.name} on #{receiver.is_a?(Module) ? receiver.name : receiver.class.name}" unless receiver.nil?
      elsif (m = error.message.match(/undefined method ['`]([^']+)' for (?:an instance of |class |module )?(\S+)/)) && m[2] != "nil"
        "no method #{m[1]} on #{m[2]}"
      end
    when NameError then "no constant #{error.name}" if error.message.start_with?("uninitialized constant")
    when ActiveRecord::StatementInvalid
      return unless error.cause.class.name.to_s.end_with?("UndefinedColumn", "UndefinedTable")

      case error.message
      when /column "?(\w+)"? of relation "(\w+)" does not exist/ then "no column #{$1} on #{$2}"
      when /column (\w+)\.(\w+) does not exist/ then "no column #{$2} on #{$1}"
      when /column "(\w+)" does not exist/ then "no column #{$1}"
      when /relation "(\w+)" does not exist/ then "no table #{$1}"
      else "no column or table: #{error.message.lines.first.strip[0, 160]}"
      end
    end
  end
  NO_RECEIVER = Object.new.freeze

  # update_columns writes past the attribute methods, so its error names the
  # column but not the record; the class is kept on the error for `absent`.
  module ColumnOwner
    def update_columns(...)
      super
    rescue ActiveModel::MissingAttributeError => e
      e.instance_variable_set(:@holdfast_owner, self.class.name)
      raise
    end
  end
  ActiveRecord::Base.prepend(ColumnOwner)

  # One record per factory call. A record made earlier fills a belongs_to
  # the attributes leave out, so `member` then `loan` is that member's loan.
  # Inside `given`, an earlier record is read by its name. A given written
  # as Ruby may return any value; only records are read again.
  class World
    attr_reader :records

    def initialize(example) = (@example = example) && (@records = {})

    def make(name, factory: name, traits: [], **attrs)
      klass = FactoryBot.factories.find(factory).build_class
      klass.reflect_on_all_associations(:belongs_to).each do |assoc|
        next if assoc.polymorphic? || assoc.options[:optional] || attrs.key?(assoc.name) || attrs.key?(assoc.foreign_key.to_sym)

        made = linkable.find { _1.is_a?(assoc.klass) }
        attrs[assoc.name] = made if made
      end
      @records[name] = FactoryBot.create(factory, *traits, **attrs)
    rescue StandardError => e
      shown = attrs.map { |k, v| "#{k}: #{v.is_a?(ActiveRecord::Base) ? "#{v.class.name}##{v.id}" : v.inspect}" }.join(", ")
      raise CouldNotRun.new("given", "given.#{name} (factory :#{factory}#{", #{shown}" unless shown.empty?}): #{e.class}: #{e.message.lines.first.to_s.strip}",
                            absent: HoldfastCheck.absent(e))
    end

    # A given written as Ruby: the block returns the record (or any value).
    def build(name, text, &block)
      @records[name] = instance_exec(&block)
    rescue StandardError => e
      raise CouldNotRun.new("given", "given.#{name} (#{text}): #{e.class}: #{e.message.lines.first.to_s.strip}", absent: HoldfastCheck.absent(e))
    end

    # The records made so far, newest first, then what each belongs to, so a
    # hold made after a copy gets that copy's book.
    def linkable
      made = @records.values.flatten.grep(ActiveRecord::Base).reverse
      made + made.flat_map { |r| r.class.reflect_on_all_associations(:belongs_to).reject(&:polymorphic?).filter_map { r.public_send(_1.name) } }
    end

    def fresh = @records.transform_values { |r| r.is_a?(Array) ? r.map { reload(_1) } : reload(r) }
    def reload(value) = value.is_a?(ActiveRecord::Base) && value.persisted? ? (value.class.unscoped.find_by(id: value.id) || value) : value
    def method_missing(name, *args, **kw, &blk) = @records.key?(name) && args.empty? ? @records[name] : @example.send(name, *args, **kw, &blk)
    def respond_to_missing?(name, all = false) = @records.key?(name) || @example.respond_to?(name, true)
  end

  # What `do` and `expect` see: each given record by its name (read again
  # from the database), `result` and `error` (of the one action, or of the
  # last in a race), `results` and `errors` (one per action, in the order the
  # suspicion lists them), `calls(X, :verb)`, and everything the spec has.
  class Scope
    def initialize(example, records, result: nil, error: nil, results: [], errors: [], calls: nil)
      @example, @records, @result, @error, @results, @errors, @calls = example, records, result, error, results, errors, calls
    end

    attr_reader :result, :error, :results, :errors

    OWN = %i[@example @records @result @error @results @errors @calls].freeze

    # The instance variables a `do` set, so `expect` reads `@payment` as
    # `do` left it (a record read again).
    def own_ivars = instance_variables - OWN
    def take_ivars(from, world) = from.own_ivars.each { instance_variable_set(_1, world.reload(from.instance_variable_get(_1))) }

    def calls(owner, verb) = @calls.of(owner, verb)
    def method_missing(name, *args, **kw, &blk) = @records.key?(name) && args.empty? ? @records[name] : @example.send(name, *args, **kw, &blk)
    def respond_to_missing?(name, all = false) = @records.key?(name) || @example.respond_to?(name, true)
  end

  # Every call to one method of an outside service's client (`PaymentGateway`
  # and `PaymentGateway.client` both name it), counted from the action on.
  class Calls
    def initialize(specs) = (@specs = specs) && (@seen = Hash.new { |h, k| h[k] = [] })

    def watch
      @specs.each do |owner, verb|
        target = owner.respond_to?(:client) ? owner.client : owner
        seen = @seen
        key = [owner.name, verb.to_sym]
        # "no PaymentGateway charges" names the method `charge`.
        verb = verb.to_s.chomp("s") if !target.respond_to?(verb) && target.respond_to?(verb.to_s.chomp("s"))
        raise CouldNotRun.new("expect", "#{owner.name} has no method #{verb} to count (#{target.class.name})") unless target.respond_to?(verb)
        target.singleton_class.prepend(Module.new do
          define_method(verb) do |*args, **kw, &blk|
            seen[key] << (kw.empty? ? args : args + [kw])
            super(*args, **kw, &blk)
          end
        end)
      end
    end

    def of(owner, verb) = @seen[[owner.name, verb.to_sym]]
  end

  # An action or an expectation line, as the suspicion wrote it. +parts+ are
  # the operands of `a && b` (or `a || b`), each [text, block, observe].
  Act = Data.define(:text, :block)
  Expect = Data.define(:text, :observe, :parts, :block)

  def act(text, &block) = Act.new(text:, block:)
  def expectation(text, observe: nil, parts: [], &block) = Expect.new(text:, observe:, parts:, block:)

  # Runs one suspicion: +given+ makes the records (in a World), +acts+ is one
  # action or two (a race at +pause+), +expects+ must all hold afterwards.
  # +calls+ lists the outside-service methods `expect` counts. +shared+ is
  # the example's binding, which holds the locals `do` sets and `expect` reads.
  def holdfast_suspicion(id, given:, acts:, expects:, calls: [], pause: nil, errors: false, shared: nil)
    report = { "id" => id }
    if acts.size == 1
      report.merge!(holdfast_once(given, acts, [0], expects, calls, pause: nil, errors:, shared:))
    else
      report.merge!(holdfast_race(given, acts, expects, calls, pause, shared))
    end
  rescue CouldNotRun => e
    report.merge!({ "result" => "could_not_run", "phase" => e.phase, "error" => e.message, "absent" => e.absent }.compact)
  rescue StandardError, ScriptError => e
    report.merge!("result" => "could_not_run", "phase" => "spec", "error" => HoldfastCheck.first_lines(e))
  ensure
    holdfast_truncate if acts.size > 1
    holdfast_write(report)
    case report["result"]
    when "could_not_run" then raise CouldNotRun.new(report["phase"], report["error"])
    when "confirmed" then raise RSpec::Expectations::ExpectationNotMetError, "suspicion confirmed: #{report["why"]}"
    end
  end

  # The error's first line and the line of the kept spec it came from, so a
  # row never reads ": ".
  def self.first_lines(error)
    frames = Array(error.backtrace)
    spec = frames.find { _1.match?(%r{spec/holdfast/(?:[\w.-]+/)?\w+_spec\.rb:\d+}) }
    own = frames.first.to_s.include?("holdfast_check.rb") ? " (inside holdfast: #{frames.first[%r{holdfast_check\.rb:\d+}]})" : ""
    at = if spec && (m = spec.match(%r{(\S*spec/holdfast/(?:[\w.-]+/)?\w+_spec\.rb):(\d+)}))
           text = (File.readlines(m[1])[m[2].to_i - 1].to_s.strip rescue "")
           " at #{m[1][%r{spec/holdfast/.*}]}:#{m[2]} `#{text[0, 160]}`"
         end
    "#{error.class}: #{error.message.lines.first.to_s.strip}#{own}#{at}"
  end

  def holdfast_race(given, acts, expects, calls, pause, shared)
    Rails.application.eager_load!
    HoldfastCheck.watch_writes
    HoldfastCheck.watch_stubs
    named = pause && pause != "batch_load"
    HoldfastCheck.method_gate(pause) if named && !POINTS.key?(pause)
    points = named ? [pause] : ["batch_load", *FALLBACKS]
    clients = HoldfastCheck.clients
    fresh_run = lambda do |order, point, trace: false|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      holdfast_truncate
      HoldfastCheck.restore(clients)
      holdfast_once(given, order.map { acts[_1] }, order, expects, calls, pause: point, errors: true, trace:, shared:)
        .merge("seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2))
    end
    orders = { "first then second" => fresh_run.([0, 1], nil, trace: true), "second then first" => fresh_run.([1, 0], nil, trace: true) }
    tried = []
    verdict = nil
    points.each do |point|
      held = {
        "first held at #{point}, second runs" => fresh_run.([0, 1], point),
        "second held at #{point}, first runs" => fresh_run.([1, 0], point)
      }
      reached = held.values.any? { _1["held_at"] }
      tried << "#{point}: #{reached ? held.values.filter_map { _1["held_at"] }.uniq.join(", ") : "not reached"}"
      next unless reached

      verdict = holdfast_race_verdict(orders, held, point)
      orders.merge!(held)
      break if verdict["result"] == "confirmed" || pause == point
    end
    candidates = orders.values_at("first then second", "second then first").flat_map { Array(_1["called"]) }.uniq.first(8)
    unless verdict
      return { "result" => "could_not_run", "phase" => "pause", "orders" => orders, "pauses" => tried,
               "error" => "no action reached #{points.join(", ")}; name a method the first action calls as `pause: Class#method`#{"; candidates: #{candidates.join(", ")}" if candidates.any?}" }
    end

    orders.each_value { _1.delete("called") }
    if verdict["result"] == "refuted"
      used = tried.reject { _1.end_with?("not reached") }
      verdict = verdict.merge("why" => verdict["serial_fails"] ? "#{verdict["why"]} (held at #{used.join("; ")})" : "each interleaving ended as a serial order ends (held at #{used.join("; ")})")
    end
    verdict.merge("orders" => orders, "pauses" => tried)
  end

  def holdfast_once(given, acts, positions, expects, call_specs, pause:, errors:, trace: false, shared: nil)
    world = World.new(self)
    world.instance_exec(&given)
    given_ids = world.records.values.flatten.grep(ActiveRecord::Base).map { "#{_1.class.name}##{_1.id}" }
    # A race runs its actions once per order; no order reads the locals the
    # order before it left.
    shared&.local_variables&.each { shared.local_variable_set(_1, nil) }
    calls = Calls.new(call_specs | HoldfastCheck.counted(expects))
    calls.watch
    HoldfastCheck.watch_outside_calls if pause
    called = []
    outcomes = if pause
                 holdfast_interleave(world, acts, pause)
               else
                 acts.map { |a| holdfast_traced(trace ? called : nil) { holdfast_step(world.fresh, a, errors:) } }
               end
    holdfast_reached!(expects)
    results = Array.new(acts.size)
    errs = Array.new(acts.size)
    positions.each_with_index do |pos, i|
      results[pos] = outcomes[i][:result]
      errs[pos] = outcomes[i][:error]
    end
    scope = Scope.new(self, world.fresh, result: outcomes.last[:result], error: outcomes.map { _1[:error] }.compact.first, results:, errors: errs, calls:)
    outcomes.each { scope.take_ivars(_1[:scope], world) if _1[:scope] }
    shared&.local_variables&.each { shared.local_variable_set(_1, world.reload(shared.local_variable_get(_1))) }
    checked = expects.map { holdfast_expect(scope, _1) }
    why = checked.reject { _1["holds"] }.map { "#{_1["expect"]} does not hold#{": #{_1["failed"].join("; ")}" if _1["failed"]}#{" (observed #{_1["observed"]})" if _1["observed"]}" }.join("; ")
    { "result" => why.empty? ? "refuted" : "confirmed", "why" => (why unless why.empty?),
      "outcomes" => outcomes.map { _1[:shown] }, "ends" => results.zip(errs).map { |r, e| e ? "raised #{e.class}" : holdfast_show(r) }, "paused" => outcomes.first[:paused], "held_at" => outcomes.first[:held_at],
      "absent" => outcomes.filter_map { _1[:absent] }.first, "checks" => checked, "called" => (called.uniq if trace), "given_ids" => given_ids }.compact
  end

  # Ruby expectations that name `calls(X, :verb)` count those calls too.
  def self.counted(expects)
    expects.flat_map { |e| e.text.scan(/calls\(\s*([A-Z][\w:]*)\s*,\s*:(\w+)\s*\)/) }.uniq.filter_map do |owner, verb|
      [Object.const_get(owner), verb]
    rescue NameError
      nil
    end
  end

  # A compound expectation that fails names each operand that failed and
  # what it saw, instead of the whole line.
  def holdfast_expect(scope, e)
    seen = begin
      e.observe && scope.instance_exec(&e.observe)
    rescue StandardError => err
      "#{err.class}: #{err.message}"
    end
    holds = begin
      scope.instance_exec(&e.block) ? true : false
    rescue StandardError => err
      # A value that is nil because the action raised (no response, no
      # result) is how the action ended, not a mistake in the suspicion.
      raised = scope.error || scope.errors.compact.first
      if raised && err.is_a?(NoMethodError) && (err.receiver rescue :none).nil?
        needs = HoldfastCheck.receiver_of(e.text, err.name) || "a value"
        return { "expect" => e.text, "holds" => false, "observed" => "do raised #{holdfast_show(raised)}",
                 "failed" => ["do raised #{raised.class}; expect needs #{needs}, which is nil after the raise"] }
      end
      raise CouldNotRun.new("expect", "expect #{e.text.inspect}: #{err.class}: #{err.message.lines.first.to_s.strip}", absent: HoldfastCheck.absent(err))
    end
    failed = unless holds || e.parts.empty?
               e.parts.filter_map do |text, block, observe|
                 ok = (scope.instance_exec(&block) rescue false)
                 next if ok

                 value = begin
                   observe ? scope.instance_exec(&observe) : ok
                 rescue StandardError => err
                   err
                 end
                 "`#{text}` fails (observed #{holdfast_show(value)})"
               end
             end
    { "expect" => e.text, "holds" => holds, "observed" => (holdfast_show(seen) if e.observe), "failed" => failed }.compact
  end

  # The receiver of the first call to +name+ in an expectation: `response`
  # in `response.status == 200`.
  def self.receiver_of(text, name)
    walk = ->(n) { [n, *n.compact_child_nodes.flat_map(&walk)] }
    walk.(Prism.parse(text).value).find { _1.is_a?(Prism::CallNode) && _1.name == name && _1.receiver }&.receiver&.slice
  end

  # The app methods an action called, in order, so a race whose pause point
  # nobody reached can name where to pause instead.
  def holdfast_traced(called)
    return yield unless called

    root = "#{Rails.root}/app/"
    tp = TracePoint.new(:call) do |t|
      next unless t.path.start_with?(root) && called.size < 40

      owner = t.defined_class
      owner = owner.attached_object if owner.singleton_class?
      called << "#{owner.name}#{t.defined_class.singleton_class? ? "." : "#"}#{t.method_id}" if owner.name
    end
    tp.enable(target_thread: Thread.current) { yield }
  end

  # A request that matched no route, or that the app turned away before it
  # reached any code (401, 403), checked nothing the suspicion is about,
  # unless `expect` names that status. A 404 the app itself answered (a
  # record it did not find) is how the request ended.
  def holdfast_reached!(expects)
    res = respond_to?(:response) && @integration_session && response
    return unless res.respond_to?(:status) && [401, 403, 404].include?(res.status)
    return if expects.any? { _1.text.include?(res.status.to_s) }

    req = request
    verb, path = req.request_method, req.path
    raised = req.env["action_dispatch.exception"]
    if res.status == 404 && (raised.is_a?(ActionController::RoutingError) || (raised.nil? && !HoldfastCheck.route?(verb, path)))
      near = HoldfastCheck.routes.select { |v, p| v == verb && p.split("/").last(1) == path.split("/").last(1) }.map { "#{_1} #{_2}" }.first(3)
      raise CouldNotRun.new("do", "#{verb} #{path} matches no route#{"; routes that end the same: #{near.join(", ")}" if near.any?}",
                            absent: "no route #{verb} #{path}")
    end
    raise CouldNotRun.new("do", "#{verb} #{path} answered #{res.status} (#{res.body.to_s[0, 120]}); sign in or send the token in `do`, or name #{res.status} in `expect`") if res.status != 404
  end

  # Rails routes and Grape endpoints, as [verb, path pattern].
  def self.routes
    @routes ||= begin
      rails = Rails.application.routes.routes.filter_map do |r|
        next if r.verb.to_s.empty? && r.app.respond_to?(:app)

        [r.verb.to_s, r.path.spec.to_s.sub("(.:format)", "")]
      end
      grape = defined?(Grape::API) ? ObjectSpace.each_object(Class).select { _1 < Grape::API::Instance rescue false }.flat_map { |api| api.routes.map { [_1.request_method, _1.path.sub("(.json)", "").sub("(.:format)", "")] } } : []
      (rails + grape).uniq
    end
  end

  def self.route?(verb, path)
    routes.any? do |v, pattern|
      next false unless v.split("|").include?(verb) || v.empty?

      Regexp.new("\\A#{Regexp.escape(pattern).gsub(/:\w+/, "[^/]+")}\\z").match?(path)
    end
  end

  # An error the app's own code raised (a refusal, a nil it did not expect)
  # is how the action ended, and `expect` is checked against it. An error
  # from the suspicion's own line (a misspelt name, a wrong argument list)
  # means the action never ran as written. In a race, or when `expect`
  # names `error` or `raises`, every error is how the action ended, except
  # a name the tree does not have: that tree cannot run the suspicion.
  def holdfast_step(records, act, errors:)
    scope = Scope.new(self, records)
    result = scope.instance_exec(&act.block)
    { result:, scope:, shown: "#{HoldfastCheck.one_line(act.text)} returned #{holdfast_show(result)}" }
  rescue StandardError => e
    app = HoldfastCheck.app_error?(e)
    absent = HoldfastCheck.absent(e) unless app
    raise CouldNotRun.new("do", "`#{act.text}` raised #{e.class}: #{e.message.lines.first.to_s.strip}", absent:) if absent || !(errors || app)

    { error: e, scope:, shown: "#{HoldfastCheck.one_line(act.text)} raised #{e.class}: #{e.message.lines.first.to_s.strip[0, 300]}" }
  end

  # A `do` of several lines is one item of the Markdown list it is shown in.
  def self.one_line(text) = text.strip.gsub(/\s*\n\s*/, "; ")

  CALL_SHAPE = /wrong number of arguments|missing keyword|unknown keyword/

  def self.app_error?(error)
    return false if error.is_a?(ArgumentError) && error.message.match?(CALL_SHAPE)

    root = Rails.root.to_s
    first = Array(error.backtrace).find { _1.start_with?(root) }
    !!first&.start_with?("#{root}/app/", "#{root}/lib/")
  end

  # The first action runs on its own thread until it reaches the pause point;
  # the second runs to its end (or until it waits on a lock the first holds);
  # then the first goes on.
  def holdfast_interleave(world, acts, point)
    gate = { point:, paused: Queue.new, go: Queue.new, passed: false }
    first_records, second_records = world.fresh, world.fresh
    outcomes = []
    t1 = Thread.new do
      Thread.current[:holdfast_gate] = gate
      ActiveRecord::Base.connection_pool.with_connection { outcomes[0] = holdfast_step(first_records, acts[0], errors: true) }
    rescue CouldNotRun => e
      outcomes[0] = { error: e, shown: e.message, could_not_run: e }
    ensure
      gate[:paused].push(:done)
    end
    reached = gate[:paused].pop == true
    backend = Queue.new
    t2 = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        backend << (conn.raw_connection.backend_pid if conn.raw_connection.respond_to?(:backend_pid))
        outcomes[1] = holdfast_step(second_records, acts[1], errors: true)
      end
    rescue CouldNotRun => e
      outcomes[1] = { error: e, shown: e.message, could_not_run: e }
    ensure
      backend << nil
    end
    waited = HoldfastCheck.blocked?(t2, backend.pop)
    gate[:go].push(true)
    [t1, t2].each { raise CouldNotRun.new("race", "the two actions did not finish within 20 s (a deadlock?)") unless _1.join(20) }
    outcomes.each { raise _1[:could_not_run] if _1[:could_not_run] }
    outcomes[0] = outcomes[0].merge(held_at: (gate[:held_at] if reached),
                                    paused: reached ? "held at #{gate[:held_at]}#{"; the second waited on a lock" if waited}" : "never reached #{point}")
    outcomes
  end

  # Whether the second action is still running after a second, or (on
  # PostgreSQL) sooner, as soon as its connection waits on a lock the held
  # action has: a fixed wait cost a second per held order.
  def self.blocked?(thread, pid, limit: 1.0)
    return thread.join(limit).nil? unless pid

    conn = ActiveRecord::Base.connection
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    until thread.join(0.01)
      return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return true if conn.select_value("SELECT 1 FROM pg_locks WHERE pid = #{Integer(pid)} AND NOT granted LIMIT 1")
    end
    false
  end

  # A race is confirmed when an interleaved order breaks `expect` and ends in
  # a way neither serial order ends: what each action did and what `expect`
  # saw. An interleaving that ends like a serial order is only an order.
  def holdfast_race_verdict(serial, held, point)
    reached = held.select { |_, run| run["held_at"] }
    # A serial order that fails `expect` means the expectation is not one a
    # race can break: only an end no serial order reaches is evidence then.
    failing = serial.find { |_, run| run["result"] == "confirmed" }
    broken = reached.find { |_, run| run["result"] == "confirmed" && serial.values.none? { HoldfastCheck.end_of(_1) == HoldfastCheck.end_of(run) } }
    if broken && failing
      order, run = broken
      { "result" => "confirmed", "order" => order, "pause_used" => "#{point} (#{run["held_at"]})",
        "why" => "#{order} (held at #{run["held_at"]}) ends #{HoldfastCheck.end_text(run)}, an end no serial order reaches " \
                 "(#{serial.map { |label, r| "#{label} ends #{HoldfastCheck.end_text(r)}" }.join("; ")}); serial order #{failing[0].inspect} also fails expect, so this end is the evidence" }
    elsif broken
      { "result" => "confirmed", "order" => broken[0], "pause_used" => "#{point} (#{broken[1]["held_at"]})",
        "why" => "#{broken[0]} (held at #{broken[1]["held_at"]}): #{broken[1]["why"]}, an end neither serial order reaches" }
    elsif failing
      { "result" => "refuted", "pause_used" => point, "serial_fails" => true,
        "why" => "refuted as a race: serial order #{failing[0].inspect} also fails expect (#{failing[1]["why"]}), and each interleaving ends as a serial order ends; write the end no serial order allows" }
    else
      { "result" => "refuted", "pause_used" => point, "why" => "each interleaving that reached #{point} ended as a serial order ends" }
    end
  end

  # How a run ended: each action's value (or the class it raised) and what
  # `expect` saw. A record the actions made is named by its class only and a
  # time by nothing, since ids and clocks differ from one order to the next
  # without the end differing; a given record keeps its id.
  TIME = /\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d+)?(?: ?(?:UTC|Z|[+-]\d\d:?\d\d))*/
  def self.end_of(run)
    given = Array(run["given_ids"])
    [run["ends"], run["checks"].map { [_1["holds"], _1["observed"], _1["failed"]] }].to_s
      .gsub(/\b([A-Z]\w*(?:::[A-Z]\w*)*)#(\d+)/) { given.include?($&) ? $& : "#{$1}#new" }.gsub(TIME, "<time>")
  end

  def self.end_text(run) = "[#{Array(run["ends"]).join(", ")}; #{run["checks"].map { "#{_1["expect"]} #{_1["holds"] ? "holds" : "fails"}#{" (#{_1["observed"]})" if _1["observed"]}" }.join("; ")}]"

  def holdfast_show(value)
    case value
    when ActiveRecord::Base
      state = %w[status state].find { value.has_attribute?(_1) }
      "#{value.class.name}##{value.id}#{"(#{state}: #{value[state].inspect})" if state}"
    when Array then value.size <= 3 ? "[#{value.map { holdfast_show(_1) }.join(", ")}]" : "#{value.size} items"
    when Hash then value.inspect[0, 160]
    when nil, true, false, Numeric, Symbol then value.inspect
    when String then value.inspect[0, 160]
    when Exception then "#{value.class}: #{value.message.lines.first.to_s.strip[0, 300]}"
    else value.inspect.then { _1.size <= 160 && !_1.start_with?("#<") ? _1 : value.class.name }
    end
  end

  # SQLite has no TRUNCATE; DELETE with the foreign keys off empties the
  # tables in any order, and sqlite_sequence holds the ids to restart.
  def holdfast_truncate
    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    return if tables.empty?
    return conn.execute("TRUNCATE #{tables.map { conn.quote_table_name(_1) }.join(", ")} RESTART IDENTITY CASCADE") if conn.adapter_name.match?(/postg/i)

    conn.disable_referential_integrity { tables.each { conn.execute("DELETE FROM #{conn.quote_table_name(_1)}") } }
    conn.execute("DELETE FROM sqlite_sequence") if conn.adapter_name.match?(/sqlite/i) && conn.select_value("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'")
  end

  def holdfast_write(report)
    dir = ENV["HOLDFAST_CHECK_OUT"] or return
    File.write(File.join(dir, "#{report["id"]}.json"), JSON.generate(report))
  end
end
