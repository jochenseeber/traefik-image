# frozen_string_literal: true

require_relative "test_helper"
require "rubygems/package"
require "stringio"

class CheckTest < Minitest::Test
  REFERENCE = "jochen/traefik:3.7.15-scratch.0"
  PROBE_IMAGE = "alpine:3.24.1@sha256:#{"1" * 64}".freeze

  def test_command_check_returns_the_matching_line_with_whitespace_collapsed
    run = ["docker", "run", "--rm", "--platform", "linux/amd64", REFERENCE, "version"]
    commands = FakeCommands.new(captures: { run => "Version:      3.7.15\nCodename:     langres\n" })

    assert_equal "Version: 3.7.15", version_check.run(reference: REFERENCE, platform: amd64, commands: commands)
  end

  def test_command_check_without_the_expected_text_raises_naming_the_description
    commands = FakeCommands.new { "Version:      3.7.150\n" }

    error = assert_raises(Image::Error) { version_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_match %r{\Aversion reports 3\.7\.15: expected "Version: 3\.7\.15\\n"}, error.message
  end

  def test_command_check_that_cannot_run_raises
    error = assert_raises(Image::Error) do
      version_check.run(reference: REFERENCE, platform: amd64, commands: FakeCommands.new)
    end
    assert_match %r{\Aversion reports 3\.7\.15: `version` failed}, error.message
  end

  def test_config_check_returns_the_value_for_the_platform
    inspect = ["docker", "image", "inspect", "--platform", "linux/amd64", "--format", "{{.Config.User}}", REFERENCE]
    commands = FakeCommands.new(captures: { inspect => "1001:1001\n" })

    assert_equal "1001:1001", user_check.run(reference: REFERENCE, platform: amd64, commands: commands)
  end

  def test_config_check_falls_back_to_inspection_without_platform
    inspect = ["docker", "image", "inspect", "--format", "{{.Config.User}}", REFERENCE]
    commands = FakeCommands.new(captures: { inspect => "1001:1001\n" })

    assert_equal "1001:1001", user_check.run(reference: REFERENCE, platform: amd64, commands: commands)
  end

  def test_config_check_with_a_different_value_raises
    commands = FakeCommands.new { "0\n" }

    error = assert_raises(Image::Error) { user_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_equal "runs as 1001:1001: expected \"1001:1001\", got \"0\"", error.message
  end

  def test_config_check_that_cannot_inspect_raises
    error = assert_raises(Image::Error) do
      user_check.run(reference: REFERENCE, platform: amd64, commands: FakeCommands.new)
    end
    assert_match %r{\Aruns as 1001:1001: cannot inspect}, error.message
  end

  def test_filesystem_check_passes_without_setuid_files
    commands = exported(file("traefik", 0o755), file("etc/ssl/certs/ca-certificates.crt", 0o644))

    assert_equal "none (2 entries)", setuid_check.run(reference: REFERENCE, platform: amd64, commands: commands)
  end

  def test_filesystem_check_fails_on_a_setuid_file_and_removes_the_container
    commands = exported(file("traefik", 0o755), file("usr/bin/su", 0o4755))

    error = assert_raises(Image::Error) { setuid_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_equal "no setuid or setgid files: usr/bin/su (4755)", error.message
    assert_includes commands.captured, %w[docker rm --force exported]
  end

  def test_filesystem_check_fails_on_a_setgid_file
    commands = exported(file("usr/bin/wall", 0o2755))

    error = assert_raises(Image::Error) { setuid_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_equal "no setuid or setgid files: usr/bin/wall (2755)", error.message
  end

  def test_filesystem_check_names_a_missing_file
    present = %w[traefik etc/ssl/certs/ca-certificates.crt usr/share/zoneinfo/UTC
                 plugins-local/src/github.com/traefik/plugin-rewritebody/.traefik.yml]
    commands = exported(*present.map { |name| file(name, 0o755) })

    error = assert_raises(Image::Error) { files_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_equal "expected files present: missing plugins-local/src/github.com/jdel/staticresponse/.traefik.yml",
                 error.message
  end

  def test_filesystem_check_that_cannot_create_a_container_raises
    error = assert_raises(Image::Error) do
      setuid_check.run(reference: REFERENCE, platform: amd64, commands: FakeCommands.new)
    end
    assert_match %r{cannot create a linux/amd64 container}, error.message
  end

  def test_service_check_reports_every_probe
    commands = service_commands

    evidence = service_check.run(reference: REFERENCE, platform: amd64, commands: commands)

    assert_equal ":9000/ping OK, :80/static served by staticresponse, :80/rewritten rewritten body", evidence
  end

  def test_service_check_runs_the_container_like_the_deployment
    commands = service_commands
    service_check.run(reference: REFERENCE, platform: amd64, commands: commands)

    arguments = commands.captured.find { |command| command.include?("--detach") }

    %w[--read-only --platform=linux/amd64 --tmpfs=/tmp --cap-drop=ALL --cap-add=NET_BIND_SERVICE
       --sysctl=net.ipv4.ip_unprivileged_port_start=1024].each do |pair|
      option, value = pair.split("=", 2)
      assert_option arguments, option, value
    end
    assert_includes arguments, "--experimental.localPlugins.rewriteBody.moduleName=github.com/traefik/plugin-rewritebody"
    assert_includes arguments, "--experimental.localPlugins.staticResponse.moduleName=github.com/jdel/staticresponse"
    assert_includes arguments, "--providers.file.filename=/verify/dynamic.yml"
    assert_option arguments, "--volume", "#{File.expand_path("../verify", __dir__)}:/verify:ro"
  end

  def test_service_check_removes_the_container_it_started
    commands = service_commands
    service_check.run(reference: REFERENCE, platform: amd64, commands: commands)

    assert_equal [container_name(commands)], removed(commands)
  end

  def test_service_check_that_never_sees_ping_raises_after_its_timeout_and_removes_the_container
    commands = service_commands(bodies: {})
    check = Image::ServiceCheck.new(description: "serves", arguments: [], probes: [ping_probe],
                                    probe_image: PROBE_IMAGE, mount: "verify", forbidden_log: "disabled",
                                    timeout: 0.2, interval: 0.05)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Image::Error) { check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_match %r{\Aserves: no "OK" from :9000/ping within 0\.2 s}, error.message
    assert_operator elapsed, :>=, 0.2
    assert_operator ping_attempts(commands), :>, 1
    assert_equal [container_name(commands)], removed(commands)
  end

  def test_service_check_stops_waiting_when_the_container_exits
    commands = service_commands(bodies: {}, running: "false\n", log: "bind: permission denied\n")

    error = assert_raises(Image::Error) { service_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_match %r{container exited.*bind: permission denied}m, error.message
    assert_equal 1, ping_attempts(commands)
    assert_equal [container_name(commands)], removed(commands)
  end

  def test_service_check_with_a_wrong_body_raises_after_its_timeout
    commands = service_commands(bodies: bodies.merge(":80/rewritten" => "original body"))
    check = Image::ServiceCheck.new(description: "serves", arguments: [], probes: [ping_probe, rewritten_probe],
                                    probe_image: PROBE_IMAGE, mount: "verify", forbidden_log: "disabled",
                                    timeout: 0.2, interval: 0.05)

    error = assert_raises(Image::Error) { check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_match %r{no "rewritten body" from :80/rewritten within 0\.2 s, last answer "original body"}, error.message
    assert_equal [container_name(commands)], removed(commands)
  end

  def test_service_check_retries_every_probe_not_only_ping
    answers = [nil, "served by staticresponse"]
    commands = service_commands(bodies: bodies.merge(":80/static" => ->(_) { answers.shift }))

    evidence = service_check.run(reference: REFERENCE, platform: amd64, commands: commands)

    assert_includes evidence, ":80/static served by staticresponse"
    assert_equal 2, probe_attempts(commands, "http://127.0.0.1:80/static")
  end

  def test_service_check_bounds_each_request
    commands = service_commands
    service_check.run(reference: REFERENCE, platform: amd64, commands: commands)

    wget = commands.captured.find { |command| command.include?("wget") }
    assert_option wget, "-T", "5"
  end

  def test_service_check_that_cannot_start_raises_and_still_removes
    commands = FakeCommands.new

    error = assert_raises(Image::Error) { service_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_match %r{cannot start}, error.message
    assert_equal 1, removed(commands).size
  end

  def test_service_check_fails_when_plugins_are_disabled
    commands = service_commands(log: "ERR Plugins are disabled because an error has occurred.\n")

    error = assert_raises(Image::Error) { service_check.run(reference: REFERENCE, platform: amd64, commands: commands) }
    assert_match %r{log contains "Plugins are disabled"}, error.message
  end

  def test_verify_requires_a_built_image
    image = IMAGE.with_platforms([amd64])
    commands = FakeCommands.new
    subject = Image.new(repository: image.repository, traefik_version: image.traefik_version,
                        base_digest: image.base_digest, builder_image: image.builder_image,
                        builder_digest: image.builder_digest, revision: image.revision,
                        platforms: image.platforms, plugins: image.plugins, commands: commands)

    error = assert_raises(Image::Error) { capture_io { subject.verify } }
    assert_equal "#{REFERENCE} has no linux/amd64 image; run `rake image:build` first", error.message
  end

  def test_checks_cover_labels
    descriptions = IMAGE.checks.map(&:description)

    IMAGE.labels.each { |label| assert_includes descriptions, "label #{label.name}" }
  end

  private

  def amd64
    Image::Platform.parse("linux/amd64")
  end

  def check(description)
    IMAGE.checks.find { |candidate| candidate.description == description } ||
      flunk("no check #{description.inspect}")
  end

  def version_check = check("version reports 3.7.15")
  def user_check = check("runs as 1001:1001")
  def setuid_check = check("no setuid or setgid files")
  def files_check = check("expected files present")
  def service_check = check("serves through both plugins")

  def ping_probe
    Image::ServiceCheck::Probe.new(port: 9000, path: "/ping", expected: "OK")
  end

  def rewritten_probe
    Image::ServiceCheck::Probe.new(port: 80, path: "/rewritten", expected: "rewritten body")
  end

  def bodies
    { ":9000/ping" => "OK", ":80/static" => "served by staticresponse", ":80/rewritten" => "rewritten body" }
  end

  # Answers like a running Traefik behind the probe container: the URL decides
  # the body, and `nil` is what a failed wget looks like to the runner.
  def service_commands(bodies: self.bodies, running: "true\n", log: "")
    FakeCommands.new do |arguments|
      case arguments
      in ["docker", "run", "--detach", *] then "0123abcd\n"
      in ["docker", "run", "--rm", "--network", _, _, "wget", *, url]
        body = bodies[url.delete_prefix("http://127.0.0.1")]
        body.respond_to?(:call) ? body.call(url) : body
      in ["docker", "container", "inspect", *] then running
      in ["docker", "logs", _] then log
      else nil
      end
    end
  end

  def container_name(commands)
    arguments = commands.captured.find { |command| command.include?("--detach") }
    arguments[arguments.index("--name") + 1]
  end

  def removed(commands)
    commands.captured.select { |command| command.first(3) == %w[docker rm --force] }.map(&:last)
  end

  def ping_attempts(commands)
    commands.captured.count { |command| command.last == "http://127.0.0.1:9000/ping" }
  end

  def probe_attempts(commands, url)
    commands.captured.count { |command| command.last == url }
  end

  def assert_option(arguments, option, value)
    index = arguments.index(option)
    refute_nil index, "#{option} missing from #{arguments.inspect}"
    assert_equal value, arguments[index + 1] unless value.nil?
  end

  Entry = Data.define(:name, :mode)

  def file(name, mode)
    Entry.new(name: name, mode: mode)
  end

  # A `docker create` + `docker export` of a container holding these files
  def exported(*entries)
    archive = StringIO.new(+"", "wb")
    Gem::Package::TarWriter.new(archive) do |tar|
      entries.each { |entry| tar.add_file_simple(entry.name, entry.mode, 0) { nil } }
    end
    create = ["docker", "create", "--platform", "linux/amd64", REFERENCE]
    FakeCommands.new(captures: { create => "exported\n", %w[docker export exported] => archive.string })
  end
end
