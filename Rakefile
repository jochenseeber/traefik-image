# frozen_string_literal: true

require "English"
require "digest"
require "json"
require "net/http"
require "rake/testtask"
require "rubygems/package"
require "securerandom"
require "stringio"
require "time"
require "tmpdir"

# Run external commands
class CommandRunner
  include Rake::DSL

  # Print command to console and run; options such as `chdir:` go to spawn
  def execute(*, **)
    sh(*, **)
  end

  # Run command, capture stdout and return `nil` on failure
  def capture(*arguments, **)
    output = IO.popen(arguments, err: File::NULL, **, &:read)
    $CHILD_STATUS.success? ? output : nil
  end

  # Run command, capture stdout and stderr, and return `nil` on failure
  def capture_merged(*arguments)
    output = IO.popen(arguments, err: %i[child out], &:read)
    $CHILD_STATUS.success? ? output : nil
  end
end

# Docker image handling
class Image
  DIGEST_PATTERN = %r{\Asha256:\h{64}\z}

  # Platform information
  Platform = Data.define(:operating_system, :architecture) do
    def self.parse(text)
      operating_system, architecture = text.to_s.split("/", 2)
      if operating_system.to_s.empty? || architecture.to_s.empty?
        raise ArgumentError, "expected an os/arch platform, got #{text.inspect}"
      end

      new(operating_system: operating_system, architecture: architecture)
    end

    def to_s
      "#{operating_system}/#{architecture}"
    end
  end

  # A Traefik plugin, installed from a GitHub tag archive
  #
  # The tag is not trusted on its own: a tag can be moved, so the archive is also
  # pinned by the SHA-256 of its bytes, which the Dockerfile checks on download.
  Plugin = Data.define(:name, :repository, :version, :checksum) do
    def initialize(name:, repository:, version:, checksum:)
      unless checksum.match?(%r{\Asha256:\h{64}\z})
        raise ArgumentError, "#{name} checksum must be sha256:<64 hex>, got #{checksum.inspect}"
      end

      super
    end

    # Where Traefik looks the plugin up under `/plugins-local/src`
    def module_path
      "github.com/#{repository}"
    end

    def archive_url
      "https://github.com/#{repository}/archive/refs/tags/#{version}.tar.gz"
    end

    # The Dockerfile `ARG` names are derived from this, so adding a plugin needs
    # no second list of names
    def argument_prefix
      name.upcase.tr("-", "_")
    end
  end

  # Label for Docker builds
  Label = Data.define(:name, :value)

  # Argument for Docker builds
  BuildArgument = Data.define(:name, :value) do
    def to_argument
      "#{name}=#{value}"
    end
  end

  class Error < StandardError; end

  # Assertion about the built image, run once per platform
  #
  # The image has no shell, so nothing can run inside it but Traefik itself.
  # Each kind of check is a different way around that: running the entrypoint,
  # serving traffic to a second container, reading the exported filesystem, or
  # reading the image configuration.
  class Check
    attr_reader :description

    def initialize(description:)
      @description = description
      freeze
    end

    # The evidence line for the report; raises Image::Error on failure
    def run(reference:, platform:, commands:)
      raise NotImplementedError, "#{self.class} does not implement #run"
    end

    private

    def failure(message)
      Error.new("#{@description}: #{message}")
    end
  end

  # Runs the entrypoint with arguments and expects a substring of its output
  #
  # A substring rather than a regexp because these assert versions, and a
  # failing literal prints a diff worth reading. Runs of spaces and tabs are
  # collapsed first: Traefik aligns its `version` output in columns, and the
  # width of those columns is not what is being asserted. A trailing newline in
  # `expected` anchors it to the end of a line, so 3.7.15 does not match 3.7.150.
  class CommandCheck < Check
    def initialize(description:, arguments:, expected:)
      @arguments = arguments.freeze
      @expected = expected
      super(description: description)
    end

    def run(reference:, platform:, commands:)
      output = commands.capture_merged("docker", "run", "--rm", "--platform", platform.to_s, reference, *@arguments)
      raise failure("`#{@arguments.join(" ")}` failed") if output.nil?

      normalized = output.gsub(%r{[ \t]+}, " ")
      raise failure("expected #{@expected.inspect} in output, got:\n#{output}") unless normalized.include?(@expected)

      normalized.lines.find { |line| line.include?(@expected.strip) }.to_s.strip
    end
  end

  # A field of the image configuration equals a value
  class ConfigCheck < Check
    def initialize(description:, format:, expected:)
      @format = format
      @expected = expected
      super(description: description)
    end

    def run(reference:, platform:, commands:)
      output = inspect_image(reference: reference, platform: platform, commands: commands)
      raise failure("cannot inspect #{platform} of #{reference}") if output.nil?

      actual = output.strip
      raise failure("expected #{@expected.inspect}, got #{actual.inspect}") unless actual == @expected

      actual
    end

    private

    # Per platform where the daemon can do it. Docker 28 cannot: `docker image
    # inspect --platform` exists only from Docker 29, and without it the daemon
    # reports the host platform's config even for a manifest list. Both
    # platforms are built from the same arguments and are expected to agree, so
    # there the check degrades from "each platform's config" to "the config" —
    # weaker, never wrong.
    def inspect_image(reference:, platform:, commands:)
      commands.capture("docker", "image", "inspect", "--platform", platform.to_s, "--format", @format, reference) ||
        commands.capture("docker", "image", "inspect", "--format", @format, reference)
    end
  end

  # A predicate over every entry of the platform's exported filesystem
  #
  # `violations` maps the entries to a list of complaints; the check passes when
  # that list is empty. Reading the export rather than running `find` in the
  # image is what a shell-less image leaves.
  class FilesystemCheck < Check
    # One tar entry; `file` is whether it is a regular file
    Entry = Data.define(:name, :mode, :file)

    def initialize(description:, evidence:, violations:)
      @evidence = evidence
      @violations = violations
      super(description: description)
    end

    def run(reference:, platform:, commands:)
      container = commands.capture("docker", "create", "--platform", platform.to_s, reference)&.strip
      raise failure("cannot create a #{platform} container from #{reference}") if container.nil?

      entries = exported_entries(container, commands: commands)
      found = @violations.call(entries)
      raise failure(found.join(", ")) unless found.empty?

      "#{@evidence} (#{entries.size} entries)"
    ensure
      commands.capture("docker", "rm", "--force", container) unless container.nil?
    end

    private

    def exported_entries(container, commands:)
      archive = commands.capture("docker", "export", container, binmode: true)
      raise failure("cannot export container #{container}") if archive.nil?

      Gem::Package::TarReader.new(StringIO.new(archive)).map do |entry|
        Entry.new(name: entry.full_name.delete_suffix("/"), mode: entry.header.mode, file: entry.file?)
      end
    end
  end

  # Starts the image as a service and requests URLs from it
  #
  # The image has no wget, so the requests come from a probe container sharing
  # the service container's network namespace. The first probe is the readiness
  # probe: it is retried until it answers or `timeout` seconds pass, then every
  # probe runs once. The container is always removed, whatever happens.
  class ServiceCheck < Check
    # One request: a port and path on the service container
    Probe = Data.define(:port, :path, :expected) do
      def url
        "http://127.0.0.1:#{port}#{path}"
      end

      def to_s
        ":#{port}#{path}"
      end
    end

    def initialize(description:, arguments:, probes:, probe_image:, mount:, forbidden_log:, timeout: 120, interval: 1)
      raise ArgumentError, "a service check needs at least one probe" if probes.empty?

      @arguments = arguments.freeze
      @probes = probes.freeze
      @probe_image = probe_image
      @mount = mount
      @forbidden_log = forbidden_log
      @timeout = timeout
      @interval = interval
      super(description: description)
    end

    def run(reference:, platform:, commands:)
      name = "traefik-verify-#{SecureRandom.hex(6)}"
      start(name, reference: reference, platform: platform, commands: commands)
      deadline = now + @timeout
      evidence = @probes.map { |probe| await(name, probe, deadline: deadline, commands: commands) }
      ensure_clean_log(name, commands: commands)
      evidence.join(", ")
    ensure
      commands.capture("docker", "rm", "--force", name)
    end

    private

    # Configured like deployment.yml. Docker sets
    # net.ipv4.ip_unprivileged_port_start=0 in every container, which lets any
    # user bind port 80; setting it back to the kernel default is what makes
    # the :80 probes depend on the file capability on /traefik, and dropping
    # every capability but NET_BIND_SERVICE is what the deployment grants.
    def start(name, reference:, platform:, commands:)
      started = commands.capture_merged("docker", "run", "--detach", "--name", name, "--platform", platform.to_s,
                                        "--read-only", "--tmpfs", "/tmp",
                                        "--cap-drop", "ALL", "--cap-add", "NET_BIND_SERVICE",
                                        "--sysctl", "net.ipv4.ip_unprivileged_port_start=1024",
                                        "--volume", "#{File.expand_path(@mount)}:/#{File.basename(@mount)}:ro",
                                        reference, *@arguments)
      raise failure("cannot start #{reference} on #{platform}") if started.nil?
    end

    # Every probe is retried against the one deadline, not just the first:
    # under QEMU a route can answer well after /ping does. A container that has
    # exited is reported at once instead of after the deadline.
    def await(name, probe, deadline:, commands:)
      body = fetch(name, probe, commands: commands)
      until body.to_s.include?(probe.expected)
        raise failure("container exited before #{probe} answered; log:\n#{log(name, commands: commands)}") \
          unless running?(name, commands: commands)
        if now >= deadline
          raise failure("no #{probe.expected.inspect} from #{probe} within #{@timeout} s, last answer " \
                        "#{body.inspect}; log:\n#{log(name, commands: commands)}")
        end

        sleep(@interval)
        body = fetch(name, probe, commands: commands)
      end
      "#{probe} #{body.strip}"
    end

    # Traefik keeps serving /ping when a plugin fails to load, so a healthy
    # ping proves nothing about the plugins; the log says so explicitly.
    def ensure_clean_log(name, commands:)
      output = log(name, commands: commands)
      raise failure("log contains #{@forbidden_log.inspect}:\n#{output}") if output.include?(@forbidden_log)
    end

    # busybox wget waits 900 s by default, which would outlast the deadline
    # while one request hangs; -T bounds each request instead.
    def fetch(name, probe, commands:)
      commands.capture_merged("docker", "run", "--rm", "--network", "container:#{name}", @probe_image,
                              "wget", "-qO-", "-T", "5", probe.url)
    end

    def running?(name, commands:)
      commands.capture("docker", "container", "inspect", "--format", "{{.State.Running}}", name)&.strip == "true"
    end

    def log(name, commands:)
      commands.capture_merged("docker", "logs", name).to_s
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  DOCKERFILE = "Dockerfile"

  # Mounted into the service check; holds the routes that exercise the plugins
  VERIFY_DIRECTORY = File.expand_path("verify", __dir__)

  attr_reader :repository, :traefik_version, :base_digest, :builder_image, :builder_digest,
              :revision, :platforms, :plugins

  def initialize(repository:, traefik_version:, base_digest:, builder_image:, builder_digest:,
                 revision:, platforms:, plugins:, commands: CommandRunner.new, registry: Registry.new)
    raise ArgumentError, "an image needs at least one platform" if platforms.empty?
    raise ArgumentError, "an image needs at least one plugin" if plugins.empty?
    raise ArgumentError, "revision must not be negative, got #{revision}" if revision.negative?

    { "base_digest" => base_digest, "builder_digest" => builder_digest }.each do |name, digest|
      raise ArgumentError, "#{name} must be sha256:<64 hex>, got #{digest.inspect}" unless digest.match?(DIGEST_PATTERN)
    end

    @repository = repository
    @traefik_version = traefik_version
    @base_digest = base_digest
    @builder_image = builder_image
    @builder_digest = builder_digest
    @revision = revision
    @platforms = platforms.freeze
    @plugins = plugins.freeze
    @commands = commands
    @registry = registry
    freeze
  end

  def with_platforms(platforms)
    unknown = platforms - @platforms
    raise Error, "#{unknown.join(", ")} is not a platform this image is configured for" unless unknown.empty?

    self.class.new(repository: @repository, traefik_version: @traefik_version,
                   base_digest: @base_digest, builder_image: @builder_image,
                   builder_digest: @builder_digest, revision: @revision, platforms: platforms,
                   plugins: @plugins, commands: @commands, registry: @registry)
  end

  # The semantic version, and the canonical form of everything below. The
  # variant and the revision together are the prerelease, so rebuilds of one
  # Traefik release order correctly (scratch.0 < scratch.1 < scratch.2).
  #
  # It uses only characters Docker accepts in a tag, which is why the image tag,
  # the git tag and the version label are all this one string rather than
  # transliterations of it.
  def version
    "#{@traefik_version}-scratch.#{@revision}"
  end

  def reference
    "#{@repository}:#{version}"
  end

  # Upstream tags its releases `v<version>`; the bare `<version>` tag is a
  # different thing
  def base_image
    "traefik:v#{@traefik_version}"
  end

  def release_reference
    "v#{version}"
  end

  def plugin(name)
    found = @plugins.find { |plugin| plugin.name == name }
    raise Error, "this image has no #{name} plugin" if found.nil?

    found
  end

  def build
    ensure_multi_platform_loadable
    @commands.execute("docker", "buildx", "build",
                      "--platform", @platforms.join(","),
                      "--file", DOCKERFILE,
                      *build_arguments.flat_map { |argument| ["--build-arg", argument.to_argument] },
                      "--tag", reference,
                      "--load", ".")
  end

  def verify
    image_checks = checks
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` first")
      puts "#{platform} (#{reference})"
      image_checks.each do |check|
        puts "  #{check.description}: #{check.run(reference: reference, platform: platform, commands: @commands)}"
      end
    end
    puts "#{image_checks.size} checks passed on #{@platforms.size} platform(s)"
  end

  def checks
    [
      CommandCheck.new(description: "version reports #{@traefik_version}",
                       arguments: ["version"], expected: "Version: #{@traefik_version}\n"),
      ConfigCheck.new(description: "runs as 1001:1001", format: "{{.Config.User}}", expected: "1001:1001"),
      ConfigCheck.new(description: "entrypoint is /traefik", format: "{{json .Config.Entrypoint}}",
                      expected: '["/traefik"]'),
      setuid_check,
      files_check,
      service_check,
      *labels.map do |label|
        ConfigCheck.new(description: "label #{label.name}",
                        format: "{{index .Config.Labels #{label.name.inspect}}}", expected: label.value)
      end,
    ]
  end

  # Never over an existing tag: `docker push` would replace it silently, and
  # whoever runs that tag would get different bytes on their next pull. A new
  # build gets a new revision instead.
  def publish
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` and `rake image:verify` first")
    end
    unless @registry.digest(@repository, version).nil?
      raise Error, "#{reference} is already published; bump the revision rather than replace it"
    end

    @commands.execute("docker", "push", reference)
  end

  # Each tag's current digest next to the pinned one: a moved digest means
  # upstream rebuilt the base, or Alpine the builder, which is a reason for a
  # new revision even when no other pin changed. Likewise each plugin's newest
  # release tag next to its pin, with the checksum of that tag's archive today.
  def report_available_versions(plugin_source:)
    [[base_image, @base_digest], [@builder_image, @builder_digest]].each do |name, pinned|
      digest = @commands.capture("docker", "buildx", "imagetools", "inspect", name,
                                 "--format", "{{.Manifest.Digest}}")
      raise Error, "cannot read the current digest of #{name}" if digest.nil?

      puts "=== #{name} ==="
      puts "current digest: #{digest.strip}"
      puts "pinned digest:  #{pinned}"
    end
    @plugins.each do |plugin|
      newest = plugin_source.newest(plugin)
      puts "=== #{plugin.name} (#{plugin.repository}) ==="
      puts "newest tag: #{newest.version} #{newest.checksum}"
      puts "pinned tag: #{plugin.version} #{plugin.checksum}"
    end
  end

  def describe
    puts "base image:  #{base_image}@#{@base_digest}"
    puts "builder:     #{@builder_image}@#{@builder_digest}"
    puts "version:     #{version}"
    puts "publishes:   #{reference}"
    puts "release tag: #{release_reference}"
    puts "platforms:   #{@platforms.join(", ")}"
    puts "plugins:"
    @plugins.each { |plugin| puts "  #{plugin.name} #{plugin.version} (#{plugin.repository}) #{plugin.checksum}" }
  end

  # Every Dockerfile `ARG` that varies, in the order the Dockerfile declares them
  def build_arguments
    [
      BuildArgument.new(name: "TRAEFIK_VERSION", value: @traefik_version),
      BuildArgument.new(name: "BASE_DIGEST", value: @base_digest),
      BuildArgument.new(name: "BUILDER_IMAGE", value: @builder_image),
      BuildArgument.new(name: "BUILDER_DIGEST", value: @builder_digest),
      *@plugins.flat_map { |plugin| plugin_arguments(plugin) },
      BuildArgument.new(name: "IMAGE_VERSION", value: version),
      BuildArgument.new(name: "SOURCE_COMMIT", value: source_commit),
    ]
  end

  def labels
    [
      Label.new(name: "org.opencontainers.image.base.name", value: "docker.io/library/#{base_image}"),
      Label.new(name: "org.opencontainers.image.base.digest", value: @base_digest),
      Label.new(name: "org.opencontainers.image.version", value: version),
    ]
  end

  private

  # Upstream ships nothing setuid, and the image runs as uid 1001 with only a
  # file capability; a setuid file would be a path back to uid 0 that this
  # build never meant to add.
  def setuid_check
    FilesystemCheck.new(
      description: "no setuid or setgid files", evidence: "none",
      violations: lambda do |entries|
        entries.select { |entry| entry.file && entry.mode.anybits?(0o6000) }
          .map { |entry| format("%<name>s (%<mode>04o)", name: entry.name, mode: entry.mode & 0o7777) }
      end
    )
  end

  def files_check
    expected = [
      "traefik", "etc/ssl/certs/ca-certificates.crt", "usr/share/zoneinfo/UTC",
      *@plugins.map { |plugin| "plugins-local/src/#{plugin.module_path}/.traefik.yml" },
    ]
    FilesystemCheck.new(
      description: "expected files present", evidence: "#{expected.size} present",
      violations: lambda do |entries|
        names = entries.to_set(&:name)
        expected.reject { |name| names.include?(name) }.map { |name| "missing #{name}" }
      end
    )
  end

  # Traefik keeps serving /ping when a plugin fails to load, so each plugin is
  # proven by a route through it. The bodies are the ones verify/dynamic.yml
  # configures; "rewritten body" is what rewritebody makes of staticresponse's
  # "original body", so it cannot appear unless both plugins ran.
  def service_check
    ServiceCheck.new(
      description: "serves through both plugins",
      arguments: [
        "--entryPoints.web.address=:80", "--entryPoints.traefik.address=:9000", "--ping=true",
        "--providers.file.filename=/verify/dynamic.yml",
        # The plugin names verify/dynamic.yml refers to, as deployment.yml declares them
        "--experimental.localPlugins.rewriteBody.moduleName=#{plugin("rewritebody").module_path}",
        "--experimental.localPlugins.staticResponse.moduleName=#{plugin("staticresponse").module_path}",
      ],
      probes: [
        ServiceCheck::Probe.new(port: 9000, path: "/ping", expected: "OK"),
        ServiceCheck::Probe.new(port: 80, path: "/static", expected: "served by staticresponse"),
        ServiceCheck::Probe.new(port: 80, path: "/rewritten", expected: "rewritten body"),
      ],
      # Any image with a busybox wget would do; the builder is already pinned
      # by digest, so the probe is as reproducible as the build.
      probe_image: "#{@builder_image}@#{@builder_digest}",
      mount: VERIFY_DIRECTORY,
      forbidden_log: "Plugins are disabled"
    )
  end

  def ensure_contains(platform, action:)
    return if contains?(platform)

    raise Error, "#{reference} has no #{platform} image; #{action}"
  end

  # Whether the tag holds an image for this platform — answered by starting
  # one, not by inspecting it.
  #
  # `docker image inspect --platform` exists only from Docker 29, and without
  # it the daemon reports the tag's *host* platform even when the tag is a
  # manifest list. Docker 28 with the containerd image store is exactly that
  # combination, and exactly what the release job builds, so inspection would
  # declare every non-host platform missing. Running the image is the one
  # question every version and image store answers alike; `--pull never` keeps
  # a missing platform a local answer rather than a registry round trip. The
  # image has no /bin/true, so it runs Traefik's own `version`.
  def contains?(platform)
    !@commands.capture("docker", "run", "--rm", "--pull", "never", "--platform", platform.to_s,
                       reference, "version").nil?
  end

  def plugin_arguments(plugin)
    [
      BuildArgument.new(name: "#{plugin.argument_prefix}_VERSION", value: plugin.version),
      BuildArgument.new(name: "#{plugin.argument_prefix}_CHECKSUM", value: plugin.checksum),
    ]
  end

  def ensure_multi_platform_loadable
    return if @platforms.size < 2 || containerd_image_store?

    raise Error, "loading a #{@platforms.size}-platform image into the local daemon requires Docker's " \
                 "containerd image store, which this daemon does not use. Enable it in Docker Desktop " \
                 "(Settings > General > \"Use containerd for pulling and storing images\"), or build one " \
                 "platform at a time with IMAGE_PLATFORMS=#{@platforms.first}"
  end

  def containerd_image_store?
    @commands.capture("docker", "info", "--format", "{{json .DriverStatus}}")
      .to_s.include?("io.containerd.snapshotter")
  end

  # "unknown" rather than an abort, so the image still builds outside a checkout.
  def source_commit
    @commands.capture("git", "rev-parse", "HEAD")&.strip || "unknown"
  end
