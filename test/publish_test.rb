# frozen_string_literal: true

require_relative "test_helper"

class PublishTest < Minitest::Test
  BASE_DIGEST = "sha256:#{"0" * 64}".freeze
  BUILDER_DIGEST = "sha256:#{"1" * 64}".freeze
  CHECKSUM = "sha256:#{"2" * 64}".freeze
  CURRENT_DIGEST = "sha256:#{"3" * 64}".freeze

  # Answers digest lookups from a table; anything else is a test mistake
  class FakeRegistry
    def initialize(digests = {})
      @digests = digests
    end

    def digest(repository, tag)
      @digests[[repository, tag]]
    end
  end

  # Answers each plugin with a newer tag, as if it had moved
  class FakePluginSource
    def newest(plugin)
      plugin.with(version: "v9.9.9", checksum: CURRENT_DIGEST)
    end
  end

  def test_publish_pushes_the_version_tag_and_nothing_else
    commands = FakeCommands.new { |_arguments| "ok" }

    image(commands: commands).publish

    assert_equal [%w[docker push jochen/traefik:3.7.15-scratch.0]], commands.executed
  end

  def test_publish_refuses_a_version_that_is_already_published
    commands = FakeCommands.new { |_arguments| "ok" }
    registry = FakeRegistry.new({ ["jochen/traefik", "3.7.15-scratch.0"] => CURRENT_DIGEST })

    error = assert_raises(Image::Error) { image(commands: commands, registry: registry).publish }

    assert_includes error.message, "already published"
    assert_empty commands.executed
  end

  def test_publish_names_the_platform_the_local_image_lacks
    commands = FakeCommands.new do |arguments|
      "ok" unless arguments.include?("linux/arm64")
    end

    error = assert_raises(Image::Error) { image(commands: commands).publish }

    assert_includes error.message, "linux/arm64"
    assert_empty commands.executed
  end

  def test_report_prints_current_and_pinned_digest_of_base_and_builder
    commands = FakeCommands.new do |arguments|
      arguments.include?("traefik:v3.7.15") ? "#{CURRENT_DIGEST}\n" : "#{BUILDER_DIGEST}\n"
    end

    output, = capture_io { image(commands: commands).report_available_versions(plugin_source: FakePluginSource.new) }

    assert_includes output, "=== traefik:v3.7.15 ==="
    assert_includes output, "current digest: #{CURRENT_DIGEST}"
    assert_includes output, "pinned digest:  #{BASE_DIGEST}"
    assert_includes output, "=== alpine:3.24.1 ==="
    assert_includes output, "current digest: #{BUILDER_DIGEST}"
    assert_includes output, "pinned digest:  #{BUILDER_DIGEST}"
  end

  def test_report_prints_newest_and_pinned_tag_of_each_plugin
    commands = FakeCommands.new { |_arguments| "#{CURRENT_DIGEST}\n" }

    output, = capture_io { image(commands: commands).report_available_versions(plugin_source: FakePluginSource.new) }

    assert_includes output, "=== rewritebody (traefik/plugin-rewritebody) ===\n" \
                            "newest tag: v9.9.9 #{CURRENT_DIGEST}\n" \
                            "pinned tag: v0.3.1 #{CHECKSUM}\n"
  end

  def test_report_fails_when_a_digest_cannot_be_read
    assert_raises(Image::Error) { capture_io { image.report_available_versions(plugin_source: FakePluginSource.new) } }
  end

  def test_with_platforms_keeps_the_registry
    registry = FakeRegistry.new({ ["jochen/traefik", "3.7.15-scratch.0"] => CURRENT_DIGEST })
    narrowed = image(registry: registry).with_platforms([Image::Platform.parse("linux/amd64")])

    assert_raises(Image::Error) { narrowed.publish }
  end

  private

  def image(**overrides)
    Image.new(
      repository: "jochen/traefik",
      traefik_version: "3.7.15",
      base_digest: BASE_DIGEST,
      builder_image: "alpine:3.24.1",
      builder_digest: BUILDER_DIGEST,
      revision: 0,
      platforms: [Image::Platform.parse("linux/amd64"), Image::Platform.parse("linux/arm64")],
      plugins: [
        Image::Plugin.new(name: "rewritebody", repository: "traefik/plugin-rewritebody",
                          version: "v0.3.1", checksum: CHECKSUM),
      ],
      commands: FakeCommands.new,
      registry: FakeRegistry.new,
      **overrides
    )
  end
end
