# Commands in one app take turns, and the boot test is a committed one.
# Neither needs a database.
require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../lib/holdfast"

class TurnTest < Minitest::Test
  BIN = File.expand_path("../bin/holdfast", __dir__)

  def test_a_second_command_in_one_app_waits_for_the_first_to_end
    Dir.mktmpdir do |app|
      FileUtils.mkdir_p(File.join(app, ".holdfast"))
      File.open(File.join(app, ".holdfast/turn.lock"), File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        held.write("pid 1, since then")
        held.flush
        out, err, waiter = Open3.popen3(RbConfig.ruby, BIN, "check", "--here", "--suspect", "- says: x", chdir: app).values_at(1, 2, 3)
        line = err.gets
        assert_equal "holdfast: another holdfast command runs in this app (pid 1, since then); this one starts when it ends\n", line
        sleep 0.5
        assert waiter.alive?, "the second command started while the first held its turn"
        held.flock(File::LOCK_UN)
        waiter.value
        out.close
        err.close
      end
      assert_match(/\Apid \d+, since /, File.read(File.join(app, ".holdfast/turn.lock")))
    end
  end

  def test_the_boot_test_is_the_smallest_committed_one
    Dir.mktmpdir do |app|
      FileUtils.mkdir_p(File.join(app, "spec/models"))
      File.write(File.join(app, "spec/models/note_spec.rb"), "describe 'note' do\n  it { expect(1).to eq 1 }\nend\n")
      system("git", "init", "-q", app)
      system("git", "-C", app, "add", ".")
      system("git", "-C", app, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "base")
      FileUtils.mkdir_p(File.join(app, "spec/tmp"))
      File.write(File.join(app, "spec/tmp/a_spec.rb"), "x\n")

      assert_equal "spec/models/note_spec.rb", Holdfast::Record.smallest_test(app, "rspec")
    end
  end
end
