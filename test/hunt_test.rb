# Runs `holdfast run` with nothing changed on the clinic fixture, with the
# invariant the skill shows, so the hunt and its folded sequences library run
# from the gem alone. Needs the same PostgreSQL server and fixture bundle as
# the skill examples, and hegeltest installed for this Ruby.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "open3"

class HuntTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_a_hunt_finds_the_sweep_overwriting_a_check_in_and_runs_the_skill_invariant
    if ENV["DB_HOST"].to_s.empty?
      flunk "HOLDFAST_PG=required and DB_HOST is not set" if ENV["HOLDFAST_PG"] == "required"
      skip "set DB_HOST and DB_PORT to a PostgreSQL server to run the hunt"
    end
    invariant = File.read(File.join(ROOT, "skills", "holdfast", "SKILL.md"))[/^```ruby\n(.*?)^```/m, 1]
    assert invariant, "the skill shows an invariant"
    Dir.mktmpdir("holdfast-hunt") do |dir|
      app = File.join(dir, "clinic")
      FileUtils.cp_r(File.join(__dir__, "fixture", "clinic"), app)
      File.write(File.join(app, ".gitignore"), "/.holdfast/\n/log/\n/tmp/\n")
      git = ->(*args) { Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", *args, chdir: app) }
      git.("init", "-q", "-b", "main")
      git.("add", "-A")
      git.("commit", "-qm", "clinic")
      FileUtils.mkdir_p(File.join(app, ".holdfast", "sequences"))
      File.write(File.join(app, ".holdfast", "sequences", "invariants.rb"), invariant)
      out, status = Open3.capture2e({ "BUNDLE_GEMFILE" => File.join(app, "Gemfile") }, RbConfig.ruby, File.join(ROOT, "bin", "holdfast"), "run", "--budget", "60", chdir: app)
      assert_equal 2, status.exitstatus, out
      assert_includes out, "nothing in the app changed against main"
      rows = File.readlines(File.join(app, ".holdfast", "verdicts.jsonl")).map { JSON.parse(_1) }
      area = rows.find { _1["target"] == "sequences: check_ins" }
      assert area, out
      assert_equal "bug_suspect", area["kind"], out
      assert_match(/no_show_sweep_job then wrote "no_show", though its own query does not select a row whose status is "checked_in"/, area["reason"])
      assert_includes File.read(File.join(app, ".holdfast", "sequences", "invariants.rb")), "invariant(:a_checked_in_appointment_is_never_charged)"
      refute_includes out, "a_checked_in_appointment_is_never_charged"
    end
  end
end
