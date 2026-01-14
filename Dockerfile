ARG SUITE=trixie
FROM debian:${SUITE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    build-essential \
    ca-certificates \
    curl \
    debhelper \
    devscripts \
    diffutils \
    gnupg \
    lintian \
    patch \
    perl \
    sed \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
