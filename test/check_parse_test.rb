# The suspicion file forms an agent writes, read without a database.
require "minitest/autorun"
require "tempfile"
require_relative "../lib/holdfast"

class CheckParseTest < Minitest::Test
  def parse(text)
    Tempfile.create(["s", ".yml"]) do |f|
      f.write(text)
      f.flush
      Holdfast::Check.parse([f.path], [])
    end
  end

  def test_ruby_with_colons_in_a_race_list_a_flow_list_and_a_given_value
    s = parse(<<~YAML).first
      - says: two bookings
        given:
          room: {}
          slot: Date.current.change(hour: 10)
        race:
          - RoomDesk.new.book(room: room, starts_at: slot)
          - RoomDesk.new.book(room: room, starts_at: slot)
        expect: [results.compact.size == 1, calls(PaymentGateway, :charge).empty?]
    YAML
    assert_equal ["RoomDesk.new.book(room: room, starts_at: slot)"] * 2, s.acts
    assert_equal ["results.compact.size == 1", "calls(PaymentGateway, :charge).empty?"], s.expects.map { _1[:text] }
    assert_equal "Date.current.change(hour: 10)", s.given["slot"]
    assert_nil s.pause
  end

def test_a_flow_list_of_shorthand_and_ruby
  s = parse(%(- says: x\n  do: a\n  expect: [no error, result == 1, "CheckIn.new(a).call", "a" == b]\n)).first
  assert_equal ["no error", "result == 1", "CheckIn.new(a).call", %("a" == b)], s.expects.map { _1[:text] }
end

def test_ruby_in_place_of_the_attributes_and_plain_values_build_without_a_factory
    lines = Holdfast::Check.given_lines({ "a" => { "ruby" => "create(:member)" }, "n" => 3, "t" => '"tok"', "m" => { "status" => "x", "since" => "-1h" } })
    assert_equal ['build :a, "create(:member)" do create(:member) end', 'build :n, "3" do 3 end', "build :t, \"\\\"tok\\\"\" do \"tok\" end",
                  'make :m, status: "x", since: 1.hour.ago'], lines
  end

  def test_a_compound_expectation_keeps_its_operands
    e = Holdfast::Check.expectation("a.b == 1 && (c || d) && e.f > 2")
    assert_equal [["a.b == 1", "a.b == 1", "a.b"], ["(c || d)", "(c || d)", "(c || d)"], ["e.f > 2", "e.f > 2", "e.f"]], e[:parts]
    assert_nil e[:observe]
    assert_equal "a.b", Holdfast::Check.expectation("a.b == 1")[:observe]
    assert_empty Holdfast::Check.expectation("a.b == 1")[:parts]
  end

  def test_short_forms_combine_with_and_and_or
    e = Holdfast::Check.expectation('no error && fine.status == "waived"')
    assert_equal '(error.nil?) && fine.status == "waived"', e[:ruby]
    assert_equal [["no error", "error.nil?", "error"], ['fine.status == "waived"', 'fine.status == "waived"', "fine.status"]], e[:parts]
    assert e[:errors]
    e = Holdfast::Check.expectation("no PaymentGateway refund || PaymentGateway charge twice")
    assert_equal "(calls(PaymentGateway, :refund).empty?) || (calls(PaymentGateway, :charge).size == 2)", e[:ruby]
    assert_equal [%w[PaymentGateway refund], %w[PaymentGateway charge]], e[:calls]
    e = Holdfast::Check.expectation("raises Fine::NotWaivable || x.y(a && b) == 1")
    assert_equal "(error.is_a?(Fine::NotWaivable)) || x.y(a && b) == 1", e[:ruby]
  end

  def test_a_flow_list_item_combines_short_forms
    s = parse(%(- says: x\n  do: a\n  expect: [no error && PaymentGateway charge once, no PaymentGateway refund || b == "x || y"]\n)).first
    assert_equal ["(error.nil?) && (calls(PaymentGateway, :charge).size == 1)", %{(calls(PaymentGateway, :refund).empty?) || b == "x || y"}], s.expects.map { _1[:ruby] }
  end

  def test_do_and_expect_share_locals_and_ivars
    s = parse(%(- says: x\n  given: {fine: {}}\n  do: "payment = fine.pay; @n = 1; fine = 2"\n  expect: payment.ok? && @n == 1\n)).first
    assert_equal %i[payment], s.shared
    spec = Holdfast::Check.spec(s, Struct.new(:helper).new("rails_helper"))
    assert_includes spec, "payment = nil # set by `do`, read by `expect`"
    assert_includes spec, "shared: binding,"
    error = assert_raises(Holdfast::Error) { parse(%(- says: x\n  do: a.call\n  expect: "@payment.ok?"\n)) }
    assert_match(/`expect` reads @payment, which no `do` sets/, error.message)
  end

  def test_a_line_that_is_not_ruby_is_refused_before_anything_runs
    error = assert_raises(Holdfast::Error) { parse("- says: x\n  do: a.call(\n  expect: no error\n") }
    assert_match(/suspicion 1 \(x\): `do` is not Ruby/, error.message)
  end

  def test_a_given_that_is_not_a_mapping_is_refused_by_name
    ["member", "[member, loan]"].each do |given|
      error = assert_raises(Holdfast::Error) { parse("- says: x\n  given: #{given}\n  do: a\n  expect: no error\n") }
      assert_match(/suspicion 1: `given` is a mapping of names to records/, error.message)
    end
  end

  # A kept spec from an earlier run is the same file only for the same text.
  def test_a_suspicion_is_named_by_its_text_not_its_place_in_the_file
    alone = parse("- says: the sweep charges\n  do: a\n  expect: no error\n").first
    second = parse("- says: something else\n  do: b\n  expect: no error\n- says: the sweep charges\n  do: a\n  expect: no error\n").last
    assert_equal alone.id, second.id
    refute_equal parse("- says: the sweep charges twice\n  do: a\n  expect: no error\n").first.id, alone.id
    error = assert_raises(Holdfast::Error) { parse("- says: x\n  do: a\n  expect: no error\n- says: x\n  do: b\n  expect: no error\n") }
    assert_match(/two suspicions say "x"/, error.message)
  end
end
