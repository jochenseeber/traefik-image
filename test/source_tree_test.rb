# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "test_helper"

class SourceTreeTest < Minitest::Test
  FILES = %w[Rakefile Dockerfile README.md deployment.yml].freeze
  ROOT = File.expand_path("..", __dir__)
  NEW_CHECKSUM = "sha256:#{"a" * 64}".freeze

  def setup
    @directory = Dir.mktmpdir("source-tree-test-")
    FILES.each { |name| FileUtils.cp(File.join(ROOT, name), @directory) }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_read_matches_the_image_literal
    release = tree.read

    assert_equal IMAGE.traefik_version, release.traefik_version
    assert_equal IMAGE.base_digest, release.base_digest
    assert_equal IMAGE.revision, release.revision
    assert_equal IMAGE.plugins, release.plugins
    assert_equal IMAGE.version, release.version
  end

  def test_repository_is_the_image_repository
    assert_equal "jochen/traefik", tree.repository
  end

  def test_write_round_trips
    changed = tree.read.with(revision: 4, traefik_version: "3.7.12")

    tree.write(changed)

    assert_equal changed, tree.read
  end

  def test_write_updates_readme_and_deployment
    tree.write(tree.read.with(revision: 4, traefik_version: "3.7.12"))

    assert_includes read("README.md"), "Published as **`jochen/traefik:3.7.12-scratch.4`**."
    assert_includes read("deployment.yml"), "        image: jochen/traefik:3.7.12-scratch.4\n"
  end

  def test_write_updates_dockerfile_arguments
    release = tree.read
    plugins = release.plugins.map do |plugin|
      plugin.name == "rewritebody" ? plugin.with(version: "v0.4.0", checksum: NEW_CHECKSUM) : plugin
    end

    tree.write(release.with(traefik_version: "3.7.12", revision: 1, plugins: plugins))

    dockerfile = read("Dockerfile")
    assert_includes dockerfile, "\nARG TRAEFIK_VERSION=3.7.12\n"
    assert_includes dockerfile, "\nARG IMAGE_VERSION=3.7.12-scratch.1\n"
    assert_includes dockerfile, "\nARG REWRITEBODY_VERSION=v0.4.0\n"
    assert_includes dockerfile, "\nARG REWRITEBODY_CHECKSUM=#{NEW_CHECKSUM}\n"
    assert_includes dockerfile, "\nARG STATICRESPONSE_VERSION=v0.0.1\n"
  end

  def test_write_moves_only_the_named_plugin
    release = tree.read
    plugins = release.plugins.map do |plugin|
      plugin.name == "rewritebody" ? plugin.with(version: "v0.4.0", checksum: NEW_CHECKSUM) : plugin
    end

    tree.write(release.with(plugins: plugins))

    assert_equal plugins, tree.read.plugins
  end

  def test_write_aborts_on_a_duplicated_line_and_writes_nothing
    rakefile = read("Rakefile").sub(%r{^  revision: 0,$}, "  revision: 0,\n  revision: 0,")
    File.write(path("Rakefile"), rakefile)
    before = snapshot

    assert_raises(SourceTree::Error) { tree.write(release_with_defaults) }

    assert_equal before, snapshot
  end

  # The last file edited is the one that fails, so this proves the earlier ones
  # were validated but not written.
  def test_write_aborts_on_a_drifted_deployment_and_writes_nothing
    File.write(path("deployment.yml"), "#{read("deployment.yml")}        image: other\n")
    before = snapshot

    assert_raises(SourceTree::Error) { tree.write(tree.read.with(revision: 4, traefik_version: "3.7.12")) }

    assert_equal before, snapshot
  end

  def test_write_aborts_on_a_missing_published_line
    File.write(path("README.md"), read("README.md").sub(%r{^Published as .*$}, ""))
    before = snapshot

    assert_raises(SourceTree::Error) { tree.write(tree.read.with(revision: 4)) }

    assert_equal before, snapshot
  end

  def test_read_rejects_a_plugin_block_whose_shape_drifted
    File.write(path("Rakefile"), read("Rakefile").sub(%(      name: "staticresponse",), %(      name:  "staticresponse",)))

    assert_raises(SourceTree::Error) { tree.read }
  end

  def test_read_rejects_a_plugin_written_on_one_line
    block = %r{^    Image::Plugin\.new\(\n      name: "staticresponse",\n.*?^    \),$}m
    one_line = %(    Image::Plugin.new(name: "staticresponse", repository: "jdel/staticresponse", ) +
               %(version: "v0.0.1", checksum: "#{NEW_CHECKSUM}"),)
    File.write(path("Rakefile"), read("Rakefile").sub(block, one_line))

    assert_raises(SourceTree::Error) { tree.read }
  end

  def test_write_rejects_a_plugin_the_tree_does_not_have
    release = tree.read
    unknown = Image::Plugin.new(name: "unknown", repository: "someone/unknown", version: "v1.0.0",
                                checksum: NEW_CHECKSUM)
    before = snapshot

    assert_raises(SourceTree::Error) { tree.write(release.with(plugins: [*release.plugins, unknown])) }

    assert_equal before, snapshot
  end

  private

  def tree
    SourceTree.new(@directory)
  end

  def release_with_defaults
    SourceTree::Release.new(traefik_version: "3.7.12", base_digest: IMAGE.base_digest, revision: 4,
                            plugins: IMAGE.plugins)
  end

  def path(name)
    File.join(@directory, name)
  end

  def read(name)
    File.read(path(name))
  end

  def snapshot
    FILES.to_h { |name| [name, File.binread(path(name))] }
  end
end
