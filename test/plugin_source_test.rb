# frozen_string_literal: true

require "digest"
require_relative "test_helper"

class PluginSourceTest < Minitest::Test
  PINNED_CHECKSUM = "sha256:#{"0" * 64}".freeze
  ARCHIVE = "fake archive bytes"
  TAGS_COMMAND = ["gh", "api", "--paginate", "repos/traefik/plugin-rewritebody/tags", "--jq", ".[].name"].freeze

  def test_newest_picks_the_highest_release_tag
    assert_equal "v0.10.0", source.newest(plugin).version
  end

  def test_newest_checksums_the_archive_of_that_tag
    downloaded = []
    newest = source(downloader: lambda { |url|
      downloaded << url
      ARCHIVE
    }).newest(plugin)

    assert_equal "sha256:#{Digest::SHA256.hexdigest(ARCHIVE)}", newest.checksum
    assert_equal ["https://github.com/traefik/plugin-rewritebody/archive/refs/tags/v0.10.0.tar.gz"], downloaded
  end

  def test_newest_keeps_name_and_repository
    newest = source.newest(plugin)

    assert_equal "rewritebody", newest.name
    assert_equal "traefik/plugin-rewritebody", newest.repository
  end

  def test_newest_asks_github_once_per_plugin
    commands = fake_commands
    downloads = 0
    plugin_source = source(commands: commands, downloader: lambda { |_url|
      downloads += 1
      ARCHIVE
    })

    2.times { plugin_source.newest(plugin) }

    assert_equal 1, commands.captured.size
    assert_equal 1, downloads
  end

  def test_newest_fails_when_the_tags_cannot_be_listed
    assert_raises(PluginSource::Error) { source(commands: FakeCommands.new).newest(plugin) }
  end

  def test_newest_fails_without_a_release_tag
    commands = FakeCommands.new(captures: { TAGS_COMMAND => "latest\nv1.0.0-rc1\n" })

    assert_raises(PluginSource::Error) { source(commands: commands).newest(plugin) }
  end

  private

  def fake_commands
    FakeCommands.new(captures: { TAGS_COMMAND => "v0.3.1\nv0.10.0\nv0.9.0\nv1.0.0-rc1\nlatest\n" })
  end

  def source(commands: fake_commands, downloader: ->(_url) { ARCHIVE })
    PluginSource.new(commands: commands, downloader: downloader)
  end

  def plugin
    Image::Plugin.new(name: "rewritebody", repository: "traefik/plugin-rewritebody", version: "v0.3.1",
                      checksum: PINNED_CHECKSUM)
  end
end
