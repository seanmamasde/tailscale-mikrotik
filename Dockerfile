# Copyright (c) 2020 Fluent Networks Inc & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

############################################################################
#
# WARNING: Tailscale is not yet officially supported in Docker,
# Kubernetes, etc.
#
# It might work, but we don't regularly test it, and it's not as polished as
# our currently supported platforms. This is provided for people who know
# how Tailscale works and what they're doing.
#
# Our tracking bug for officially support container use cases is:
#    https://github.com/tailscale/tailscale/issues/504
#
# Also, see the various bugs tagged "containers":
#    https://github.com/tailscale/tailscale/labels/containers
#
############################################################################

# BuildKit auto args
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG BASE_IMAGE="debian:bookworm-slim"

FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build-env

WORKDIR /go/src/tailscale

COPY tailscale/go.mod tailscale/go.sum ./
RUN go mod download

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pre-build some stuff before the following COPY line invalidates the Docker cache.
RUN go install \
    github.com/aws/aws-sdk-go-v2/aws \
    github.com/aws/aws-sdk-go-v2/config \
    gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
    gvisor.dev/gvisor/pkg/tcpip/stack \
    golang.org/x/crypto/ssh \
    golang.org/x/crypto/acme \
    github.com/coder/websocket \
    github.com/mdlayher/netlink

COPY tailscale/. .

# see build.sh
ARG VERSION_LONG=""
ENV VERSION_LONG=$VERSION_LONG
ARG VERSION_SHORT=""
ENV VERSION_SHORT=$VERSION_SHORT
ARG VERSION_GIT_HASH=""
ENV VERSION_GIT_HASH=$VERSION_GIT_HASH
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG GOARM_OVERRIDE=""

RUN set -eux; \
    GOARM_ARG=""; \
    if [ "$TARGETARCH" = "arm" ]; then \
      if [ -n "${GOARM_OVERRIDE}" ]; then \
        GOARM_ARG="${GOARM_OVERRIDE}"; \
      elif [ -n "${TARGETVARIANT:-}" ]; then \
        GOARM_ARG="${TARGETVARIANT#v}"; \
      fi; \
    fi; \
    CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="$TARGETARCH" GOARM="$GOARM_ARG" \
    go install -ldflags="-w -s\
      -X tailscale.com/version.Long=$VERSION_LONG \
      -X tailscale.com/version.Short=$VERSION_SHORT \
      -X tailscale.com/version.GitCommit=$VERSION_GIT_HASH" \
      -v ./cmd/tailscale ./cmd/tailscaled

#
# Build a target-rootfs overlay WITHOUT executing target-arch binaries:
# - For Mikrotik ARMv5 we use Debian "armel" packages (older ARM port).
#
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS rootfs
ARG TARGETARCH

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates openssh-client dpkg xz-utils; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb; \
    mkdir -p /out

RUN set -eux; \
    if [ "$TARGETARCH" = "arm" ]; then \
      dpkg --add-architecture armel; \
      ARCH=armel; \
    else \
      ARCH=amd64; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends --download-only \
      ca-certificates:${ARCH} \
      iptables:${ARCH} \
      iproute2:${ARCH} \
      openssh-server:${ARCH} \
      openssh-sftp-server:${ARCH} \
      openssh-client:${ARCH} \
      curl:${ARCH} \
      jq:${ARCH} \
      procps:${ARCH}; \
    for deb in /var/cache/apt/archives/*.deb; do \
      case "$deb" in \
        *_"${ARCH}".deb|*_all.deb) dpkg-deb -x "$deb" /out ;; \
      esac; \
    done; \
    mkdir -p /out/etc; \
    touch /out/etc/passwd /out/etc/group; \
    grep -q '^sshd:' /out/etc/group || echo 'sshd:x:74:' >> /out/etc/group; \
    grep -q '^sshd:' /out/etc/passwd || echo 'sshd:x:74:74::/run/sshd:/bin/false' >> /out/etc/passwd; \
    mkdir -p /out/run/sshd; \
    for d in bin sbin lib lib64; do \
      if [ -d "/out/$d" ] && [ ! -L "/out/$d" ]; then \
        mkdir -p "/out/usr/$d"; \
        cp -a "/out/$d/." "/out/usr/$d/"; \
        rm -rf "/out/$d"; \
      fi; \
    done; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb; \
    mkdir -p /out/usr/local/bin; \
    ln -sf /usr/sbin/iptables-legacy /out/usr/local/bin/iptables || true; \
    ln -sf /usr/sbin/ip6tables-legacy /out/usr/local/bin/ip6tables || true; \
    # Ensure a usable CA bundle (postinst would normally generate it)
    mkdir -p /out/etc/ssl/certs; \
    cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt; \
    # Pre-generate SSH host keys (keys are arch-independent data)
    mkdir -p /out/etc/ssh; \
    ssh-keygen -f /out/etc/ssh/ssh_host_rsa_key -N '' -t rsa; \
    ssh-keygen -f /out/etc/ssh/ssh_host_ed25519_key -N '' -t ed25519

# Runtime base image is supplied by build arg:
# - amd64: debian:bookworm-slim
# - mikrotik v5: arm32v5/debian:bookworm-slim  (linux/arm/v5)
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/seanmamasde/tailscale-mikrotik"

COPY --from=rootfs /out/ /

COPY --from=build-env /go/bin/* /usr/local/bin/
COPY sshd_config /etc/ssh/
COPY tailscale.sh /usr/local/bin/

EXPOSE 22
CMD ["/usr/local/bin/tailscale.sh"]
