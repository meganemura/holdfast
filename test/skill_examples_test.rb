# Runs every YAML example in the skill through `holdfast check` on the clinic
# fixture app, so a form the skill shows is a form that runs. It needs a
# PostgreSQL server at DB_HOST and DB_PORT and the fixture's bundle
# installed, so it skips without DB_HOST; HOLDFAST_PG=required makes that a
# failure, as CI sets it.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "yaml"
require "open3"

class SkillExamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  # What the clinic fixture does with each example: two defects on purpose,
  # and a check-in that holds under a race.
  EXPECTED = {
    "a passed tentative appointment is charged a no-show fee" => "confirmed",
    "check-in between the sweep's load and its lock becomes a no-show" => "confirmed",
    "two desks checking in one appointment both succeed" => "refuted",
    "a check-in hands back the appointment, checked in" => "refuted"
  }.freeze

  def self.examples = File.read(File.join(ROOT, "skills", "holdfast", "SKILL.md")).scan(/^```yaml\n(.*?)^```/m).map(&:first)

  def test_every_example_runs_and_ends_as_the_fixture_says
    if ENV["DB_HOST"].to_s.empty?
      flunk "HOLDFAST_PG=required and DB_HOST is not set" if ENV["HOLDFAST_PG"] == "required"
      skip "set DB_HOST and DB_PORT to a PostgreSQL server to run the skill examples"
    end
    examples = self.class.examples
    refute_empty examples
    Dir.mktmpdir("holdfast-skill") do |dir|
      app = File.join(dir, "clinic")
      FileUtils.cp_r(File.join(__dir__, "fixture", "clinic"), app)
      git = ->(*args) { Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", *args, chdir: app) }
      git.("init", "-q", "-b", "main")
      git.("add", "-A")
      git.("commit", "-qm", "clinic")
      files = examples.each_with_index.map { |text, i| File.join(dir, "example#{i + 1}.yml").tap { File.write(_1, text) } }
      out, status = Open3.capture2e({ "BUNDLE_GEMFILE" => File.join(app, "Gemfile") }, RbConfig.ruby, File.join(ROOT, "bin", "holdfast"), "check", *files, "--here", chdir: app)
      assert_includes [0, 2], status.exitstatus, out
      assert_includes out, "no change: checks run on the current tree only"
      assert_includes out, "rows: .holdfast/check/main/check.jsonl; kept specs: spec/holdfast/main/"
      rows = File.readlines(File.join(app, out[/^rows: (\S+);/, 1])).map { JSON.parse(_1) }
      says = examples.flat_map { YAML.safe_load(_1.gsub(/^(\s*(?:-\s+)?(?:do|expect):[ \t]+)(?!['"\[{])(\S.*)$/) { "#{$1}'#{$2.gsub("'", "''")}'" }) }.map { _1["says"] }
      assert_equal EXPECTED.keys.sort, says.sort, "every SKILL.md example has an expected row here"
      rows.each do |row|
        refute_equal "could_not_run", row["kind"], "#{row["target"]}: #{row["reason"]}\n#{out}"
        refute_match(/\A\s*:|: \z/, row["reason"].to_s)
        assert_equal EXPECTED.fetch(row["target"]), row["kind"], "#{row["target"]}: #{row["reason"]}"
      end
    end
  end
end