end

# GitHub Actions workflow linting
class WorkflowLinter
  def initialize(directory: ".github/workflows", tool: "actionlint", commands: CommandRunner.new)
    @directory = directory
    @tool = tool
    @commands = commands
  end

  def lint
    files = workflow_files
    if files.empty?
      puts "no workflows under #{@directory}; nothing to lint"
      return
    end

    # Passed explicitly rather than left to the linter's own discovery, so this
    # cannot pass vacuously when the directory is not where it expects.
    @commands.execute(executable, *files)
  end

  private

  def workflow_files
    Dir.glob(File.join(@directory, "*.{yml,yaml}"))
  end

  def executable
    found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      .map { |directory| File.join(directory, @tool) }
      .find { |candidate| File.executable?(candidate) }
    return found if found

    abort "#{@tool} is not installed, so #{@directory} cannot be linted; " \
          "install it with `brew install #{@tool}`"
  end
end

# Docker registry HTTP API, with anonymous pull access
class Registry
  # A digest has to name what `docker pull` resolves: the manifest list for a
  # multi-platform image, else the single manifest.
  MANIFEST_TYPES = [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
  ].join(", ")

  class Error < StandardError; end

  def initialize(host: "registry-1.docker.io", token_url: "https://auth.docker.io/token",
                 service: "registry.docker.io")
    @host = host
    @token_url = token_url
    @service = service
  end

  # Every tag of a repository, following the API's pagination
  def tags(repository)
    path = "/v2/#{repository}/tags/list?n=1000"
    found = []
    while path
      response = request(Net::HTTP::Get, repository, path)
      raise Error, "listing #{repository} tags: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      found.concat(JSON.parse(response.body).fetch("tags") || [])
      path = response["link"]&.[](%r{<([^>]+)>;\s*rel="next"}, 1)
    end
    found
  end

  # The digest a tag resolves to, or nil when the tag does not exist
  def digest(repository, tag)
    response = request(Net::HTTP::Head, repository, "/v2/#{repository}/manifests/#{tag}", accept: MANIFEST_TYPES)
    return nil if response.is_a?(Net::HTTPNotFound)
    raise Error, "resolving #{repository}:#{tag}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response["docker-content-digest"]
  end

  private

  def request(type, repository, path, accept: nil)
    Net::HTTP.start(@host, 443, use_ssl: true) do |http|
      request = type.new(path)
      request["Authorization"] = "Bearer #{token(repository)}"
      request["Accept"] = accept if accept
      http.request(request)
    end
  end

  def token(repository)
    uri = URI(@token_url)
    uri.query = URI.encode_www_form(service: @service, scope: "repository:#{repository}:pull")
    response = Net::HTTP.get_response(uri)
    raise Error, "token for #{repository}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("token")
  end
