# rbs_inline: enabled

module Holdfast
  # What one run looks at: the base whose behavior must survive, the head
  # (the working tree as it is now, committed or not), and so which mode the
  # harness runs in. The working tree is snapshotted into a commit object
  # through a private index, so the caller's index and stash stay untouched.
  Change = Data.define(
    :root, #: String
    :base, #: String
    :head, #: String
    :base_label, #: String
    :mode, #: String
    :named #: Array[String]
  )

  # The paths whose edits change what the app does.
  CODE = %w[app lib config db Gemfile Gemfile.lock].freeze #: Array[String]

  class Change
    # @rbs root: String
    # @rbs base_ref: String
    # @rbs named: Array[String]
    # @rbs return: Change
    def self.read(root, base_ref:, named:)
      base_sha = git(root, "merge-base", base_ref, "HEAD")
      head_sha = snapshot(root)
      same = git(root, "rev-parse", "#{base_sha}^{tree}") == git(root, "rev-parse", "#{head_sha}^{tree}")
      # Edits only to tests, factories or docs change no behavior the app
      # has, so they neither make a change run nor stop a hunt.
      code = git(root, "diff", "--name-only", base_sha, head_sha, "--", *CODE).lines.map(&:strip).reject(&:empty?)
      same ||= code.empty?
      mode = if !same then "change"
             elsif named.any? then "before"
             else "hunt"
             end
      new(root:, base: base_sha, head: head_sha, base_label: base_ref, mode:, named:)
    end

    #: (String) -> String
    def self.snapshot(root)
      dirty = !git(root, "status", "--porcelain", "--untracked-files=all", "--", ".", ":!.holdfast").empty?
      return git(root, "rev-parse", "HEAD") unless dirty

      index = File.join(Dir.mktmpdir("holdfast-index"), "index")
      env = { "GIT_INDEX_FILE" => index }
      git(root, "read-tree", "HEAD", env:)
      git(root, "add", "-A", env:)
      git(root, "rm", "-r", "--cached", "--quiet", "--ignore-unmatch", ".holdfast", env:)
      tree = git(root, "write-tree", env:)
      # The commit stays private to this run, so it needs no identity from the user and must not fail without one.
      who = { "GIT_AUTHOR_NAME" => "holdfast", "GIT_AUTHOR_EMAIL" => "holdfast@localhost",
              "GIT_COMMITTER_NAME" => "holdfast", "GIT_COMMITTER_EMAIL" => "holdfast@localhost" }
      git(root, "commit-tree", tree, "-p", "HEAD", "-m", "holdfast: working tree", env: env.merge(who))
    ensure
      FileUtils.rm_rf(File.dirname(index)) if index
    end

    #: (String root, *String args, ?env: Hash[String, String]) -> String
    def self.git(root, *args, env: {})
      out, err, status = Open3.capture3(env, "git", *args, chdir: root)
      raise Holdfast::Error, "git #{args.join(" ")}: #{err.lines.first.to_s.strip}" unless status.success?

      out.strip
    end

    #: () -> bool
    def changed? = mode == "change"
    #: (String) -> String
    def short(sha) = sha[0, 7] #: String

    # A dirty tree's snapshot is a commit no `git log` shows; the reader
    # gets the commit it sits on instead.
    #: () -> String
    def tree_label
      committed = Change.git(root, "rev-parse", "HEAD")
      committed == head ? short(head) : "uncommitted changes on #{short(committed)}"
    end

    #: () -> String
    def header
      case mode
      when "change" then "change: #{base_label} (#{short(base)}) .. working tree (#{tree_label})"
      when "before" then "before a change: pinning #{named.join(", ")} at #{tree_label}"
      else "#{Change.git(root, "diff", "--quiet", base, head).then { "" } rescue "only tests, factories or docs differ from #{base_label}; " }nothing in the app changed against #{base_label} (#{short(base)})"
      end
    end
  end
end
