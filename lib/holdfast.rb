# rbs_inline: enabled

# holdfast checks a Rails app by running it. `holdfast check` turns what an
# agent suspects into specs and runs them on base and head. `holdfast run`
# looks at the working tree against a base and decides what runs: it selects
# the targets and their tests, drafts and fills missing pins, compares base
# and head, and hunts when nothing changed. Every tool result becomes
# evidence under one row per target; no tool's own output reaches the caller.
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require "erb"
require "yaml"
require "prism"

module Holdfast
  # @rbs!
  #   # A parsed JSON object: what record.json, a jitcatch brief, a test
  #   # result or a hunt table holds. Its values are whatever the file says.
  #   type json = Hash[String, untyped]
  #
  #   # One value of such a document, where a reader keeps it whole (a hunt
  #   # line's outcome or writes) and only prints or compares it.
  #   type json_value = nil | bool | Integer | Float | String | Array[json_value] | Hash[String, json_value]
  #
  #   # A value YAML.safe_load reads with no permitted classes: a suspicion
  #   # file or a --suspect mapping.
  #   type yaml = nil | bool | Integer | Float | String | Array[yaml] | Hash[yaml, yaml]
  #
  #   # file => { "base" => [lines], "head" => [lines] } a diff changed.
  #   type changed_lines = Hash[String, Hash[String, Array[Integer]]]
  #
  #   # test => side ("1" base, "2" head) => file => what that test ran on
  #   # that side: line numbers, or under the "(drew)" and "(arms)" keys the
  #   # values its inputs wrote and the branch arms it took.
  #   type reach = Hash[String, Hash[String, Hash[String, Array[json_value]]]]
  #
  #   class Error < StandardError
  #   end

  # @rbs skip
  Error = Class.new(StandardError)

  # Loaded into the app's own test processes by path, never required here.
  # __dir__ is nil only in code that eval reads, never in a file.
  HERE = __dir__ #: String
  RUNTIME = File.expand_path("holdfast/runtime", HERE) #: String
  SEQUENCES = File.expand_path("holdfast/sequences", HERE) #: String

  #: (String) -> String
  def self.dir(root) = File.join(root, ".holdfast")
  #: (String) -> String
  def self.slug(name) = name.gsub(/[^\w]+/, "-").gsub(/\A-|-\z/, "").downcase
  #: (String) -> String
  def self.snake(name) = name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
end

require_relative "holdfast/version"
require_relative "holdfast/tools"
require_relative "holdfast/verdict"
require_relative "holdfast/record"
require_relative "holdfast/change"
require_relative "holdfast/inputs"
require_relative "holdfast/draft"
require_relative "holdfast/callers"
require_relative "holdfast/drawn"
require_relative "holdfast/stages/select"
require_relative "holdfast/stages/fill"
require_relative "holdfast/stages/diff"
require_relative "holdfast/stages/fold"
require_relative "holdfast/stages/hunt"
require_relative "holdfast/stages/observe"
require_relative "holdfast/harness"
require_relative "holdfast/check"
require_relative "holdfast/cli"
