# Loaded through RUBYOPT into each test process jitcatch starts, before the
# app: it records which lines of the app each test file ran, so a row can say
# whether a test reached the changed lines or only named the method. It runs
# with no holdfast code loaded and writes one JSON file per process.
require "coverage"
require "json"

# eval: true also counts code compiled from a file name, which is how
# ActionView runs a template. Branches tell whether the body of a
# `return x if y` ran, which line counts cannot.
Coverage.start(lines: true, branches: true, eval: true) unless Coverage.running?

# Which of the values the change added or removed (HOLDFAST_VALUES, a JSON
# list) an input drew: a row written with that value. Reads do not count: a
# scope that selects by a constant puts every member in each query.
HOLDFAST_WANTED = (JSON.parse(ENV.fetch("HOLDFAST_VALUES", "[]")) rescue []).map(&:to_s)
HOLDFAST_DREW = []
unless HOLDFAST_WANTED.empty?
  attach = TracePoint.new(:end) do |tp|
    next unless defined?(ActiveSupport::Notifications)

    tp.disable
    ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next unless sql.match?(/\A\s*(INSERT|UPDATE)/i)

      binds = payload[:type_casted_binds]
      binds = binds.call if binds.respond_to?(:call)
      seen = Array(binds).map(&:to_s) + sql.scan(/'((?:[^']|'')*)'/).flatten
      HOLDFAST_DREW.concat(HOLDFAST_WANTED & seen)
      HOLDFAST_DREW.uniq!
    end
  end
  attach.enable
end

# What ran since the last take, as { file => lines } and { file => arms },
# for the app's own files. Each take clears the counts, so the file's total
# is the union of every take.
HOLDFAST_ROOT = "#{Dir.pwd}/"
HOLDFAST_TOTAL = { "hits" => Hash.new { |h, k| h[k] = [] }, "arms" => Hash.new { |h, k| h[k] = [] } }
def holdfast_take
  hits = {}
  arms = {}
  Coverage.result(stop: false, clear: true).each do |path, counts|
    next unless path.start_with?(HOLDFAST_ROOT)

    relative = path.delete_prefix(HOLDFAST_ROOT)
    next unless relative.start_with?("app/", "lib/")

    lines = counts.is_a?(Hash) ? counts[:lines] : counts
    ran = Array(lines).each_with_index.filter_map { |count, i| i + 1 if count.to_i.positive? }
    taken = (counts.is_a?(Hash) && counts[:branches] || {}).values.flat_map { |a| a.filter_map { |(_, _, line, column, last, last_column), n| "#{line}:#{column}-#{last}:#{last_column}" if n.positive? } }
    hits[relative] = ran unless ran.empty?
    arms[relative] = taken unless taken.empty?
  end
  hits.each { |k, v| HOLDFAST_TOTAL["hits"][k] |= v }
  arms.each { |k, v| HOLDFAST_TOTAL["arms"][k] |= v }
  { "hits" => hits, "arms" => arms }
end

# One test file holds examples that agree and examples the change added, so
# a file's lines cannot say which example drew a new branch. Each example's
# own lines are kept by the line it is declared on, the line jitcatch
# reports for it.
HOLDFAST_EXAMPLES = {}
module HoldfastRSpecExample
  def run(*)
    holdfast_take
    super
  ensure
    HOLDFAST_EXAMPLES[metadata[:line_number]] = holdfast_take
  end
end
module HoldfastMinitestTest
  def run(*)
    holdfast_take
    super
  ensure
    line = (method(name).source_location&.last rescue nil)
    HOLDFAST_EXAMPLES[line] = holdfast_take if line
  end
end
holdfast_hook = TracePoint.new(:end) do |tp|
  if defined?(RSpec::Core::Example) && !RSpec::Core::Example.include?(HoldfastRSpecExample)
    RSpec::Core::Example.prepend(HoldfastRSpecExample)
    tp.disable
  elsif defined?(Minitest::Test) && !Minitest::Test.include?(HoldfastMinitestTest)
    Minitest::Test.prepend(HoldfastMinitestTest)
    tp.disable
  end
end
holdfast_hook.enable

at_exit do
  dir = ENV["HOLDFAST_REACH_DIR"]
  test = ARGV.reverse.find { _1.include?(".jitcatch/") }
  next unless dir && test

  holdfast_take
  record = { "side" => ENV["TEST_ENV_NUMBER"], "test" => test.sub(%r{\A.*?\.jitcatch/}, ""), "hits" => HOLDFAST_TOTAL["hits"],
             "drew" => HOLDFAST_DREW, "arms" => HOLDFAST_TOTAL["arms"], "examples" => HOLDFAST_EXAMPLES.compact }
  File.write(File.join(dir, "reach-#{ENV["TEST_ENV_NUMBER"]}-#{Process.pid}.json"), JSON.generate(record))
end