end

# The newest release of a plugin on GitHub
#
# Both plugins publish only tags, no GitHub releases, so the newest release is
# the highest `vX.Y.Z` tag. Its checksum is computed from the archive GitHub
# serves today rather than trusted from anywhere else: a tag that moved, or an
# archive GitHub regenerated, changes the checksum and so makes a new revision.
class PluginSource
  RELEASE_TAG = %r{\Av(\d+\.\d+\.\d+)\z}

  class Error < StandardError; end

  # GitHub answers an archive URL with a redirect to codeload.github.com
  def self.download(url, redirects: 5)
    uri = URI(url)
    redirects.times do
      response = Net::HTTP.get_response(uri)
      case response
      when Net::HTTPSuccess then return response.body
      when Net::HTTPRedirection then uri = URI.join(uri.to_s, response["location"])
      else raise Error, "downloading #{url}: HTTP #{response.code}"
      end
    end
    raise Error, "downloading #{url}: more than #{redirects} redirects"
  end

  def initialize(commands: CommandRunner.new, downloader: self.class.method(:download))
    @commands = commands
    @downloader = downloader
    @newest = {}
  end

  # The plugin at its newest release tag, with that archive's checksum. Asked
  # once per repository: a mirror run asks for every version it handles.
  def newest(plugin)
    @newest[plugin.repository] ||= begin
      tagged = plugin.with(version: newest_tag(plugin.repository))
      tagged.with(checksum: "sha256:#{Digest::SHA256.hexdigest(@downloader.call(tagged.archive_url))}")
    end
  end

  private

  def newest_tag(repository)
    output = @commands.capture("gh", "api", "--paginate", "repos/#{repository}/tags", "--jq", ".[].name")
    raise Error, "cannot list the tags of #{repository}" if output.nil?

    newest = output.lines.map(&:strip).grep(RELEASE_TAG)
      .max_by { |tag| Gem::Version.new(tag[RELEASE_TAG, 1]) }
    raise Error, "#{repository} has no vX.Y.Z tag" if newest.nil?

    newest
  end
