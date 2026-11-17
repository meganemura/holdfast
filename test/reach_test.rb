# The reach recorder loads through RUBYOPT into every process a change's
# tests start, before the app's bundle. These run it the same way, in a
# plain Ruby process, with no app and no database.
require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

class ReachTest < Minitest::Test
  REACH = File.expand_path("../lib/holdfast/runtime/reach.rb", __dir__)

  def run_recorded(dir, script, values: nil)
    env = { "RUBYOPT" => "-r#{REACH}", "HOLDFAST_REACH_DIR" => File.join(dir, "reach"), "TEST_ENV_NUMBER" => "1" }
    env["HOLDFAST_VALUES"] = values if values
    FileUtils.mkdir_p([File.join(dir, "reach"), File.join(dir, ".jitcatch"), File.join(dir, "lib")])
    File.write(File.join(dir, "lib", "plan.rb"), "def plan(x) = x * 2\n")
    File.write(File.join(dir, ".jitcatch", "plan_test.rb"), script)
    Open3.capture2e(env, RbConfig.ruby, ".jitcatch/plan_test.rb", chdir: dir)
  end

  # Ruby's own json, loaded before the bundle, made an app that pins another
  # json version fail to boot: "You have already activated json".
  def test_the_recorder_loads_no_json_before_the_app_does
    Dir.mktmpdir("holdfast-reach") do |dir|
      out, status = run_recorded(dir, "puts $LOADED_FEATURES.grep(%r{/json(/|\\.rb)}).size\n")
      assert status.success?, out
      assert_equal "0", out.lines.first.strip
    end
  end

  # SimpleCov stops coverage from an at_exit that runs before the
  # recorder's; the record was then lost to "coverage measurement is not
  # enabled", and every row of the change said no test reached it.
  def test_the_record_is_written_when_another_at_exit_stopped_coverage
    Dir.mktmpdir("holdfast-reach") do |dir|
      out, status = run_recorded(dir, <<~RUBY)
        require_relative "../lib/plan"
        plan(2)
        at_exit { Coverage.result }
      RUBY
      assert status.success?, out
      files = Dir[File.join(dir, "reach", "*.json")]
      assert_equal 1, files.size, out
      assert_equal "plan_test.rb", JSON.parse(File.read(files.first))["test"]
    end
  end

  def test_a_value_the_change_named_reaches_the_recorder_as_text
    Dir.mktmpdir("holdfast-reach") do |dir|
      values = ["archived", "two, words", "日本"].map { [_1].pack("m0") }.join(",")
      out, status = run_recorded(dir, "p HOLDFAST_WANTED\n", values:)
      assert status.success?, out
      assert_equal ["archived", "two, words", "日本"].inspect, out.lines.first.strip
    end
  end
end
