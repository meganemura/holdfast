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
  Error = Class.new(StandardError)

  # Loaded into the app's own test processes by path, never required here.
  RUNTIME = File.expand_path("holdfast/runtime", __dir__)
  SEQUENCES = File.expand_path("holdfast/sequences", __dir__)

  def self.dir(root) = File.join(root, ".holdfast")
  def self.slug(name) = name.gsub(/[^\w]+/, "-").gsub(/\A-|-\z/, "").downcase
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
