# Traefik Image

This repository contains the Dockerfile to create a
[Traefik](https://traefik.io/traefik/) image that allows Traefik to bind to
service (low) ports without being started as root.

Published as **`jochen/traefik:3.7.12-scratch.0`**.

The image is derived from the official
[Traefik image](https://hub.docker.com/_/traefik) and sets
`cap_net_bind_service=ep` on the Traefik binary.

Also, the following useful plugins get added to the image:

- [plugin-rewritebody](https://github.com/traefik/plugin-rewritebody)
- [staticresponse](https://github.com/jdel/staticresponse)

The image is built `FROM scratch`: it contains the Traefik binary, the CA
certificates and time zone data from the official image, and the two plugins
under `/plugins-local`, and nothing else. There is no shell. It runs as
`1001:1001` and its entrypoint is `/traefik`. It is built for `linux/amd64` and
`linux/arm64`.

## Versions

Versions are semantic: `3.7.15` is the upstream Traefik release, and the
`scratch.0` prerelease names the variant and counts rebuilds of it. One string
serves everywhere: the image tag, the git tag (`v3.7.15-scratch.0`) and the
`org.opencontainers.image.version` label are the same characters, because the
format uses nothing Docker rejects in a tag. There is no `latest` tag.

A rebuild without a Traefik bump (a rebuilt base image, a new plugin release)
increments the revision, giving `-scratch.1`, `-scratch.2` and so on.

## Running

See [this file](deployment.yml) for an example how to deploy on Kubernetes.

## Building

Requires Docker with buildx, and, to build more than one platform locally,
Docker's containerd image store. Ruby is the version in `.ruby-version`; run
`bundle install` for the development gems (the `Rakefile` itself uses only the
standard library).

```bash
rake image:config    # show what would be built and published
rake image:build     # one multi-platform build, loaded locally
rake image:verify    # run the checks against each platform in it
rake image:push      # build, verify, then push exactly what was verified
```

`rake -T` lists every task. `rake test` is `image:build` plus `image:verify`;
`rake unit` runs the unit tests and `rake lint` lints the workflows with
[actionlint](https://github.com/rhysd/actionlint). Set `IMAGE_PLATFORMS` (for
example `IMAGE_PLATFORMS=linux/arm64`) to build and verify a subset of the
configured platforms.

`image:build` produces a single multi-platform image under the tag it will be
published as, so what gets verified is the artifact itself. `image:verify` then
reaches each architecture out of that one manifest list with
`docker run --platform`.

### What `image:verify` checks

The image has no shell, so every check runs the Traefik binary, a separate
probe container, or inspects the exported files. On each platform it checks:

- that `traefik version` reports the pinned Traefik version;
- that the image runs as `1001:1001` and its entrypoint is `/traefik`;
- that no file is setuid or setgid;
- that the Traefik binary, the CA certificates, the time zone data and both
  plugins' `.traefik.yml` are present;
- that Traefik starts on a read-only root filesystem with every capability
  dropped except `NET_BIND_SERVICE`, and with
  `net.ipv4.ip_unprivileged_port_start=1024`, and serves `/ping` on `:9000` and
  two routes on `:80`. Docker lets any user bind port 80 by default, so without
  the sysctl the check would pass even if the file capability were missing. One
  route is answered by `staticresponse`; the other is `staticresponse`
  rewritten by `rewritebody`. Traefik keeps serving `/ping` when a plugin fails
  to load, so the routes, together with a check that the log does not say
  `Plugins are disabled`, are what prove the plugins work;
- the `org.opencontainers.image.base.name`, `.base.digest` and `.version`
  labels.

The routes are configured in [`verify/dynamic.yml`](verify/dynamic.yml).

### Versions are pinned, on purpose

The base image, the Alpine builder image, and both plugins are pinned. The base
and builder are pinned by digest. Each plugin is pinned by its tag _and_ by the
SHA-256 of the tag's source archive, which BuildKit checks on download, so a
tag that is moved upstream fails the build instead of changing the image.
Nothing floats, so fixes only arrive as a new revision.

`rake image:versions` reports the current base and builder digests and the
newest plugin tags next to the pinned ones. The mirror (below) follows the base
and the plugins; the builder is only used to run `setcap` and unpack the
plugins, so it is bumped by hand.

The CI runners are pinned too (`ubuntu-24.04`, not `ubuntu-latest`).

## Mirroring upstream releases

New Traefik releases and plugin updates are picked up automatically.
`.github/workflows/mirror.yml` runs daily (and on demand) and keeps one
**release line** per upstream release:

- **branch `<version>-scratch.x`**, e.g. `3.7.15-scratch.x`, holding the files
  for that Traefik release;
- **tags `v<version>-scratch.<revision>`** cut from it, each published as
  `jochen/traefik:<version>-scratch.<revision>`.

It tracks every exact `vX.Y.Z` tag of the official `library/traefik` image at
or above the `floor` in the `Rakefile` (`3.7.10`). Moving tags such as `v3.7`,
the bare `3.7.15`, release candidates and the Windows variants are not
releases. For each, **oldest first**, it compares the line's current `IMAGE`
literal with what is available now: the tag's digest, and the newest `vX.Y.Z`
tag of each plugin together with the checksum of its archive. If anything moved
it writes the next revision into the line, runs `rake test`, and only then
commits, tags, pushes and publishes. A new line starts at revision `0`, forked
from `main`.

Plugin updates apply to **every** release line, not just the newest one: a new
plugin release (or a moved tag or archive) creates a new revision on each line
the next time the mirror runs.

Order is guaranteed by doing one version at a time and stopping at the first
failure: a failing older line stops the newer ones, so a later release never
lands while an earlier one is broken, and the next run retries from the same
place. Each release also waits for its publish run to finish before the next
version starts. A failure is the signal that an upstream release or plugin
needs a human: fix the line's branch (or `main`, for a line that does not exist
yet) and the next run carries on.

Revisions already taken are never reused: they are counted from the line's git
tags and from the tags in the Docker Hub repository, so deleting a git tag does
not free a published revision. Tags in the older `v3.7.10` style do not count.

Two things a person still decides: the `floor`, and changes to the image
itself. A Dockerfile or tooling change on `main` reaches an existing line only
when merged into its branch and released by hand, as below.

```bash
rake mirror:plan                 # what is tracked, and each line's latest tag
DRY_RUN=true rake mirror:sync    # verify what would be released, change nothing
```

The workflow's own dry run (`workflow_dispatch` with `dry_run`) does the same
on a runner.

## Bumping versions by hand

The mirror normally does this. By hand it is the same steps, which still apply
to `main` and to a release line being fixed.

Everything version-shaped lives in the `IMAGE` literal near the bottom of the
[`Rakefile`](Rakefile). The Dockerfile's `ARG` defaults mirror it so a bare
`docker build` works, and have to be updated alongside.

1. Run `rake image:versions` to see the current digests and plugin tags.
2. Set `traefik_version` and `base_digest` in the literal (and `revision` back
   to `0`), or change a plugin's `version` and `checksum`, or the builder.
3. Mirror the change into the Dockerfile's `ARG` defaults, the `Published as`
   line in this file and the `image:` in `deployment.yml`. Forgetting the base
   digest builds the _old_ release under the new tag, because Docker ignores
   the tag when a digest is present; `rake test` fails on the version check.
4. `rake test`, then commit.
5. Tag with the reference the `Rakefile` now expects (annotated, because
   `--follow-tags` pushes only annotated tags) and push the tag:

   ```bash
   tag="$(rake --silent image:release_ref)"
   git tag --annotate "$tag" --message "Release $tag"
   git push origin main --follow-tags
   ```

   The release workflow refuses any tag that disagrees with the `Rakefile`.

To rebuild without a Traefik bump, leave `traefik_version` alone and increment
`revision`.

### Adding a platform

The `platforms` list in the `Rakefile` and the `build` matrix in
`.github/workflows/ci.yml` are separate lists, on purpose. Change both
together.

## Releasing

`.github/workflows/release.yml` fires on a `v*` tag. It checks that the tag
matches the `Rakefile`, runs the full CI suite for that commit, and only then
builds, verifies and pushes, with the same `rake image:push` a workstation
runs.

The mirror's tags reach it differently: a tag pushed with the workflow token
starts no workflows, so the mirror dispatches `release.yml` on the tag instead.
A dispatch on anything but a matching tag fails its tag check. Such a run skips
the CI job, because the mirror already built and verified that exact commit
before tagging it; the publish job still builds and verifies before it pushes.

`image:publish` is a plain `docker push` of the image already in the local
daemon, so the bytes that reach Docker Hub are the ones `image:verify` ran its
checks against. It refuses to push a tag that is absent, missing a platform, or
already published.

### One-time GitHub setup

- Create the environment **`release`** (Settings, Environments) with two
  secrets, and restrict its deployment policy to `v*` tags:
  - `DOCKERHUB_USERNAME`: the Docker Hub account that owns the namespace.
  - `DOCKERHUB_TOKEN`: an access token for it, not the account password.
- Under Settings, Actions, General, allow **read and write permissions** for
  workflows. The mirror pushes branches and tags and dispatches the release.
- Do not protect `main` or the `*-scratch.x` branches: the mirror pushes to
  them directly.

The publish job declares `environment: release`, which is what makes the
secrets visible to it. CI holds no Docker Hub credentials at all; it only pulls
public images.

## Layout

- `Rakefile`: single source of truth (Traefik version, base digest, plugins,
  revision, platforms, the mirror's floor), the `image:*` and `mirror:*` tasks
  and `rake lint`.
- `Dockerfile`: the image.
- `verify/dynamic.yml`: the Traefik configuration `image:verify` serves.
- `deployment.yml`: example Kubernetes deployment.
- `test/`: unit tests, run by `rake unit`.
- `.github/workflows/`: CI (lint, then build and verify per platform), release
  (publish) and mirror (track upstream releases).

## License

[MIT](LICENSE.txt), for the files in this repository. The image they build also
contains software under its own licenses.
