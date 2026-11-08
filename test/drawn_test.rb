# Whether the tests that ran a changed method drew what the change added,
# read from the reach the recorder writes, with no database.
require "minitest/autorun"
require "prism"
require_relative "../lib/holdfast"

class DrawnTest < Minitest::Test
  Source = Struct.new(:path)
  Outcome = Struct.new(:source, :test)

  SOURCE = <<~RUBY
    class PlanChange
      def call
        return :refused if @target.archived?
        :done
      end
    end
  RUBY

  def need
    line, arm, = Holdfast::Drawn.branches(Prism.parse(SOURCE).value, [3]).first
    Holdfast::Drawn::Need.new(value: nil, file: "app/services/plan_change.rb", line:, arm:, why: "added")
  end

  # Every run of `return x if y` runs its line, so the line says nothing
  # about the body; only the arm the recorder saw taken does.
  def test_a_same_line_branch_counts_only_when_its_arm_was_taken
    file = "app/services/plan_change.rb"
    arms = Holdfast::Stages::Diff::ARMS + file
    passed_by = Outcome.new(Source.new("spec/a_spec.rb"), { "line" => 4 })
    took = Outcome.new(Source.new("spec/b_spec.rb"), { "line" => 9 })
    reach = {
      "spec/a_spec.rb" => { "2" => { file => [3, 4], arms => ["3:4-3:20"] } },
      "spec/b_spec.rb" => { "2" => { file => [3], arms => [need.arm] } }
    }

    assert_equal [need], Holdfast::Drawn.missing([need], [passed_by], reach)
    assert_empty Holdfast::Drawn.missing([need], [took], reach)
  end

  # One file holds the examples that agree and the one the change added;
  # the file's union must not lend the new example's arm to the others.
  def test_an_example_is_judged_by_its_own_lines_when_they_were_kept
    file = "app/services/plan_change.rb"
    arms = Holdfast::Stages::Diff::ARMS + file
    old = Outcome.new(Source.new("spec/plan_change_spec.rb"), { "line" => 4 })
    added = Outcome.new(Source.new("spec/plan_change_spec.rb"), { "line" => 44 })
    reach = {
      "spec/plan_change_spec.rb" => { "2" => { file => [3, 4], arms => [need.arm] } },
      "spec/plan_change_spec.rb:4" => { "2" => { file => [3, 4], arms => [] } },
      "spec/plan_change_spec.rb:44" => { "2" => { file => [3], arms => [need.arm] } }
    }

    assert_equal [need], Holdfast::Drawn.missing([need], [old], reach)
    assert_empty Holdfast::Drawn.missing([need], [added], reach)
    assert_equal [3, 4], Holdfast::Stages::Diff.ran(reach, Outcome.new(Source.new("spec/plan_change_spec.rb"), { "line" => 7 }), "2")[file]
  end
end
