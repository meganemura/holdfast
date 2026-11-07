module Holdfast
  # jitcatch and branchout are not on RubyGems yet, so the gemspec cannot
  # depend on them. `holdfast check` and the hunt need neither; the stages
  # of `holdfast run` that do ask here and get a message that says what to
  # install instead of a LoadError.
  module Tools
    SOURCES = {
      "jitcatch" => "https://github.com/meganemura/jitcatch",
      "branchout" => "https://github.com/meganemura/branchout"
    }.freeze

    def self.missing(name, use)
      "#{use} needs the #{name} gem, which is not on RubyGems yet: " \
        "build it from #{SOURCES.fetch(name)} (`gem build #{name}.gemspec`, then `gem install ./#{name}-*.gem`), " \
        "and add it to the app's Gemfile when you run holdfast with bundle exec; holdfast check and a hunt work without it"
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
