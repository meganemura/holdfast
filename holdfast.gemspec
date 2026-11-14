# frozen_string_literal: true

require_relative "lib/holdfast/version"

Gem::Specification.new do |spec|
  spec.name = "holdfast"
  spec.version = Holdfast::VERSION
  spec.authors = ["meganemura"]
  spec.email = ["meganemura@users.noreply.github.com"]
  spec.summary = "Run what you suspect in a Rails app on base and head, and keep the spec that proves it."
  spec.description = "holdfast turns each suspicion an agent writes about a Rails app (a bug, a race, an effect on another area) into a spec built with the app's factories, runs it on base and head, and answers confirmed, refuted, or could_not_run. It also checks a change against its base and hunts with random sequences of the app's entry points when nothing changed."
  spec.homepage = "https://github.com/meganemura/holdfast"
  spec.license = "MIT"
  # hegeltest needs Ruby 3.4, and the hunt uses `it` block parameters.
  spec.required_ruby_version = ">= 3.4"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").select do |path|
      # sig/ holds the generated signatures; sig-deps/ stays out of the gem.
      # The runtime and sequences scripts run inside an app's test process,
      # not under require "holdfast", and their signatures declare top-level
      # helpers on Object, so a user's own type check never loads them.
      next false if path.start_with?("sig/generated/holdfast/runtime/", "sig/generated/holdfast/sequences/")

      path.start_with?("bin/", "lib/", "sig/", "skills/") || %w[LICENSE README.md README.ja.md].include?(path)
    end
  end
  spec.bindir = "bin"
  spec.executables = ["holdfast"]
  spec.add_dependency "hegeltest", Holdfast::HEGELTEST_VERSION
  # holdfast run compares a change through these two.
  spec.add_dependency "jitcatch", "~> 0.1"
  spec.add_dependency "branchout", "~> 0.1"
end
