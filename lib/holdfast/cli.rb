# rbs_inline: enabled

require "optparse"
require "time"
require "prism"

module Holdfast
  # The stated intent belongs to the branch it was given on, so a run on
  # another branch does not show a stale one.
  module Intent
    #: (String root, String? text) -> String?
    def self.keep(root, text)
      path = File.join(Holdfast.dir(root), "intent.json")
      branch = Change.git(root, "rev-parse", "--abbrev-ref", "HEAD")
      File.write(path, JSON.generate({ "branch" => branch, "text" => text })) if text
      kept = JSON.parse(File.read(path)) rescue {} #: json
      kept["branch"] == branch ? kept["text"] : nil
    end
  end

  # `run` is the entry: it decides what to check from the working tree. `show`
  # prints the last summary again. Exit 2 when a row needs a decision
  # (unintended_change or bug_suspect), 1 on a usage error, 0 otherwise.
  module CLI
    USAGE = <<~TEXT #: String
      usage:
        holdfast run [--base REF] [--target NAME]... [--only NAME]... [--intent TEXT] [--learn] [--sequences] [--observe] [--budget SECONDS]
        holdfast check [FILE]... [--suspect YAML]... [--base REF] [--here]
        holdfast show
      run   checks the working tree against REF (default: the record's base branch).
            With nothing changed and --target, it pins NAME's current behavior first.
            With nothing changed and no target, it hunts with sequences (--budget caps the seconds).
            --sequences also hunts over the changed areas, before a pull request.
            --observe runs the areas' action orderings on base and head and reports each step that differs.
      check turns each suspicion (says, given, do or race, expect) into a spec and runs it on base
            and head (or once on the tree with no change, or with --here); confirmed, refuted or could_not_run.
      --repo DIR  run in DIR (default: the working directory)
    TEXT

    # The options by name; each holds the type its flag parses to.
    # @rbs!
    #   type options = Hash[Symbol, untyped]

    #: (Array[String]) -> Integer
    def self.start(argv)
      opts = { repo: Dir.pwd, named: [], only: [], suspects: [] } #: options
      args = OptionParser.new do |o|
        o.on("--repo DIR") { opts[:repo] = File.expand_path(_1) }
        o.on("--base REF") { opts[:base] = _1 }
        o.on("--target NAME") { opts[:named] << _1 }
        o.on("--only NAME") { opts[:only] << _1 }
        o.on("--intent TEXT") { opts[:intent] = _1 }
        o.on("--learn") { opts[:learn] = true }
        o.on("--sequences") { opts[:sequences] = true }
        o.on("--observe") { opts[:observe] = true }
        o.on("--budget SECONDS", Integer) { opts[:budget] = _1 }
        o.on("--suspect YAML") { opts[:suspects] << _1 }
        o.on("--here") { opts[:here] = true }
      end.parse(argv)
      Dir.chdir(opts[:repo]) do
        case args.shift
        when "run" then run(opts)
        when "show" then show
        when "check" then check(opts, args)
        else
          $stderr.puts USAGE
          1
        end
      end
    rescue OptionParser::ParseError, Holdfast::Error, *Tools.errors => e
      $stderr.puts "holdfast: #{e.message}"
      1
    end

    #: (options) -> Integer
    def self.run(opts)
      root = Dir.pwd
      dir = Holdfast.dir(root)
      FileUtils.mkdir_p(dir)
      intent = Intent.keep(root, opts[:intent])
      result = Harness.run(root, base: opts[:base], named: opts[:named], relearn: opts[:learn], only: opts[:only],
                                   sequences: opts[:sequences], budget: opts[:budget], observe: opts[:observe], intent:)
      header = [result.change.header, ("intent: #{intent}" if intent),
                *result.notes.map { "note: #{_1}" },
                "seconds: #{result.seconds.map { "#{_1} #{_2}" }.join(", ")}"].compact
      File.write(File.join(dir, "verdicts.jsonl"), result.verdicts.map(&:to_json_line).join("\n") + "\n")
      File.write(File.join(dir, "summary.md"), Summary.markdown(header, result.verdicts, mode: result.change.mode))
      show
      result.verdicts.any? { %w[unintended_change bug_suspect].include?(_1.kind) } ? 2 : 0
    end

    #: (options opts, Array[String] files) -> Integer
    def self.check(opts, files)
      root = Dir.pwd
      FileUtils.mkdir_p(Holdfast.dir(root))
      rows, header, place = Check.run(root, files: files.map { File.expand_path(_1) }, inline: opts[:suspects], base: opts[:base], here: opts[:here])
      out = File.join(root, place.out)
      FileUtils.mkdir_p(out)
      File.write(File.join(out, "check.jsonl"), rows.map(&:to_json_line).join("\n") + "\n")
      File.write(File.join(out, "check.md"), Summary.markdown(header, rows, rows: "check.jsonl"))
      puts File.read(File.join(out, "check.md"))
      puts "rows: #{place.out}/check.jsonl; kept specs: #{place.specs}/"
      rows.any? { _1.kind == "confirmed" } ? 2 : 0
    end

    #: () -> Integer
    def self.show
      path = File.join(Holdfast.dir(Dir.pwd), "summary.md")
      raise Holdfast::Error, "no run yet; run holdfast run" unless File.file?(path)

      puts File.read(path)
      puts "rows: .holdfast/verdicts.jsonl"
      0
    end
  end
end
