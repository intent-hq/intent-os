# Ubuntu 24.04 with what tests/sway-apps.sh needs, as on the CI runner.
FROM ubuntu:24.04
COPY packages.txt /tmp/packages.txt
RUN apt-get update -q && \
    xargs -a /tmp/packages.txt apt-get install -yq --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*
