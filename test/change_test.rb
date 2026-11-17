# Reading a change from a repository, with the real git and no database.
require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../lib/holdfast"

class ChangeTest < Minitest::Test
  # A CI runner often has no git identity. The snapshot of an uncommitted
  # working tree must still work there.
  def test_an_uncommitted_edit_is_read_without_a_git_identity
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app"))
      File.write(File.join(app, "app", "a.rb"), "A = 1\n")
      git = ->(*args) { Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", *args, chdir: app) }
      git.("init", "-q", "-b", "main")
      git.("add", ".")
      git.("commit", "-q", "-m", "base")
      File.write(File.join(app, "app", "a.rb"), "A = 2\n")

      saved = ENV.to_h.slice("HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "EMAIL")
      begin
        ENV["HOME"] = dir
        ENV["GIT_CONFIG_GLOBAL"] = File::NULL
        ENV["GIT_CONFIG_NOSYSTEM"] = "1"
        ENV.delete("EMAIL")
        change = Holdfast::Change.read(app, base_ref: "HEAD", named: [])
      ensure
        %w[HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM EMAIL].each { saved.key?(_1) ? ENV[_1] = saved[_1] : ENV.delete(_1) }
      end

      assert_equal "change", change.mode
      shown, = Open3.capture2("git", "show", "#{change.head}:app/a.rb", chdir: app)
      assert_equal "A = 2\n", shown
    end
  end

  # holdfast's own folder holds databases a running test opens and drops
  # (SQLite's -shm and -wal files) and checkouts of its own. Adding it
  # failed when one of them vanished or could not be added, and the
  # snapshot never needed it.
  def test_the_snapshot_never_adds_holdfasts_own_folder
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "app"))
      File.write(File.join(app, "app", "a.rb"), "A = 1\n")
      git = ->(*args) { Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.test", *args, chdir: app) }
      git.("init", "-q", "-b", "main")
      git.("add", ".")
      git.("commit", "-q", "-m", "base")
      File.write(File.join(app, "app", "a.rb"), "A = 2\n")
      # git refuses to add a repository with no commit, as it refuses a file that vanished.
      nested = File.join(app, ".holdfast", "runs", "w")
      FileUtils.mkdir_p(nested)
      Open3.capture2e("git", "init", "-q", chdir: nested)
      File.write(File.join(nested, "f"), "")

      change = Holdfast::Change.read(app, base_ref: "HEAD", named: [])

      shown, = Open3.capture2("git", "show", "#{change.head}:app/a.rb", chdir: app)
      assert_equal "A = 2\n", shown
    end
  end
end
