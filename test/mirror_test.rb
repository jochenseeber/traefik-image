# frozen_string_literal: true

require "fileutils"
require "time"
require_relative "test_helper"

class MirrorTest < Minitest::Test
  UPSTREAM_TAGS = %w[v3.7.15 3.7.15 v3.7 v3 latest v3.8.0-rc1 v2.11.59 v3.7.9 v3.7.10
                     v3.7.15-nanoserver-ltsc2025].freeze
  UPSTREAM_DIGEST = "sha256:#{"d" * 64}".freeze
  MOVED_CHECKSUM = "sha256:#{"e" * 64}".freeze
  PUBLISHED_DIGEST = "sha256:#{"f" * 64}".freeze
  ROOT = File.expand_path("..", __dir__)

  # Tags per repository and digests per [repository, tag]
  class FakeRegistry
    def initialize(tags:, digests: {})
      @tags = tags
      @digests = digests
    end

    def tags(repository)
      @tags.fetch(repository, [])
    end

    def digest(repository, tag)
      @digests[[repository, tag]]
    end
  end

  # Answers with the pinned plugin unless a test moved it
  class FakePluginSource
    def initialize(moved = {})
      @moved = moved
    end

    def newest(plugin)
      @moved.fetch(plugin.name, plugin)
    end
  end

  # Gives `git worktree add` a directory holding this repository's source files,
  # and records the tree `rake test` would have built
  class WorktreeCommands < FakeCommands
    attr_reader :tested

    def initialize(captures: {}, fail_test: false, rakefile_edits: {}, &)
      super(captures: captures, &)
      @fail_test = fail_test
      @rakefile_edits = rakefile_edits
      @tested = []
    end

    def execute(*arguments, **options)
      super
      case arguments
      in ["git", "worktree", "add", "--quiet", "--detach", directory, _start]
        FileUtils.mkdir_p(directory)
        %w[Rakefile Dockerfile README.md deployment.yml].each { |name| FileUtils.cp(File.join(ROOT, name), directory) }
        edit_rakefile(File.join(directory, "Rakefile"))
      in ["rake", "test"]
        raise "rake test failed" if @fail_test

        @tested << SourceTree.new(options.fetch(:chdir)).read
      else
        nil
      end
    end

    private

    # Lets a test start from a plugin pin the repository does not hold
    def edit_rakefile(path)
      File.write(path, @rakefile_edits.reduce(File.read(path)) { |text, (from, to)| text.sub(from, to) })
    end
  end

  def test_versions_are_release_tags_at_or_above_the_floor_oldest_first
    assert_equal %w[3.7.10 3.7.15], mirror.versions.map(&:to_s)
  end

  def test_released_revisions_count_git_tags_and_published_images
    commands = FakeCommands.new(captures: { ["git", "tag", "--list", "v3.7.10-scratch.*"] => "v3.7.10-scratch.0\n" })
    registry = registry(published: %w[3.7.10-scratch.2 v3.7.10 3.7.10])

    assert_equal [0, 2], mirror(commands: commands, registry: registry).released_revisions(Gem::Version.new("3.7.10")).sort
  end

  def test_plan_lists_every_version_with_its_line
    commands = FakeCommands.new(captures: { ["git", "tag", "--list", "v3.7.10-scratch.*"] => "v3.7.10-scratch.0\n" })

    output, = capture_io { mirror(commands: commands).plan }

    assert_equal "3.7.10: branch 3.7.10-scratch.x, latest v3.7.10-scratch.0\n" \
                 "3.7.15: branch 3.7.15-scratch.x, nothing released\n", output
  end

  def test_dry_run_verifies_the_next_revision_without_committing_or_publishing
    commands = WorktreeCommands.new(captures: { ["git", "tag", "--list", "v3.7.10-scratch.*"] => "v3.7.10-scratch.0\n" })
    registry = registry(published: %w[3.7.10-scratch.2 v3.7.10 3.7.10])

    capture_io { mirror(commands: commands, registry: registry).sync(Gem::Version.new("3.7.10"), dry_run: true) }

    assert_equal 1, commands.tested.size
    release = commands.tested.first
    assert_equal "3.7.10", release.traefik_version
    assert_equal UPSTREAM_DIGEST, release.base_digest
    assert_equal 3, release.revision
    assert_equal [%w[git worktree add], %w[rake test], %w[git worktree remove]],
                 commands.executed.map { |arguments| arguments.first(3) }
    assert_equal "HEAD", commands.executed.first.last
  end

  def test_release_commits_tags_pushes_and_dispatches_in_order
    commands = WorktreeCommands.new(captures: { ["git", "status", "--porcelain"] => " M Rakefile\n" }) do |arguments|
      %([{"databaseId": 42, "createdAt": "#{Time.now.utc.iso8601}"}]) if arguments.first(3) == %w[gh run list]
    end

    capture_io { mirror(commands: commands).sync(Gem::Version.new("3.7.10"), dry_run: false) }

    steps = commands.executed.drop(2).map { |arguments| arguments.reject { |argument| argument.include?("\n") } }
    assert_equal [
      %w[git commit --all --quiet --message],
      ["git", "tag", "--annotate", "v3.7.10-scratch.0", "--message", "Traefik 3.7.10 on scratch with local plugins"],
      %w[git push origin HEAD:refs/heads/3.7.10-scratch.x],
      %w[git push origin refs/tags/v3.7.10-scratch.0],
      %w[gh workflow run release.yml --ref v3.7.10-scratch.0],
      %w[gh run watch 42 --exit-status --interval 30],
    ], steps.first(6)
    assert_equal %w[git worktree remove], commands.executed.last.first(3)
  end

  def test_commit_message_lists_the_changes
    commands = WorktreeCommands.new(captures: { ["git", "status", "--porcelain"] => " M Rakefile\n" }) do |arguments|
      %([{"databaseId": 42, "createdAt": "#{Time.now.utc.iso8601}"}]) if arguments.first(3) == %w[gh run list]
    end
    moved = IMAGE.plugin("rewritebody").with(version: "v0.4.0", checksum: MOVED_CHECKSUM)

    capture_io do
      mirror(commands: commands, plugin_source: FakePluginSource.new("rewritebody" => moved))
        .sync(Gem::Version.new("3.7.10"), dry_run: false)
    end

    message = commands.executed.find { |arguments| arguments.first(2) == %w[git commit] }.last
    assert_equal "chore: release 3.7.10-scratch.0\n\n" \
                 "- Traefik 3.7.15 -> 3.7.10\n" \
                 "- base #{IMAGE.base_digest} -> #{UPSTREAM_DIGEST}\n" \
                 "- rewritebody v0.3.1 -> v0.4.0\n", message
  end

  def test_a_moved_plugin_checksum_is_a_new_revision
    commands = WorktreeCommands.new(captures: { ["git", "tag", "--list", "v3.7.15-scratch.*"] => "v3.7.15-scratch.0\n" })
    moved = IMAGE.plugin("staticresponse").with(checksum: MOVED_CHECKSUM)

    output, = capture_io do
      mirror(commands: commands, registry: registry(upstream_digest: IMAGE.base_digest),
             plugin_source: FakePluginSource.new("staticresponse" => moved))
        .sync(Gem::Version.new("3.7.15"), dry_run: true)
    end

    assert_equal 1, commands.tested.first.revision
    assert_equal moved, commands.tested.first.plugins.find { |plugin| plugin.name == "staticresponse" }
    assert_includes output, "staticresponse v0.0.1 checksum #{IMAGE.plugin("staticresponse").checksum} -> #{MOVED_CHECKSUM}"
  end

  def test_an_unchanged_released_line_is_left_alone
    captures = {
      ["git", "tag", "--list", "v3.7.15-scratch.*"] => "v3.7.15-scratch.0\n",
      ["git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/3.7.15-scratch.x"] => "abc\n",
    }
    commands = WorktreeCommands.new(captures: captures)
    registry = registry(upstream_digest: IMAGE.base_digest, published: %w[3.7.15-scratch.0],
                        digests: { ["jochen/traefik", "3.7.15-scratch.0"] => PUBLISHED_DIGEST })

    output, = capture_io { mirror(commands: commands, registry: registry).sync(Gem::Version.new("3.7.15"), dry_run: false) }

    assert_includes output, "3.7.15: up to date at v3.7.15-scratch.0"
    assert_empty commands.tested
    assert_equal [%w[git worktree add], %w[git worktree remove]], commands.executed.map { |arguments| arguments.first(3) }
    assert_equal "origin/3.7.15-scratch.x", commands.executed.first.last
  end

  def test_a_plugin_that_moved_backwards_stops_the_run_without_committing_or_tagging
    commands = WorktreeCommands.new do |arguments|
      %([{"databaseId": 42, "createdAt": "#{Time.now.utc.iso8601}"}]) if arguments.first(3) == %w[gh run list]
    end
    older = IMAGE.plugin("rewritebody").with(version: "v0.2.0", checksum: MOVED_CHECKSUM)
    source = FakePluginSource.new("rewritebody" => older)

    error = assert_raises(Mirror::Error) do
      capture_io { mirror(commands: commands, plugin_source: source).sync(Gem::Version.new("3.7.10"), dry_run: false) }
    end

    assert_match %r{rewritebody.*v0\.2\.0.*older than.*v0\.3\.1}, error.message
    assert_nothing_released commands
  end

  def test_a_plugin_pinned_to_something_but_a_release_tag_stops_the_run_without_committing_or_tagging
    commands = WorktreeCommands.new(rakefile_edits: { 'version: "v0.3.1"' => 'version: "main"' }) do |arguments|
      %([{"databaseId": 42, "createdAt": "#{Time.now.utc.iso8601}"}]) if arguments.first(3) == %w[gh run list]
    end

    error = assert_raises(Mirror::Error) do
      capture_io { mirror(commands: commands).sync(Gem::Version.new("3.7.10"), dry_run: false) }
    end

    assert_match %r{rewritebody.*"main".*vX\.Y\.Z}, error.message
    assert_nothing_released commands
  end

  def test_an_up_to_date_line_whose_image_is_not_published_is_released_again
    captures = {
      ["git", "tag", "--list", "v3.7.15-scratch.*"] => "v3.7.15-scratch.0\n",
      ["git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/3.7.15-scratch.x"] => "abc\n",
    }
    commands = WorktreeCommands.new(captures: captures) do |arguments|
      %([{"databaseId": 42, "createdAt": "#{Time.now.utc.iso8601}"}]) if arguments.first(3) == %w[gh run list]
    end
    registry = registry(upstream_digest: IMAGE.base_digest, published: %w[3.7.15-scratch.0])

    output, = capture_io { mirror(commands: commands, registry: registry).sync(Gem::Version.new("3.7.15"), dry_run: false) }

    assert_includes output, "jochen/traefik:3.7.15-scratch.0 is not published"
    assert_empty commands.tested
    assert_includes commands.executed, %w[gh workflow run release.yml --ref v3.7.15-scratch.0]
    refute(commands.executed.any? { |arguments| arguments.first(2) == %w[git commit] })
  end

  def test_a_release_with_nothing_to_commit_is_tagged_without_a_commit
    commands = WorktreeCommands.new(captures: { ["git", "status", "--porcelain"] => "" }) do |arguments|
      %([{"databaseId": 42, "createdAt": "#{Time.now.utc.iso8601}"}]) if arguments.first(3) == %w[gh run list]
    end

    capture_io do
      mirror(commands: commands, registry: registry(upstream_digest: IMAGE.base_digest))
        .sync(Gem::Version.new("3.7.15"), dry_run: false)
    end

    refute(commands.executed.any? { |arguments| arguments.first(2) == %w[git commit] })
    assert(commands.executed.any? { |arguments| arguments.first(3) == %w[git tag --annotate] })
  end

  def test_sync_all_stops_at_the_first_failure
    commands = WorktreeCommands.new(fail_test: true)

    assert_raises(RuntimeError) { capture_io { mirror(commands: commands).sync_all(dry_run: true) } }

    added = commands.executed.select { |arguments| arguments.first(3) == %w[git worktree add] }
    assert_equal 1, added.size
  end

  private

  def assert_nothing_released(commands)
    verbs = commands.executed.map { |arguments| arguments.first(2) }
    assert_empty commands.tested
    refute_includes verbs, %w[git commit]
    refute_includes verbs, %w[git tag]
    refute_includes verbs, %w[git push]
    assert_equal %w[git worktree remove], commands.executed.last.first(3)
  end

  def mirror(commands: FakeCommands.new, registry: self.registry, plugin_source: FakePluginSource.new)
    Mirror.new(upstream: "library/traefik", repository: "jochen/traefik", floor: "3.7.10",
               release_workflow: "release.yml", registry: registry, plugin_source: plugin_source, commands: commands)
  end

  def registry(published: [], upstream_digest: UPSTREAM_DIGEST, digests: {})
    upstream = %w[3.7.10 3.7.15].to_h { |version| [["library/traefik", "v#{version}"], upstream_digest] }
    FakeRegistry.new(tags: { "library/traefik" => UPSTREAM_TAGS, "jochen/traefik" => published },
                     digests: upstream.merge(digests))
  end
end
