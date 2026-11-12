module Holdfast
  # The stages of `holdfast run` load jitcatch and branchout here, so a
  # bundle that left them out gets a message instead of a LoadError.
  module Tools
    def self.missing(name, use)
      "#{use} needs the #{name} gem, which holdfast depends on: run `bundle install` " \
        "with holdfast in the app's Gemfile, then run holdfast with bundle exec"
    end

    def self.jitcatch!
      require "jitcatch"
    rescue LoadError
      raise Holdfast::Error, missing("jitcatch", "holdfast run on a change")
    end

    # The rescue list of the CLI: JitCatch::Error exists only once jitcatch
    # is loaded.
    def self.errors = defined?(JitCatch::Error) ? [JitCatch::Error] : []

    # branchout runs inside the app's test process, which has the app's
    # bundle and not necessarily branchout, so it is put on the load path by
    # directory. Under bundle exec, Gem::Specification sees only the bundle,
    # so the installed gems are searched by path too.
    def self.branchout_lib
      feature = $LOAD_PATH.resolve_feature_path("branchout") rescue nil
      return File.dirname(feature[1]) if feature

      dirs = Gem.path.flat_map { Dir.glob(File.join(_1, "gems", "branchout-*", "lib")) }
      found = dirs.max_by { Gem::Version.new(_1[%r{branchout-([\d.]+)/lib\z}, 1] || "0") }
      found or raise Holdfast::Error, missing("branchout", "pinning a target")
    end
  end
end
