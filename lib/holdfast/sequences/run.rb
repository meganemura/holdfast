# rbs_inline: enabled

# Runs every sequence definition in SEQUENCES_OUT, each in its own process
# on its own numbered test database, until the seeds are clean or one fails,
# and prints one table. The hunt stage runs it as a script:
#
#   ruby run.rb [-j 4] [--cases 300] [--seeds 1,2,3] [--timeout S] [--json FILE] [FILE...]
require "json"
require "open3"
require "etc"
require "timeout"
require "fileutils"

$stdout.sync = true
# Logs hold UTF-8 (zone names, refusals); a caller with no LANG must not make them US-ASCII.
Encoding.default_external = Encoding::UTF_8

LIB = __dir__ #: String

args = ARGV.dup
take = ->(flag, default) { (i = args.index(flag)) ? args.slice!(i, 2)&.last : default } #: ^(String, untyped) -> untyped
jobs = Integer(take.("-j", [Etc.nprocessors, 4].min))
cases = Integer(take.("--cases", 300))
top = 2**31 - 1 #: Integer
seeds = take.("--seeds", Array.new(3) { rand(1..top) }.join(",")) #: String
limit = Integer(take.("--timeout", 3600))
json_out = take.("--json", nil)
defs = ENV.fetch("SEQUENCES_OUT", "spec/sequences")
files = args.empty? ? Dir["#{defs}/*.rb"].reject { File.basename(it) == "invariants.rb" }.sort : args
abort "no definitions in #{defs}: holdfast run drafts them" if files.empty?

out = File.expand_path(ENV.fetch("SEQUENCES_WORK", "tmp/sequences"))
FileUtils.mkdir_p(out)
jobs = [jobs, files.size].min
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# One database per worker, so two areas never truncate each other's rows.
# SEQUENCES_DATABASE_URL names a database prefix of the caller's, so two
# apps on one server never share app_test1.
worker_env = lambda do |i|
  url = ENV["SEQUENCES_DATABASE_URL"]
  { "TEST_ENV_NUMBER" => (i + 1).to_s }.merge(url ? { "DATABASE_URL" => "#{url}_seq#{i + 1}" } : {})
end
puts "preparing #{jobs} test databases (TEST_ENV_NUMBER=1..#{jobs})"
jobs.times.map do |i|
  Thread.new do
    log, status = Open3.capture2e(worker_env.(i).merge("RAILS_ENV" => "test"),
                                  "bin/rails", "db:create", "db:schema:load")
    abort "database #{i + 1} failed:\n#{log}" unless status.success?
  end
end.each(&:join)
puts "seeds #{seeds}, #{cases} cases each, #{files.size} areas, #{jobs} at a time"

queue = Queue.new
files.each { queue << it }
results = {} #: Hash[String, area_result]
running = {} #: Hash[String, Float]
lock = Mutex.new

# Each refusal names what to change: a param the text mentions, or the kind
# of input a refusal like it needs.
# @rbs!
#   # One area's run: its files, how its process ended, and the report it
#   # wrote, which is the JSON of Sequences.explore_cases.
#   type area_result = { file: String, log: String, seconds: Integer, status: Process::Status | :timeout, report: Holdfast::json? }
#
#   class Object
#     private def hint: (Holdfast::json_value text, Array[Holdfast::json_value] params) -> String
#     private def clean_refusal: (Holdfast::json_value text) -> String?
#     private def scope: (Holdfast::json report) -> [Integer, Integer, Array[String]]
#     private def verdict: (area_result r, Integer limit) -> [String, String, String]
#   end
def hint(text, params)
  low = text.to_s.downcase
  named = params.select do |param|
    words = param.to_s.sub(/_(id|at|on|from)\z/, "").split("_")
    low.include?(param.to_s) || words.all? { low.include?(it) }
  end
  return "change #{named.join(", ")}" if named.any?

  case low
  when /only one door picks|one door only|one door makes a new/
    "the two doors cannot take the same inputs; drop the twins line, or give both doors the same params"
  when /ends? before|duration|longest|shortest|minutes/
    "draw the end from the start: #{params.grep(/end|until|minutes/).first || "ends_at"}: after(:starts_at, minutes: [...])"
  when /missing param (\w+)/ then "add the param #{$1} to the action body"
  when /param is missing|is missing|is invalid/ then "send the param the message names"
  when /unauthori[sz]ed|not recogni[sz]ed|pin|token|unknown kiosk|forbidden/ then "a credential: the caller pool, auth_for, or the setup"
  when /not found|couldn't find/ then "the record it looks up is not there for this caller: narrow the pool or make it in setup"
  when /closed|not open|hours|weekday/ then "a time param inside opening hours (BOUNDARY_TIMES, clock start)"
  when /passed|ahead|too early|too late|closed at|has closed/ then "a time param or the clock: how far ahead it is drawn"
  else "make the state it needs in setup, or narrow a pool to records it accepts"
  end
end

def clean_refusal(text) = text.to_s.sub(/\A(HTTP \d+ )?refused: /, "").gsub(/\s+/, " ")[0, 70]

# An action reached its target when one run ended other than refused; one
# that was only refused, never drawn, or left as TODO checked nothing.
def scope(report)
  reached = report["reached"]
  missing = report["actions"].filter_map do |action|
    kinds = reached[action] || {}
    params = report.dig("params", action.sub(/ \[other offset\]\z/, "")) || []
    if kinds.empty? then "#{action} (never drawn)"
    elsif kinds.keys.all? { it.include?("refused") }
      texts = report.dig("refused_with", action) || []
      text = texts.first
      also = texts.drop(1).map { clean_refusal(it) }.uniq - [clean_refusal(text)]
      "#{action} (only refused: #{clean_refusal(text)}#{"; also: #{also.join("; ")}" unless also.empty?}; hint: #{hint(text, params)})"
    end
  end
  done = report["actions"].size - missing.size
  missing += report["skipped"].map { |action, why| "#{action} (#{why})" }
  [done, report["actions"].size + report["skipped"].size, missing]
