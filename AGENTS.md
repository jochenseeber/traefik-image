# Agent Instructions

Read [README.md](README.md) first. It covers what the image is, how it is
versioned, built, verified, mirrored and released. Everything below is only for
agents and is not repeated there.

## The one rule that matters here

The `IMAGE` literal near the bottom of the `Rakefile` is the single source of
truth for every version. It is the composition root: the only place that names
concrete versions, reads the environment (`IMAGE_PLATFORMS`) and wires the
objects together. `Image` itself is told everything at construction and is
frozen, so do not move configuration into constants on the class or have it
consult `ENV`. That is the design, not an accident.

When asked to bump anything, change that literal and run `rake test`.

Two places deliberately repeat what the literal says, and both must be changed
with it:

- the `Dockerfile`'s `ARG` defaults, so a bare `docker build` still works;
- the `build` matrix in `.github/workflows/ci.yml`, which states its platforms
  rather than computing them.

This duplication is a decision, not an oversight. Do not reintroduce a
generated matrix or a separate manifest file to remove it. `rake unit` catches
a `Dockerfile` that has drifted
(`test_dockerfile_defaults_match_the_image_literal` in `test/image_test.rb`);
`rake image:verify` cannot, because builds pass every `ARG` explicitly. Nothing
catches a CI matrix missing a platform the `Rakefile` lists, which would then
be published unverified, so that is the pairing to be careful with.

## Do not "fix" these

They look like oversights and are not:

- **No shell in the image, and checks that go around it.** The final stage is
  `FROM scratch`. Do not add busybox "for debugging" or a `HEALTHCHECK` that
  needs one. The checks run the Traefik binary, read the exported filesystem,
  or use a separate probe container (the pinned builder image, for its `wget`)
  that shares the service container's network namespace.
- **Port 80 is tested with a sysctl and a dropped capability set.** Docker sets
  `net.ipv4.ip_unprivileged_port_start=0` in every container, so any user can
  bind port 80 and a plain "binds :80" check passes even without the file
  capability. The service check sets it back to 1024 and drops every capability
  but `NET_BIND_SERVICE`. Removing either makes the check vacuous. Run any
  change to it against an image built without `setcap` as a negative control:
  it has to fail there.
- **Plugins are proven by routes, not by `/ping`.** Traefik logs "Plugins are
  disabled" and keeps serving `/ping` when a plugin fails to load. The routes
  in `verify/dynamic.yml` and the expected bodies in the `Rakefile` go
  together; change them together.
- **Every plugin is pinned by tag and by checksum.** The tag alone can be
  moved. The `Dockerfile` hands the checksum to `ADD --checksum`.
- **No `# syntax=` directive in the `Dockerfile`.** It would pull a frontend
  image from the registry at a floating tag, in a project whose point is that
  nothing floats.
- **`libcap` is not pinned.** It only provides `setcap` at build time and
  leaves nothing in the final image; the builder image itself is pinned by
  digest, and bumped by hand because the mirror does not touch it.
- **A tag _and_ a digest in `FROM`.** The digest is the pin; the tag is
  documentation, which Docker ignores when a digest is present. Do not drop
  either. `BASE_DIGEST` is declared twice in the `Dockerfile` on purpose: an
  `ARG` before `FROM` is out of scope after it, and the label needs it.
- **Everything in one `Rakefile`.** There is no `rakelib/`. `.rubocop.yml`
  excludes the `Rakefile` from `Style/OneClassPerFile` for exactly this reason.
  The `Rakefile` uses only the standard library; dev gems live in the Gemfile.
- **No rescue around the task bodies.** Rake already aborts with exit 1 and
  prints the exception message; a wrapper would only hide the backtrace.
- **`runs-on: ubuntu-24.04`, not `ubuntu-latest`.** Pinned like everything
  else, and deliberately on the image shipping Docker 28, which has no
  `--platform` on `docker image inspect`. `Image` has fallbacks for that; a
  newer runner leaves them untested.
- **No Docker Hub login in CI or in the mirror.** They pull only public images.
  The push token stays in `release.yml`'s `release` environment, and an
  environment secret reaches only a job that names its environment. Removing
  `environment: release` does not fall back to repository secrets; the secrets
  resolve to empty and the login fails.
- **`Image#version` with no separate tag method.** The format
  (`3.7.15-scratch.0`) uses only characters Docker accepts in a tag, so the
  image tag, the git tag and the version label are one string. Semver build
  metadata (`+scratch`) would be invalid as a Docker tag.
- **`image:publish` is a plain `docker push`** of the already-loaded image, on
  purpose: the published bytes are the verified ones. Do not turn it into a
  `buildx --push`, and keep its refusal to push a missing, partial or already
  published tag.

## The mirror

`rake mirror:sync` (run daily by `.github/workflows/mirror.yml`) keeps a
release line per upstream release. README.md, "Mirroring upstream releases",
covers what it does; these are the constraints on changing it.

- **The line shapes of the `IMAGE` literal are an interface.** `SourceTree`
  reads and rewrites `traefik_version: "…",`, `base_digest: "…",`,
  `revision: N,` and each plugin's six-line `Image::Plugin.new(` block
  (keywords one per line, in order, no trailing comma after `checksum:`) by
  line-anchored pattern, along with the `Dockerfile`'s `ARG` defaults, the
  `Published as` line in the README and the `image:` line in `deployment.yml`.
  Each edit must match exactly once, so a reformatted line fails the run rather
  than corrupting it, but it does fail it. Name a new plugin's `ARG`s after the
  plugin (`rewritebody` gives `REWRITEBODY_VERSION` and
  `REWRITEBODY_CHECKSUM`).
- **Strictly serial, stopping at the first failure.** That is how order is
  guaranteed. Do not turn it into a matrix or let it skip a failing version.
- **Verified before committed.** `rake test` runs in the line's worktree before
  anything is committed or tagged, so a base or plugin this image cannot handle
  leaves no tag behind. Do not move the commit before it, and do not drop it as
  a duplicate: `release.yml` skips its CI job for runs the mirror dispatched
  (`github.actor == 'github-actions[bot]'`), so the mirror's run is the CI for
  its releases.
- **Published by dispatch, not by the tag push.** A tag pushed with the
  workflow token starts no workflows; `workflow_dispatch` is the exception. So
  the mirror dispatches `release.yml` on the tag and waits for it. Removing
  `workflow_dispatch` from `release.yml` stops every automated release.
- **New lines fork from `main`, never from an older tag**, even for a version
  released before its line existed. Tags still set the next revision, so
  nothing is renumbered. `main` is the template: its `IMAGE` literal is what a
  new line starts from, and changes to `main` reach an existing line only when
  merged into its branch by hand.
- **Detached worktrees, no local branches.** The mirror pushes
  `HEAD:refs/heads/<branch>`, so a run leaves no branch behind, and a dry run
  leaves nothing at all.
- **Revisions come from git tags and Docker Hub together.** Git tags can be
  deleted; reusing a published revision would overwrite an image someone may
  run.

## Verification

`rake image:verify` is not optional before publishing, and it must keep testing
every platform the image is configured for, not just the host's. Every
hardening check should be run against an image it is meant to guard against, as
a negative control, and fail there. A check that passes on the broken image
proves nothing.

Report what `rake image:verify` and `rake test` actually printed. They name the
versions and bodies they found, so quoting them is cheap and a claim without
them is not verification.
