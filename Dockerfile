# The defaults mirror IMAGE in the Rakefile, so a plain `docker build .` builds
# the same image as `rake image:build`. The Rakefile passes every one of them
# explicitly, and the mirror rewrites both together.
ARG TRAEFIK_VERSION=3.7.14
ARG BASE_DIGEST=sha256:575fa15b135078fe5e50aa847987d96dbddd7b093c172429618404df73f3fa7c
ARG BUILDER_IMAGE=alpine:3.24.1
ARG BUILDER_DIGEST=sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ARG REWRITEBODY_VERSION=v0.3.1
ARG REWRITEBODY_CHECKSUM=sha256:41dad57a5a49d462a9d7ee3f13b7f9a3fe9d64c1fc458ee43448a31780c8e3b0
ARG STATICRESPONSE_VERSION=v0.0.1
ARG STATICRESPONSE_CHECKSUM=sha256:211c02d6ff74ee07e95939ba35c4174e15935c9338ede0df8c85d23b0ef5ab67

FROM traefik:v${TRAEFIK_VERSION}@${BASE_DIGEST} AS traefik

FROM ${BUILDER_IMAGE}@${BUILDER_DIGEST} AS builder
ARG REWRITEBODY_VERSION
ARG REWRITEBODY_CHECKSUM
ARG STATICRESPONSE_VERSION
ARG STATICRESPONSE_CHECKSUM

# BuildKit checks the archives against the pinned checksums before they reach
# the build, so a moved tag fails the build instead of changing the image.
ADD --checksum=${REWRITEBODY_CHECKSUM} \
    https://github.com/traefik/plugin-rewritebody/archive/refs/tags/${REWRITEBODY_VERSION}.tar.gz \
    /tmp/rewritebody.tar.gz
ADD --checksum=${STATICRESPONSE_CHECKSUM} \
    https://github.com/jdel/staticresponse/archive/refs/tags/${STATICRESPONSE_VERSION}.tar.gz \
    /tmp/staticresponse.tar.gz

COPY --from=traefik /usr/local/bin/traefik /traefik

# libcap is deliberately not pinned: it only provides setcap, runs at build time
# and leaves nothing in the final image, so a newer Alpine package cannot change
# what ships. The builder image itself is pinned by digest.
RUN set -ex; \
    apk add --no-cache libcap; \
    setcap 'cap_net_bind_service=ep' /traefik; \
    mkdir --parents /plugins-local/src/github.com/traefik/plugin-rewritebody; \
    tar --extract --gzip --directory /plugins-local/src/github.com/traefik/plugin-rewritebody --strip-components 1 --file /tmp/rewritebody.tar.gz; \
    mkdir --parents /plugins-local/src/github.com/jdel/staticresponse; \
    tar --extract --gzip --directory /plugins-local/src/github.com/jdel/staticresponse --strip-components 1 --file /tmp/staticresponse.tar.gz

FROM scratch
ARG BASE_DIGEST
ARG TRAEFIK_VERSION
ARG IMAGE_VERSION=3.7.14-scratch.0
ARG SOURCE_COMMIT=unknown

LABEL org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/traefik:v${TRAEFIK_VERSION}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.source="https://github.com/jochenseeber/traefik-image"

WORKDIR /
COPY --from=traefik /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=traefik /usr/share/zoneinfo /usr/share/zoneinfo/
COPY --from=builder --chown=0:0 --chmod=0755 /traefik /
COPY --from=builder --chown=0:0 --chmod=0755 /plugins-local /plugins-local
USER 1001:1001
EXPOSE 80
VOLUME ["/tmp"]
ENTRYPOINT ["/traefik"]
