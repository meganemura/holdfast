# Loaded through RUBYOPT into each test process jitcatch starts, before the
# app: it records which lines of the app each test file ran, so a row can say
# whether a test reached the changed lines or only named the method. It runs
# with no holdfast code loaded and writes one JSON file per process.
require "coverage"
require "json"

# eval: true also counts code compiled from a file name, which is how
# ActionView runs a template.
Coverage.start(lines: true, eval: true) unless Coverage.running?

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

at_exit do
  dir = ENV["HOLDFAST_REACH_DIR"]
  test = ARGV.reverse.find { _1.include?(".jitcatch/") }
  next unless dir && test

  root = "#{Dir.pwd}/"
  hits = Coverage.result.filter_map do |path, counts|
    next unless path.start_with?(root)

    relative = path.delete_prefix(root)
    next unless relative.start_with?("app/", "lib/")

    lines = counts.is_a?(Hash) ? counts[:lines] : counts
    ran = lines.each_with_index.filter_map { |count, i| i + 1 if count.to_i.positive? }
    [relative, ran] unless ran.empty?
  end.to_h
  record = { "side" => ENV["TEST_ENV_NUMBER"], "test" => test.sub(%r{\A.*?\.jitcatch/}, ""), "hits" => hits, "drew" => HOLDFAST_DREW }
  File.write(File.join(dir, "reach-#{ENV["TEST_ENV_NUMBER"]}-#{Process.pid}.json"), JSON.generate(record))
end
