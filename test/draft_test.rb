# Drafts of a scope whose body a draft cannot fill, read without a repository.
require "minitest/autorun"
require_relative "../lib/holdfast"

class DraftTest < Minitest::Test
  def draft(name, source)
    target = Holdfast::Target.new(name:, kind: "method", file: "app/models/hold.rb", line: 1, why: ["modified"],
                                  tests: [], source:, reader: nil, span: {})
    change = Holdfast::Change.new(root: "/nonexistent", base: "a", head: "b", base_label: "main", mode: "change", named: [])
    Holdfast::Draft.for(change, "a", target)
  end

  def test_a_scope_given_as_a_block_argument_has_no_body_to_draft
    result = draft("Hold.open", "scope :open, &OPEN")
    assert_nil result.path
    assert_equal ["no def found for open"], result.holes
  end

  def test_a_scope_that_reads_it_or_a_numbered_parameter_asks_for_inputs
    ["scope :since, -> { where(\"created_at > ?\", it) }", "scope :since, -> { where(\"created_at > ?\", _1) }"].each do |source|
      result = draft("Hold.since", source)
      assert_nil result.path
      assert_match(/takes `_1` or `it` parameters/, result.holes.first)
    end
  end
end
