# frozen_string_literal: true

require_relative "test_helper"

class ImageTest < Minitest::Test
  BASE_DIGEST = "sha256:#{"0" * 64}".freeze
  BUILDER_DIGEST = "sha256:#{"1" * 64}".freeze
  CHECKSUM = "sha256:#{"2" * 64}".freeze

  def test_version_is_traefik_version_and_revision
    assert_equal "3.7.15-scratch.0", image.version
  end

  def test_reference_is_repository_and_version
    assert_equal "jochen/traefik:3.7.15-scratch.0", image.reference
  end

  def test_release_reference_is_the_version_with_a_v_prefix
    assert_equal "v3.7.15-scratch.0", image.release_reference
  end

  def test_base_image_is_the_upstream_tag
    assert_equal "traefik:v3.7.15", image.base_image
  end

  def test_revision_is_part_of_the_version
    assert_equal "3.7.15-scratch.4", image(revision: 4).version
  end

  def test_build_arguments_name_every_dockerfile_argument
    names = image.build_arguments.map(&:name)

    assert_equal %w[TRAEFIK_VERSION BASE_DIGEST BUILDER_IMAGE BUILDER_DIGEST
                    REWRITEBODY_VERSION REWRITEBODY_CHECKSUM STATICRESPONSE_VERSION
                    STATICRESPONSE_CHECKSUM IMAGE_VERSION SOURCE_COMMIT], names
  end

  def test_build_arguments_carry_the_configured_values
    values = image.build_arguments.to_h { |argument| [argument.name, argument.value] }

    assert_equal "3.7.15", values["TRAEFIK_VERSION"]
    assert_equal BASE_DIGEST, values["BASE_DIGEST"]
    assert_equal "alpine:3.24.1", values["BUILDER_IMAGE"]
    assert_equal BUILDER_DIGEST, values["BUILDER_DIGEST"]
    assert_equal "v0.3.1", values["REWRITEBODY_VERSION"]
    assert_equal CHECKSUM, values["REWRITEBODY_CHECKSUM"]
    assert_equal "3.7.15-scratch.0", values["IMAGE_VERSION"]
  end

  def test_source_commit_comes_from_git
    commands = FakeCommands.new(captures: { %w[git rev-parse HEAD] => "abc123\n" })

    assert_equal "abc123", source_commit(image(commands: commands))
  end

  def test_source_commit_is_unknown_outside_a_checkout
    assert_equal "unknown", source_commit(image)
  end

  def test_labels_describe_version_and_base
    labels = image.labels.to_h { |label| [label.name, label.value] }

    assert_equal "3.7.15-scratch.0", labels["org.opencontainers.image.version"]
    assert_equal "docker.io/library/traefik:v3.7.15", labels["org.opencontainers.image.base.name"]
    assert_equal BASE_DIGEST, labels["org.opencontainers.image.base.digest"]
  end

  def test_plugin_module_path
    plugin = Image::Plugin.new(name: "rewritebody", repository: "traefik/plugin-rewritebody",
                               version: "v0.3.1", checksum: CHECKSUM)

    assert_equal "github.com/traefik/plugin-rewritebody", plugin.module_path
  end

  def test_plugin_archive_url
    plugin = Image::Plugin.new(name: "rewritebody", repository: "traefik/plugin-rewritebody",
                               version: "v0.3.1", checksum: CHECKSUM)

    assert_equal "https://github.com/traefik/plugin-rewritebody/archive/refs/tags/v0.3.1.tar.gz",
                 plugin.archive_url
  end

  def test_plugin_argument_prefix
    plugin = Image::Plugin.new(name: "static-response", repository: "a/b", version: "v1.0.0", checksum: CHECKSUM)

    assert_equal "STATIC_RESPONSE", plugin.argument_prefix
  end

  def test_plugin_lookup_by_name
    assert_equal "jdel/staticresponse", image.plugin("staticresponse").repository
  end

  def test_unknown_plugin_raises
    assert_raises(Image::Error) { image.plugin("nonexistent") }
  end

  def test_malformed_checksum_is_rejected
    assert_raises(ArgumentError) do
      Image::Plugin.new(name: "x", repository: "a/b", version: "v1.0.0", checksum: "sha256:abc")
    end
  end

  def test_checksum_without_algorithm_is_rejected
    assert_raises(ArgumentError) do
      Image::Plugin.new(name: "x", repository: "a/b", version: "v1.0.0", checksum: "2" * 64)
    end
  end

  def test_malformed_base_digest_is_rejected
    assert_raises(ArgumentError) { image(base_digest: "sha256:abc") }
  end

  def test_malformed_builder_digest_is_rejected
    assert_raises(ArgumentError) { image(builder_digest: "latest") }
  end

  def test_negative_revision_is_rejected
    assert_raises(ArgumentError) { image(revision: -1) }
  end

  def test_no_plugins_is_rejected
    assert_raises(ArgumentError) { image(plugins: []) }
  end

  def test_no_platforms_is_rejected
    assert_raises(ArgumentError) { image(platforms: []) }
  end

  def test_with_platforms_narrows_the_image
    narrowed = image.with_platforms([amd64])

    assert_equal [amd64], narrowed.platforms
  end

  def test_with_platforms_rejects_an_unconfigured_platform
    assert_raises(Image::Error) { image.with_platforms([Image::Platform.parse("linux/riscv64")]) }
  end

  def test_platform_parse_requires_os_and_architecture
    assert_raises(ArgumentError) { Image::Platform.parse("linux") }
  end

  def test_build_loads_every_platform_with_the_pinned_arguments
    commands = FakeCommands.new(
      captures: { ["docker", "info", "--format", "{{json .DriverStatus}}"] => "io.containerd.snapshotter" }
    )
    image(commands: commands).build

    arguments = commands.executed.fetch(0)

    assert_equal %w[docker buildx build --platform linux/amd64,linux/arm64], arguments.first(5)
    assert_includes arguments, "TRAEFIK_VERSION=3.7.15"
    assert_includes arguments, "jochen/traefik:3.7.15-scratch.0"
    assert_includes arguments, "--load"
  end

  def test_build_refuses_two_platforms_without_the_containerd_store
    commands = FakeCommands.new

    assert_raises(Image::Error) { image(commands: commands).build }
    assert_empty commands.executed
  end

  def test_composition_root_image_is_valid
    assert_equal "jochen/traefik", IMAGE.repository
    assert_equal %w[rewritebody staticresponse], IMAGE.plugins.map(&:name)
  end

  # A plain `docker build .` uses the Dockerfile's defaults, so they must say
  # what IMAGE says. SOURCE_COMMIT is the one argument without a literal value:
  # it names the commit, which no committed file can know.
  def test_dockerfile_defaults_match_the_image_literal
    dockerfile = File.read(File.expand_path("../Dockerfile", __dir__))
    defaults = dockerfile.scan(%r{^ARG ([A-Z_]+)=(.*)$}).to_h.except("SOURCE_COMMIT")
    pinned = Image.new(repository: IMAGE.repository, traefik_version: IMAGE.traefik_version,
                       base_digest: IMAGE.base_digest, builder_image: IMAGE.builder_image,
                       builder_digest: IMAGE.builder_digest, revision: IMAGE.revision,
                       platforms: IMAGE.platforms, plugins: IMAGE.plugins, commands: FakeCommands.new)
    expected = pinned.build_arguments.to_h { |argument| [argument.name, argument.value] }.except("SOURCE_COMMIT")

    assert_equal expected, defaults
  end

  private

  def amd64
    Image::Platform.parse("linux/amd64")
  end

  def source_commit(subject)
    subject.build_arguments.find { |argument| argument.name == "SOURCE_COMMIT" }.value
  end

  def image(**overrides)
    Image.new(
      repository: "jochen/traefik",
      traefik_version: "3.7.15",
      base_digest: BASE_DIGEST,
      builder_image: "alpine:3.24.1",
      builder_digest: BUILDER_DIGEST,
      revision: 0,
      platforms: [amd64, Image::Platform.parse("linux/arm64")],
      plugins: [
        Image::Plugin.new(name: "rewritebody", repository: "traefik/plugin-rewritebody",
                          version: "v0.3.1", checksum: CHECKSUM),
        Image::Plugin.new(name: "staticresponse", repository: "jdel/staticresponse",
                          version: "v0.0.1", checksum: CHECKSUM),
      ],
      commands: FakeCommands.new,
      **overrides
    )
  end
end
