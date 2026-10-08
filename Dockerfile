# AcreetionOS Horizon build container.
# Based on the same image as .github/workflows/build-iso.yml; every tool the
# build needs is installed by tools/container/setup-build-env.sh at image
# build time, so the host only needs a container runtime.
FROM archlinux:base-devel

COPY tools/container/setup-build-env.sh /usr/local/bin/setup-build-env.sh
COPY build-deps.txt /tmp/build-deps.txt
RUN chmod +x /usr/local/bin/setup-build-env.sh && \
    /usr/local/bin/setup-build-env.sh && \
    rm -f /tmp/build-deps.txt

WORKDIR /repo