end

# The version-bearing lines of one release line's files: the IMAGE literal, the
# Dockerfile's ARG defaults, the README's published tag and deployment.yml's
# image
#
# Edits are line-anchored and must each match exactly once, so a file whose
# shape has drifted fails the edit instead of being half rewritten. Every edit
# of every file is made in memory first and the files are written only when all
# of them matched, so a failure leaves the tree as it was. It only ever changes
# values; a new plugin or platform is a human's change.
class SourceTree
  Release = Data.define(:traefik_version, :base_digest, :revision, :plugins) do
    def version
      "#{traefik_version}-scratch.#{revision}"
    end
  end

  class Error < StandardError; end

  # The IMAGE literal, and any plugin in it whatever its indentation or layout,
  # so a reformatted plugin is noticed
  LITERAL = %r{^IMAGE = Image\.new\(\n(.*?)^\)\.freeze$}m
  PLUGIN_START = %r{^ *Image::Plugin\.new\(}

  # One plugin's block of the IMAGE literal, located by its `name:` line; the
  # same lines #plugin_block writes
  def self.plugin_pattern(name)
    Regexp.new(
      [
        "^    Image::Plugin\\.new\\(",
        %(      name: "(#{name})",),
        %(      repository: "([^"]+)",),
        %(      version: "([^"]+)",),
        %(      checksum: "([^"]+)"),
        "    \\),$",
      ].join("\n")
    )
  end

  PLUGIN = plugin_pattern(%([^"]+))

  def initialize(directory)
    @directory = directory
  end

  def read
    rakefile = file("Rakefile")
    Release.new(traefik_version: value(rakefile, "Rakefile", %r{^  traefik_version: "([^"]+)",$}),
                base_digest: value(rakefile, "Rakefile", %r{^  base_digest: "([^"]+)",$}),
                revision: Integer(value(rakefile, "Rakefile", %r{^  revision: (\d+),$})),
                plugins: plugins(rakefile))
  end

  def repository
    value(file("Rakefile"), "Rakefile", %r{^  repository: "([^"]+)",$})
  end

  def write(release)
    edited = {
      "Rakefile" => edit_rakefile(release),
      "Dockerfile" => edit_dockerfile(release),
      "README.md" => replace(file("README.md"), "README.md", %r{^Published as \*\*`[^`]+`\*\*\.$},
                             "Published as **`#{published(release)}`**."),
      "deployment.yml" => replace(file("deployment.yml"), "deployment.yml", %r{^        image: .*$},
                                  "        image: #{published(release)}"),
    }
    edited.each { |name, text| File.write(File.join(@directory, name), text) }
  end

  private

  def edit_rakefile(release)
    text = file("Rakefile")
    text = replace(text, "Rakefile", %r{^  traefik_version: "[^"]+",$}, %(  traefik_version: "#{release.traefik_version}",))
    text = replace(text, "Rakefile", %r{^  base_digest: "[^"]+",$}, %(  base_digest: "#{release.base_digest}",))
    text = replace(text, "Rakefile", %r{^  revision: \d+,$}, "  revision: #{release.revision},")
    release.plugins.reduce(text) do |result, plugin|
      replace(result, "Rakefile", self.class.plugin_pattern(Regexp.escape(plugin.name)), plugin_block(plugin))
    end
  end

  def edit_dockerfile(release)
    text = file("Dockerfile")
    text = replace(text, "Dockerfile", %r{^ARG TRAEFIK_VERSION=.*$}, "ARG TRAEFIK_VERSION=#{release.traefik_version}")
    text = replace(text, "Dockerfile", %r{^ARG BASE_DIGEST=.*$}, "ARG BASE_DIGEST=#{release.base_digest}")
    text = replace(text, "Dockerfile", %r{^ARG IMAGE_VERSION=.*$}, "ARG IMAGE_VERSION=#{release.version}")
    release.plugins.reduce(text) do |result, plugin|
      { "VERSION" => plugin.version, "CHECKSUM" => plugin.checksum }.reduce(result) do |edited, (suffix, setting)|
        argument = "#{plugin.argument_prefix}_#{suffix}"
        replace(edited, "Dockerfile", %r{^ARG #{argument}=.*$}, "ARG #{argument}=#{setting}")
      end
    end
  end

  # Every `Image::Plugin.new(` in the IMAGE literal has to be a block of the
  # expected shape: one that is not would otherwise drop silently out of what
  # the mirror keeps current.
  def plugins(rakefile)
    literal = value(rakefile, "Rakefile", LITERAL)
    blocks = literal.scan(PLUGIN)
    starts = literal.scan(PLUGIN_START).size
    unless blocks.size == starts
      raise Error, "#{starts} Image::Plugin.new blocks in #{path("Rakefile")}, but only #{blocks.size} " \
                   "of the expected shape"
    end

    blocks.map do |name, repository, version, checksum|
      Image::Plugin.new(name: name, repository: repository, version: version, checksum: checksum)
    end
  end

  def plugin_block(plugin)
    [
      "    Image::Plugin.new(",
      %(      name: "#{plugin.name}",),
      %(      repository: "#{plugin.repository}",),
      %(      version: "#{plugin.version}",),
      %(      checksum: "#{plugin.checksum}"),
      "    ),",
    ].join("\n")
  end

  def published(release)
    "#{repository}:#{release.version}"
  end

  def path(name)
    File.join(@directory, name)
  end

  def file(name)
    File.read(path(name))
  end

  def value(text, name, pattern)
    matches = text.scan(pattern)
    raise Error, "expected one match of #{pattern.source} in #{path(name)}, found #{matches.size}" \
      unless matches.size == 1

    matches.first.first
  end

  def replace(text, name, pattern, line)
    count = text.scan(pattern).size
    raise Error, "expected one match of #{pattern.source} in #{path(name)}, found #{count}" unless count == 1

    text.sub(pattern) { line }
  end
end

# Tracks every upstream traefik:v<version> at or above a floor, each on a
# release line of its own: branch `<version>-scratch.x`, released as tags
# `v<version>-scratch.<revision>`
#
# Versions are handled oldest first, one at a time, and the first failure stops
# the run, so a release never overtakes an older one that is still broken.
class Mirror
  class Error < StandardError; end

  def initialize(upstream:, repository:, floor:, release_workflow:,
                 registry: Registry.new, plugin_source: PluginSource.new, commands: CommandRunner.new)
    @upstream = upstream
    @repository = repository
    @floor = Gem::Version.new(floor)
    @release_workflow = release_workflow
    @registry = registry
    @plugin_source = plugin_source
    @commands = commands
  end

  # Upstream releases at or above the floor, oldest first. Only exact `vX.Y.Z`
  # tags: the bare `X.Y.Z` tags and the moving `vX.Y`, `vX` and `latest` tags
  # alias these, release candidates are not releases, and the
  # `-nanoserver-…` tags are Windows images.
  def versions
    @registry.tags(@upstream)
      .filter_map { |tag| tag[%r{\Av(\d+\.\d+\.\d+)\z}, 1] }
      .map { |text| Gem::Version.new(text) }
      .select { |version| version >= @floor }
      .sort
  end

  def plan
    versions.each do |version|
      released = released_revisions(version)
      latest = released.empty? ? "nothing released" : "latest #{tag_for(version, released.max)}"
      puts "#{version}: branch #{branch_for(version)}, #{latest}"
    end
  end

  def sync_all(dry_run:)
    versions.each { |version| sync(version, dry_run: dry_run) }
  end

  def sync(version, dry_run:)
    digest = @registry.digest(@upstream, "v#{version}")
    raise Error, "#{@upstream}:v#{version} has no digest" if digest.nil?

    released = released_revisions(version)
    with_worktree(start_point(version)) do |directory|
      tree = SourceTree.new(directory)
      current = tree.read
      desired = current.with(traefik_version: version.to_s, base_digest: digest,
                             plugins: current.plugins.map { |plugin| follow(plugin) })
      if desired == current && released.include?(current.revision)
        up_to_date(version, current, directory, dry_run: dry_run)
      else
        release = desired.with(revision: released.empty? ? 0 : released.max + 1)
        tree.write(release)
        cut_release(version, release, current, directory, dry_run: dry_run)
      end
    end
  end

  # Revisions taken, by git tag or by published image. Docker Hub counts too:
  # git tags can be deleted, and a revision reused after that would overwrite
  # an image someone may be running. Only `<version>-scratch.<n>` counts, so
  # the repository's older `v<version>` and `<version>` tags take no revision.
  def released_revisions(version)
    tagged = (@commands.capture("git", "tag", "--list", "v#{version}-scratch.*") || "")
      .lines.map { |tag| tag.strip.delete_prefix("v") }
    pattern = %r{\A#{Regexp.escape(version.to_s)}-scratch\.(\d+)\z}
    (tagged + published_tags).filter_map { |tag| tag[pattern, 1]&.to_i }.uniq
  end

  private

  # The plugin's newest release tag. The line may only move forward: a pin that
  # is not a release tag cannot be compared, and a plugin whose newest tag is
  # older than the pin (a deleted tag, say) would otherwise be published as a
  # downgrade on every line.
  def follow(plugin)
    pinned = plugin.version[PluginSource::RELEASE_TAG, 1]
    raise Error, "#{plugin.name} is pinned to #{plugin.version.inspect}, not a vX.Y.Z tag" if pinned.nil?

    newest = @plugin_source.newest(plugin)
    if Gem::Version.new(newest.version[PluginSource::RELEASE_TAG, 1]) < Gem::Version.new(pinned)
      raise Error, "#{plugin.name}'s newest tag #{newest.version} is older than the pinned #{plugin.version}"
    end

    newest
  end

  def up_to_date(version, current, directory, dry_run:)
    tag = tag_for(version, current.revision)
    puts "#{version}: up to date at #{tag}"
    push_branch(version, directory, dry_run: dry_run) unless remote_branch?(version)
    if @registry.digest(@repository, current.version).nil?
      puts "#{version}: #{@repository}:#{current.version} is not published"
      publish(tag, dry_run: dry_run)
    end
  end

  # Verified before anything is committed, so an upstream release this image
  # cannot handle leaves no tag behind — only a failed run to look at.
  def cut_release(version, release, previous, directory, dry_run:)
    tag = tag_for(version, release.revision)
    puts "#{version}: #{tag} — #{changes(previous, release).join("; ")}"
    @commands.execute("rake", "test", chdir: directory)
    if dry_run
      puts "#{version}: dry run, so #{tag} is verified but not committed, tagged or published"
      return
    end

    # Nothing to commit when the line already holds this release but it was
    # never tagged — main's own literal, for one. The tag then goes on as is.
    unless @commands.capture("git", "status", "--porcelain", chdir: directory).to_s.empty?
      git(directory, "commit", "--all", "--quiet", "--message", commit_message(release, previous))
    end
    git(directory, "tag", "--annotate", tag, "--message", "Traefik #{version} on scratch with local plugins")
    push_branch(version, directory, dry_run: dry_run)
    @commands.execute("git", "push", "origin", "refs/tags/#{tag}", chdir: directory)
    publish(tag, dry_run: dry_run)
  end

  def changes(previous, release)
    found = []
    found << "Traefik #{previous.traefik_version} -> #{release.traefik_version}" \
      if previous.traefik_version != release.traefik_version
    found << "base #{previous.base_digest} -> #{release.base_digest}" if previous.base_digest != release.base_digest
    release.plugins.each do |plugin|
      before = previous.plugins.find { |candidate| candidate.name == plugin.name }
      if before.version != plugin.version
        found << "#{plugin.name} #{before.version} -> #{plugin.version}"
      elsif before.checksum != plugin.checksum
        found << "#{plugin.name} #{plugin.version} checksum #{before.checksum} -> #{plugin.checksum}"
      end
    end
    found.empty? ? ["unreleased commit"] : found
  end

  def commit_message(release, previous)
    "chore: release #{release.version}\n\n" + changes(previous, release).map { |change| "- #{change}\n" }.join
  end

  # Tags pushed with the workflow token start no workflows, so the release is
  # dispatched explicitly — on the tag, which the release environment admits —
  # and waited for, so releases land in order.
  def publish(tag, dry_run:)
    if dry_run
      puts "dry run, so #{tag} is not released"
      return
    end

    dispatched = Time.now.utc
    @commands.execute("gh", "workflow", "run", @release_workflow, "--ref", tag)
    @commands.execute("gh", "run", "watch", dispatched_run(tag, dispatched).to_s, "--exit-status", "--interval", "30")
  end

  def dispatched_run(tag, dispatched)
    60.times do
      output = @commands.capture("gh", "run", "list", "--workflow", @release_workflow, "--event", "workflow_dispatch",
                                 "--branch", tag, "--json", "databaseId,createdAt", "--limit", "10")
      run = JSON.parse(output || "[]").find { |candidate| Time.parse(candidate["createdAt"]) >= dispatched - 10 }
      return run["databaseId"] if run

      sleep 5
    end
    raise Error, "the #{@release_workflow} run for #{tag} never appeared"
  end

  # The existing branch, else this checkout's HEAD — never an older tag, even
  # for a version released before its branch existed. A release is published by
  # dispatching the release workflow on its tag, which needs that tag's copy of
  # the workflow to accept dispatch; only current tooling is sure to. The tags
  # still set the next revision, so nothing is renumbered.
  def start_point(version)
    remote_branch?(version) ? "origin/#{branch_for(version)}" : "HEAD"
  end

  # A detached worktree, so no local branch is created or left behind; a
  # release pushes HEAD to the branch by name.
  def with_worktree(start)
    Dir.mktmpdir("mirror-") do |parent|
      directory = File.join(parent, "tree")
      @commands.execute("git", "worktree", "add", "--quiet", "--detach", directory, start)
      begin
        yield directory
      ensure
        @commands.execute("git", "worktree", "remove", "--force", directory)
      end
    end
  end

  def push_branch(version, directory, dry_run:)
    if dry_run
      puts "dry run, so branch #{branch_for(version)} is not pushed"
      return
    end

    @commands.execute("git", "push", "origin", "HEAD:refs/heads/#{branch_for(version)}", chdir: directory)
  end

  def published_tags
    @published_tags ||= @registry.tags(@repository)
  end

  def remote_branch?(version)
    !@commands.capture("git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch_for(version)}").nil?
  end

  def git(directory, *)
    @commands.execute("git", *, chdir: directory)
  end

  def branch_for(version)
    "#{version}-scratch.x"
  end

  def tag_for(version, revision)
    "v#{version}-scratch.#{revision}"
  end
end

# The mirror's SourceTree reads and rewrites this literal by line shape, so the
# shapes are an interface: `  traefik_version: "…",`, `  base_digest: "…",`,
# `  revision: N,` and each plugin's six-line `Image::Plugin.new(` block, with
# its keywords one per line in this order and no trailing comma after
# `checksum:`. A reformatted line fails the mirror rather than corrupting it,
# but it does fail it. A new plugin's Dockerfile ARGs are named after it
# (`rewritebody` -> `REWRITEBODY_VERSION`, `REWRITEBODY_CHECKSUM`).
IMAGE = Image.new(
  repository: "jochen/traefik",
  traefik_version: "3.7.17",
  # The manifest list behind traefik:v<version>. `rake image:versions` prints
  # the tag's current one.
  base_digest: "sha256:30ff62491aacdb862ceb8c9edcf2627da638d7deafdd4b6dab32fe34f8aa3e90",
  # Only unpacks plugin archives and sets a file capability, but pinned all the
  # same so that a build is reproducible. Bumped by hand.
  builder_image: "alpine:3.24.1",
  builder_digest: "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
  # Bumped when the image changes but Traefik does not; reset on a version bump.
  revision: 0,
  platforms: ["linux/amd64", "linux/arm64"].map { |text| Image::Platform.parse(text) },
  plugins: [
    Image::Plugin.new(
      name: "rewritebody",
      repository: "traefik/plugin-rewritebody",
      version: "v0.3.1",
      checksum: "sha256:41dad57a5a49d462a9d7ee3f13b7f9a3fe9d64c1fc458ee43448a31780c8e3b0"
    ),
    Image::Plugin.new(
      name: "staticresponse",
      repository: "jdel/staticresponse",
      version: "v0.0.1",
      checksum: "sha256:211c02d6ff74ee07e95939ba35c4174e15935c9338ede0df8c85d23b0ef5ab67"
    ),
  ]
).freeze

MIRROR = Mirror.new(
  upstream: "library/traefik",
  repository: IMAGE.repository,
  # The oldest upstream release tracked, inclusive. Lowering this backfills
  # older releases, oldest first.
  floor: "3.7.10",
  release_workflow: "release.yml"
)

def selected_image
  requested = ENV.fetch("IMAGE_PLATFORMS", "").split(",").map(&:strip).reject(&:empty?)
  return IMAGE if requested.empty?

  IMAGE.with_platforms(requested.map { |text| Image::Platform.parse(text) })
end

namespace "image" do
  desc "Print the configuration: base image, published tag and pinned plugin versions"
  task "config" do
    selected_image.describe
  end

  desc "Print the fully qualified image reference"
  task "reference" do
    puts selected_image.reference
  end

  desc "Print the git tag this revision expects to be released under"
  task "release_ref" do
    puts selected_image.release_reference
  end

  desc "Build one multi-platform image and load it into the local daemon"
  task "build" do
    selected_image.build
  end

  desc "Run the verification checks against the locally built image"
  task "verify" do
    selected_image.verify
  end

  desc "Push the already-built local image, without building or verifying"
  task "publish" do
    selected_image.publish
  end

  desc "Build, verify, then push"
  task "push" => %w[build verify publish]

  desc "Report the current base and builder digests and the newest plugin tags, for bumping the pins"
  task "versions" do
    selected_image.report_available_versions(plugin_source: PluginSource.new)
  end
end

namespace "mirror" do
  desc "List the tracked upstream releases, oldest first, with their release lines"
  task "plan" do
    MIRROR.plan
  end

  desc "Release every tracked upstream version whose base or plugins moved (DRY_RUN=true stops before committing)"
  task "sync" do
    MIRROR.sync_all(dry_run: ENV.fetch("DRY_RUN", "false") == "true")
  end
end

desc "Build and verify the image"
task "test" => ["image:build", "image:verify"]

Rake::TestTask.new("unit") do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.description = "Run the unit tests"
end

namespace "lint" do
  desc "Lint the GitHub Actions workflows with actionlint"
  task "github" do
    WorkflowLinter.new.lint
  end
end

desc "Run every linter"
task "lint" => "lint:github"
