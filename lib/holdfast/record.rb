# rbs_inline: enabled

require "digest"

module Holdfast
  # What this project needs to run a test, learned once by running it and
  # kept in .holdfast/record.json for every stage. Each learning step keeps
  # its command and outcome, so a failed setup is one fact the verdicts cite
  # instead of a load error on every row.
  class Record
    # jitcatch numbers base 1 and head 2; a pin runs in a checkout of its own.
    SIDES = { "base" => "1", "head" => "2", "pin" => "3" }.freeze #: Hash[String, String]
    COVERAGE = %w[coverage/jitcatch-coverage.json tmp/jitcatch-coverage.json].freeze #: Array[String]

    attr_reader :data #: json

    #: (String) -> String
    def self.path(root) = File.join(Holdfast.dir(root), "record.json")

    #: (String, ?relearn: bool?) -> Record
    def self.load_or_learn(root, relearn: false)
      return new(JSON.parse(File.read(path(root)))) if File.file?(path(root)) && !relearn

      learn(root).tap { _1.write(root) }
    end

    #: (String) -> Record
    def self.learn(root)
      facts = read_facts(root)
      steps = [] #: Array[json]
      if facts["rails"] && facts["database"]["url"]
        SIDES.each do |side, number|
          steps << run_step(root, "create the #{side} database (#{database_name(facts, number) || "TEST_ENV_NUMBER=#{number}"})", facts["side_setup"],
                            side_env(facts, number))
        end
      end
      if steps.all? { _1["ok"] } && (probe = smallest_test(root, facts["framework"]))
        cmd = facts["framework"] == "rspec" ? "#{facts["bundle"]}rspec #{probe}" : "#{facts["bundle"]}ruby -Itest #{probe}"
        steps << run_step(root, "boot one test", cmd, side_env(facts, SIDES["base"]))
      end
      failed = steps.find { !_1["ok"] }
      new(facts.merge("learned_at" => Time.now.utc.iso8601, "steps" => steps,
                      "status" => failed ? "setup_failed" : "ok",
                      "failure" => failed && "#{failed["name"]}: `#{failed["command"]}` exited #{failed["exit"]}"))
    end

    #: (String) -> json
    def self.read_facts(root)
      lock = File.read(File.join(root, "Gemfile.lock")) rescue ""
      framework = lock.match?(/^    rspec-core /) && File.directory?(File.join(root, "spec")) ? "rspec" : "minitest"
      db_yml = File.read(File.join(root, "config/database.yml")) rescue ""
      test_section = db_yml[/^test:.*\z/m].to_s
      adapter = test_section[/adapter:\s*(\w+)/, 1] || db_yml[/adapter:\s*(\w+)/, 1]
      server = %w[postgresql mysql2 trilogy].include?(adapter)
      url = if server then database_url(root, adapter)
            elsif adapter == "sqlite3" then sqlite_url(root)
            end
      {
        "framework" => framework,
        "bundle" => File.file?(File.join(root, "Gemfile")) ? "bundle exec " : "",
        "rails" => File.file?(File.join(root, "config/environment.rb")),
        "helper" => framework == "rspec" ? (File.file?(File.join(root, "spec/rails_helper.rb")) ? "rails_helper" : "spec_helper") : "test_helper",
        "database" => { "adapter" => adapter, "server" => server, "numbered" => test_section.include?("TEST_ENV_NUMBER"),
                        "url" => url }.compact,
        "env" => db_yml.scan(/ENV(?:\.fetch\(|\[)\s*["'](\w+)["']/).flatten.uniq - %w[TEST_ENV_NUMBER RAILS_ENV],
        "side_setup" => url ? "bin/rails db:create db:schema:load" : nil,
        "base_branch" => base_branch(root),
        "coverage" => COVERAGE.find { File.file?(File.join(root, _1)) }
      }
    end

    # Two apps whose database.yml both say app_test<N> would share one
    # database on a shared server. Each app gets its own names, from its
    # directory and a digest of its path, through DATABASE_URL, which Rails
    # prefers over database.yml and jitcatch numbers per side.
    #: (String, String?) -> String?
    def self.database_url(root, adapter)
      yml = YAML.safe_load(ERB.new(File.read(File.join(root, "config/database.yml"))).result, aliases: true) #: json
      none = {} #: json
      test = yml.fetch("test", none)
      scheme = { "postgresql" => "postgres", "mysql2" => "mysql2", "trilogy" => "trilogy" }.fetch(adapter)
      user = [test["username"], test["password"]].compact.join(":")
      host = test["host"] || "localhost"
      name = "hf_#{File.basename(root).downcase.gsub(/[^a-z0-9]+/, "_")}_#{Digest::SHA1.hexdigest(root)[0, 6]}"
      "#{scheme}://#{"#{user}@" unless user.empty?}#{host}#{":#{test["port"]}" if test["port"]}/#{name}"
    rescue StandardError
      nil
    end

    # A SQLite database.yml names one file, and TEST_ENV_NUMBER changes it
    # only where the file name reads it: base, head and each hunt worker
    # wrote the app's own storage/test.sqlite3, and emptied it after a race.
    # Each gets a file of its own under .holdfast/db/ instead.
    #: (String) -> String
    def self.sqlite_url(root) = "sqlite3:#{File.join(File.expand_path(Holdfast.dir(root)), "db", "test")}"

    #: (json facts, String number) -> Hash[String, String]
    def self.side_env(facts, number)
      url = facts.dig("database", "url")
      { "RAILS_ENV" => "test", "TEST_ENV_NUMBER" => number }.merge(url ? { "DATABASE_URL" => "#{url}_#{number}" } : {})
    end

    #: (json facts, String number) -> String?
    def self.database_name(facts, number) = facts.dig("database", "url")&.then { "#{_1[%r{[^/]+\z}]}_#{number}" }

    #: (String) -> String
    def self.base_branch(root)
      remote = Open3.capture2("git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD", chdir: root, err: File::NULL).first.strip
      return remote unless remote.empty?

      %w[main master].find { system("git", "rev-parse", "--verify", "--quiet", _1, chdir: root, out: File::NULL) } || "HEAD"
    end

    #: (String root, String framework) -> String?
    def self.smallest_test(root, framework)
      glob = framework == "rspec" ? "spec/**/*_spec.rb" : "test/**/*_test.rb"
      Dir.glob(glob, base: root).min_by { File.size(File.join(root, _1)) }
    end

    #: (String root, String name, String command, Hash[String, String] extra_env) -> json
    def self.run_step(root, name, command, extra_env)
      env = extra_env.merge("BUNDLE_GEMFILE" => File.join(root, "Gemfile"))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, status = Open3.capture2e(env, "/bin/sh", "-c", command, chdir: root)
      { "name" => name, "command" => command, "env" => extra_env, "ok" => status.success?, "exit" => status.exitstatus,
        "seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1),
        "tail" => status.success? ? nil : failure_lines(out) }.compact
    end

    # Rake ends every failure with the same two lines; the cause is above them.
    #: (String) -> Array[String]
    def self.failure_lines(out)
      lines = out.lines.map(&:rstrip).reject { _1.strip.empty? || _1.start_with?("Tasks:", "(See full trace") }
      (lines.grep(/error|refused|could not|failed|bad/i).first(4) + lines.last(2)).uniq
    end

    #: (json) -> void
    def initialize(data) = @data = data
    #: () -> bool
    def ok? = data["status"] == "ok"
    #: () -> String?
    def failure = data["failure"]
    #: () -> String
    def framework = data["framework"]
    #: () -> Array[String]
    def env_names = data["env"]
    #: () -> String?
    def side_setup = data["side_setup"]
    #: () -> String
    def bundle = data["bundle"]
    #: () -> String
    def helper = data["helper"]
    #: () -> String
    def base_branch = data["base_branch"]
    #: () -> String?
    def coverage = data["coverage"]
    #: () -> String?
    def database_url = data.dig("database", "url")
    #: (String) -> Hash[String, String]
    def env_for(side) = self.class.side_env(data, SIDES.fetch(side))
    #: () -> String
    def test_suffix = framework == "rspec" ? "_spec.rb" : "_test.rb"

    #: (String) -> void
    def write(root)
      FileUtils.mkdir_p(Holdfast.dir(root))
      File.write(self.class.path(root), "#{JSON.pretty_generate(data)}\n")
    end
  end
end
