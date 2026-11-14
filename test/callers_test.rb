# The column a changed scope compares with a constant, read without a database.
require "minitest/autorun"
require_relative "../lib/holdfast"

class CallersTest < Minitest::Test
  def test_a_keyword_names_the_column_the_scope_compares
    assert_equal "status", Holdfast::Callers.where_column("scope :open, -> { where(status: OPEN) }", "OPEN")
  end

  def test_a_splatted_constant_names_no_column
    assert_nil Holdfast::Callers.where_column("scope :open, -> { where(**OPEN) }", "OPEN")
    assert_equal "status", Holdfast::Callers.where_column("scope :open, -> { where(**extra, status: OPEN) }", "OPEN")
  end
end
