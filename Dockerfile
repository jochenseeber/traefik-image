ARG TRAEFIK_VERSION

FROM traefik:v${TRAEFIK_VERSION} AS traefik

FROM alpine:3.20.3 AS builder
COPY --from=traefik /usr/local/bin/traefik /traefik
RUN set -ex; \
    apk add --no-cache curl libcap; \
    setcap 'cap_net_bind_service=ep' /traefik; \
    mkdir --parents /plugins-local/src/github.com/traefik/plugin-rewritebody; \
    curl --silent --location --output /tmp/rewritebody.tar.gz https://github.com/traefik/plugin-rewritebody/archive/refs/tags/v0.3.1.tar.gz; \
    tar --extract --gzip --directory /plugins-local/src/github.com/traefik/plugin-rewritebody --strip-components 1 --file /tmp/rewritebody.tar.gz; \
    mkdir --parents /plugins-local/src/github.com/jdel/staticresponse; \
    curl --silent --location --output /tmp/staticresponse.tar.gz https://github.com/jdel/staticresponse/archive/refs/tags/v0.0.1.tar.gz; \
    tar --extract --gzip --directory /plugins-local/src/github.com/jdel/staticresponse --strip-components 1 --file /tmp/staticresponse.tar.gz;

FROM scratch
WORKDIR /
COPY --from=traefik /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=traefik /usr/share/zoneinfo /usr/share/
COPY --from=builder --chown=0:0 --chmod=0755 /traefik /
COPY --from=builder --chown=0:0 --chmod=0755 /plugins-local /plugins-local
USER 1001:1001
EXPOSE 80
VOLUME ["/tmp"]
ENTRYPOINT ["/traefik"]
