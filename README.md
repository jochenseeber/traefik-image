# Traefik Image

This repository contains the Dockerfile to create a [Traefik](https://traefik.io/traefik/) image that allows Traefik to bind to service (low) ports without being started as root.

The image is derived from the official [Traefik image](https://hub.docker.com/_/traefik) and sets `cap_net_bind_service=ep` on the Traefik binary.

Also, the following useful plugins get added to the image:

* [plugin-rewritebody](https://github.com/traefik/plugin-rewritebody)
* [staticresponse](https://github.com/jdel/staticresponse)

## Running

See [this file](deployment.yml) for an example how to deploy on Kubernetes.

## Building

Run `./build version [repo]` to create the image, e.g. `./build 3.3.2`.
