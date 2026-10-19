# Build environment for the Scrappy worker autoinstall ISO.
# No --privileged needed: xorriso edits the ISO image directly, no loop mounts.
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg xorriso python3 python3-yaml shellcheck whois \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
