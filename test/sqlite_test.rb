# Runs the skill's examples and a short hunt on the clinic fixture moved to
# SQLite: its Gemfile names sqlite3 in place of pg and its database.yml names
# one file. Races and the hunt empty their tables with SQL that SQLite takes,
# and each side gets a database file of its own under .holdfast/db/, so the
# app's own test database is never written. Needs the sqlite3 gem installed
# for this Ruby, so it skips without it; HOLDFAST_SQLITE=required makes that
# a failure.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "yaml"
require "open3"
require_relative "skill_examples_test"

class SqliteTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def sqlite_clinic(dir)
    sqlite = Gem::Specification.find_all_by_name("sqlite3").max_by(&:version)
    unless sqlite
      flunk "HOLDFAST_SQLITE=required and the sqlite3 gem is not installed" if ENV["HOLDFAST_SQLITE"] == "required"
      skip "install the sqlite3 gem to run the fixture on SQLite"
    end
    app = File.join(dir, "clinic")
    FileUtils.cp_r(File.join(__dir__, "fixture", "clinic"), app)
    gemfile = File.join(app, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(/^gem "pg".*$/, %(gem "sqlite3", "#{sqlite.version}")))
    File.write(File.join(app, "config", "database.yml"), "test:\n  adapter: sqlite3\n  database: storage/test.sqlite3\n  timeout: 5000\n")
    File.write(File.join(app, ".gitignore"), "/.holdfast/\n/log/\n/tmp/\n/storage/\n")
    out, status = Open3.capture2e({ "BUNDLE_GEMFILE" => gemfile }, "bundle", "lock", "--local", chdir: app)
    assert status.success?, out
    git = ->(*args) { Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", *args, chdir: app) }
    git.("init", "-q", "-b", "main")
    git.("add", "-A")
    git.("commit", "-qm", "clinic")
    app
  end

  def holdfast(app, *args) = Open3.capture2e({ "BUNDLE_GEMFILE" => File.join(app, "Gemfile") }, RbConfig.ruby, File.join(ROOT, "bin", "holdfast"), *args, chdir: app)

  def test_the_skill_examples_race_on_sqlite_as_on_postgresql_on_files_of_their_own
    Dir.mktmpdir("holdfast-sqlite") do |dir|
      app = sqlite_clinic(dir)
      files = SkillExamplesTest.examples.each_with_index.map { |text, i| File.join(dir, "example#{i + 1}.yml").tap { File.write(_1, text) } }
      out, status = holdfast(app, "check", *files, "--here")
      assert_equal 2, status.exitstatus, out
      rows = File.readlines(File.join(app, ".holdfast", "check", "main", "check.jsonl")).map { JSON.parse(_1) }
      rows.each { assert_equal SkillExamplesTest::EXPECTED.fetch(_1["target"]), _1["kind"], "#{_1["target"]}: #{_1["reason"]}\n#{out}" }
      assert_equal SkillExamplesTest::EXPECTED.size, rows.size
      record = JSON.parse(File.read(File.join(app, ".holdfast", "record.json")))
      assert_match(%r{\Asqlite3:/\S+/clinic/\.holdfast/db/test\z}, record.dig("database", "url"))
      assert_match(%r{DATABASE_URL=sqlite3:\S+/\.holdfast/db/test_c2 TEST_ENV_NUMBER=c2 bundle exec rspec}, out)
      refute File.exist?(File.join(app, "storage", "test.sqlite3")), "the app's own test database is never written"
    end
  end

  def test_a_hunt_on_sqlite_finds_the_sweep_overwriting_a_check_in
    Dir.mktmpdir("holdfast-sqlite") do |dir|
      app = sqlite_clinic(dir)
      out, status = holdfast(app, "run", "--budget", "60")
      assert_equal 2, status.exitstatus, out
      rows = File.readlines(File.join(app, ".holdfast", "verdicts.jsonl")).map { JSON.parse(_1) }
      area = rows.find { _1["target"] == "sequences: check_ins" }
      assert area, out
      assert_equal "bug_suspect", area["kind"], out
      refute_includes out, "holdfast failed"
      refute File.exist?(File.join(app, "storage", "test.sqlite3")), "the app's own test database is never written"
    end
  end

  # RSpec's stub sits in front of a hook on the module, so a race could not
  # hold at a module method the suspicion stubs until the stub itself held.
  def test_a_race_holds_at_a_module_method_the_suspicion_stubs
    Dir.mktmpdir("holdfast-sqlite") do |dir|
      app = sqlite_clinic(dir)
      suspicion = <<~YAML
        - says: the sweep holds at the gateway while a check-in waits
          given: {stub: {ruby: "allow(PaymentGateway).to receive(:client).and_return(FakePaymentGateway.new); :stubbed"}, appointment: {status: booked, starts_at: -20m}}
          race: [NoShowSweepJob.perform_now, "CheckIn.new(appointment).call"]
          pause: PaymentGateway.client
          expect: appointment.status == "no_show"
      YAML
      File.write(File.join(dir, "stub.yml"), suspicion)
      out, = holdfast(app, "check", File.join(dir, "stub.yml"), "--here")
      row = JSON.parse(File.readlines(File.join(app, ".holdfast", "check", "main", "check.jsonl")).first)
      refute_equal "could_not_run", row["kind"], out
      assert_includes row["evidence"].join("\n"), "held at PaymentGateway.client", out
    end
  end

  # Drafting reads every controller of the app, so one form it could not
  # read failed the whole hunt.
  def test_drafting_reads_a_controller_that_permits_nothing_and_finds_by_a_local_key_or_a_splat
    Dir.mktmpdir("holdfast-sqlite") do |dir|
      app = sqlite_clinic(dir)
      File.write(File.join(app, "app", "controllers", "reschedules_controller.rb"), <<~RUBY)
        class ReschedulesController < ActionController::API
          def create
            Appointment.find(params[:id]).update!(params.require(:appointment).permit)
            column = :patient_token
            Appointment.find_by(column => params[:token])&.touch
            search = { status: "booked" }
            Appointment.find_by(**search)&.touch
            params.expect(**search)
            Rails.logger.info(params[:note])
            head :ok
          end
        end
      RUBY
      routes = File.join(app, "config", "routes.rb")
      File.write(routes, File.read(routes).sub(/^end/, %(  post "/appointments/:id/reschedule", to: "reschedules#create"\nend)))
      Open3.capture2e("git", "add", "-A", chdir: app)
      Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-qm", "reschedule", chdir: app)
      out, = holdfast(app, "run", "--budget", "30")
      refute_includes out, "holdfast failed", out
      assert File.file?(File.join(app, ".holdfast", "sequences", "reschedules.rb")), out
    end
  end

  # A service that calls Net::HTTP itself has no `.client` a spec replaces:
  # its real call is the environment, never a bug_suspect row.
  def test_a_real_network_call_in_the_hunt_is_the_environment_and_the_draft_names_the_service
    Dir.mktmpdir("holdfast-sqlite") do |dir|
      app = sqlite_clinic(dir)
      File.write(File.join(app, "app", "services", "arrival_notice.rb"), <<~RUBY)
        require "net/http"

        module ArrivalNotice
          def self.send_for(appointment) = Net::HTTP.post(URI("http://notices.invalid/arrivals"), appointment.id.to_s)
        end
      RUBY
      check_in = File.join(app, "app", "services", "check_in.rb")
      File.write(check_in, File.read(check_in).sub("    @appointment\n  end", "    ArrivalNotice.send_for(@appointment)\n    @appointment\n  end"))
      Open3.capture2e("git", "add", "-A", chdir: app)
      Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-qm", "notice", chdir: app)
      out, = holdfast(app, "run", "--budget", "30")
      rows = File.readlines(File.join(app, ".holdfast", "verdicts.jsonl")).map { JSON.parse(_1) }
      network = rows.select { _1["reason"].to_s.include?("real network call to notices.invalid:80") }
      refute_empty network, out
      network.each { assert_equal "unchecked", _1["kind"], out }
      refute(rows.any? { _1["kind"] == "bug_suspect" && _1["reason"].include?("notices.invalid") }, out)
      drafted = Dir[File.join(app, ".holdfast", "sequences", "*.rb")].map { File.read(_1) }.join
      assert_includes drafted, "TODO: ArrivalNotice calls a real host"
    end
  end
end