end

RANK = { "FAILURE" => 0, "unchecked" => 1, "partly checked" => 2, "clean" => 3 }.freeze #: Hash[String, Integer]

# A verdict of clean means every action, offset replay and pair of doors
# reached its target at least once; anything less is partly checked.
def verdict(r, limit)
  rep = r[:report]
  if rep.nil?
    tail = File.readlines(r[:log]).grep(/Error|error:|uninitialized|undefined/).first.to_s.strip
    return ["unchecked", "-", "unchecked: #{r[:status] == :timeout ? "timed out after #{limit} s" : "no report (#{tail[0, 100]})"}"]
  end
  done, total, missing = scope(rep)
  # A failure or a refusal that came from a real service says nothing about
  # the app; the area checks nothing until the service is faked.
  unless rep["network"].to_h.empty?
    calls = rep["network"].map { |where, actions| "#{where}#{" (from #{actions.join(", ")})" unless actions.empty?}" }
    return ["unchecked", "#{done}/#{total}", "unchecked: real network call to #{calls.join(", ")}; the hunt refuses it, so fake that service in the area's setup"]
  end
  # The time limit stopped the area between cases with no failure found:
  # what ran still counts, and the row says it was cut short.
  if rep["verdict"].nil?
    ran = File.read(r[:log])[/: (\d+) runs in/, 1]
    rep = rep.merge("verdict" => "clean", "seeds" => [nil])
    cut = "cut by the time limit after #{ran || "some"} of #{rep["cases"]} cases"
  end
  case rep["verdict"]
  when "clean"
    runs = cut || "#{rep["seeds"].size} seeds x #{rep["cases"]} cases"
    return ["clean", "#{done}/#{total}", "clean: #{runs}"] if missing.empty?

    ["partly checked", "#{done}/#{total}", "partly checked: #{runs}; not covered:\n#{missing.map { "    - #{it}" }.join("\n")}"]
  when "failure" then ["FAILURE", "#{done}/#{total}", "FAILURE: #{rep["reason"].to_s.lines.first.to_s.strip}"]
  else ["unchecked", "#{done}/#{total}", "unchecked: #{rep["reason"].to_s.lines.first.to_s.strip}"]
  end
end

now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
estimated = false
heartbeat = Thread.new do
  loop do
    sleep 20
    lock.synchronize do
      busy = running.map { |name, t0| "#{name} #{(now.() - t0).round} s" }.join(", ")
      puts "  ... #{(now.() - started).round} s: #{results.size} of #{files.size} done; running #{busy}"
    end
  end
end

jobs.times.map do |i|
  Thread.new do
    while (file = (queue.pop(true) rescue nil))
      name = File.basename(file, ".rb")
      report = File.join(out, "#{name}.json")
      log = File.join(out, "#{name}.log")
      File.delete(report) if File.exist?(report)
      env = { **worker_env.(i), "SEQ_CASES" => cases.to_s, "SEQ_SEEDS" => seeds,
              "SEQ_REPORT" => report, "SEQUENCES_LIB" => File.join(LIB, "sequences.rb") }
      t0 = now.()
      lock.synchronize { running[name] = t0 }
      pid = Process.spawn(env, "bundle", "exec", "rspec", file, out: log, err: [:child, :out], pgroup: true)
      status = begin
        Timeout.timeout(limit) { Process.wait2(pid).last }
      rescue Timeout::Error
        Process.kill("TERM", -pid)
        Process.wait(pid)
        :timeout
      end #: Process::Status | :timeout
      seconds = (now.() - t0).round
      lock.synchronize do
        running.delete(name)
        results[name] = { file:, log:, seconds:, status:, report: (JSON.parse(File.read(report)) if File.exist?(report)) }
        kind, reached, = verdict(results[name], limit)
        puts "  #{name}: #{kind} (#{reached} reached) in #{seconds} s"
        unless estimated
          estimated = true
          rounds = (files.size.to_f / jobs).ceil
          puts "  estimate: about #{(rounds * seconds / 60.0).ceil} min for all #{files.size} areas (#{rounds} rounds of #{jobs}, the first area took #{seconds} s)"
        end
      end
    end
  end
end.each(&:join)
heartbeat.kill

rows = results.map do |name, r|
  kind, reached, text = verdict(r, limit)
  [name, kind, reached, text, r] #: [String, String, String, String, area_result]
end.sort_by { |name, kind, *| [RANK.fetch(kind), name] }
width = rows.map { it[0].size }.max
puts format("%-#{width}s  %-7s  %s", "area", "reached", "verdict")
rows.each do |name, kind, reached, text, r|
  first, *rest = text.lines
  first = first #: String
  puts format("%-#{width}s  %-7s  %s", name, reached, first.chomp)
  rest.each { puts "#{" " * (width + 9)}#{it}" }
  puts format("%-#{width}s  %-7s  log: %s (%d s)", "", "", r[:log].sub("#{Dir.pwd}/", ""), r[:seconds]) unless kind == "clean"
end
puts "total #{(now.() - started).round} s, seeds #{seeds}"
if json_out
  File.write(json_out, JSON.generate(rows.map do |name, kind, reached, text, r|
    { "area" => name, "verdict" => kind, "reached" => reached, "text" => text, "log" => r[:log], "seconds" => r[:seconds],
      "file" => r[:file], "cases" => cases, "seeds" => seeds }
  end))
end
exit(rows.any? { %w[FAILURE unchecked].include?(it[1]) } ? 1 : 0)
