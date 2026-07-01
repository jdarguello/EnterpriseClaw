# Build context: repo ROOT (podman build -f actions/enterpriseclaw/v0.1.0/Dockerfile .)
# The Dockerfile COPYs cli/ so the full Nushell module tree is present at runtime.
#
# Multi-arch: TARGETARCH is set by BuildKit/podman --platform.
# linux/amd64  → nu-0.112.2-x86_64-unknown-linux-gnu
# linux/arm64  → nu-0.112.2-aarch64-unknown-linux-gnu

FROM public.ecr.aws/docker/library/debian:bookworm-slim

ARG TARGETARCH
ARG NU_VERSION=0.112.2

# Install runtime deps: ca-certificates (TLS for Slack/broker/A2A HTTPS calls), curl (runtime http
# calls from nushell builtins), tar (unpacking the nushell tarball in the same layer).
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl tar && \
    rm -rf /var/lib/apt/lists/* && \
    # Resolve arch → nushell tarball name
    case "$TARGETARCH" in \
      amd64)  NU_ARCH=x86_64-unknown-linux-gnu ;; \
      arm64)  NU_ARCH=aarch64-unknown-linux-gnu ;; \
      *)      echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac && \
    NU_URL="https://github.com/nushell/nushell/releases/download/${NU_VERSION}/nu-${NU_VERSION}-${NU_ARCH}.tar.gz" && \
    curl -sSL "$NU_URL" -o /tmp/nu.tar.gz && \
    tar -xzf /tmp/nu.tar.gz -C /tmp && \
    install -m 0755 /tmp/nu-${NU_VERSION}-${NU_ARCH}/nu /usr/local/bin/nu && \
    rm -rf /tmp/nu.tar.gz /tmp/nu-${NU_VERSION}-${NU_ARCH}

# Copy the entire cli/ tree so all sourced modules resolve correctly.
# The entrypoint script (cli/enterpriseclaw) uses relative `source` paths resolved from its own
# directory, so we preserve the tree under /opt/enterpriseclaw/cli/.
COPY cli/ /opt/enterpriseclaw/cli/

# Make `enterpriseclaw` runnable as a bare command. We use a thin shell wrapper rather than a bare
# symlink because nushell resolves `source` paths relative to the script's directory at *parse
# time* using the path it was given — NOT the resolved symlink target. A wrapper that passes the
# absolute path to `nu` guarantees nushell sees the real location and resolves all relative
# `source` statements from /opt/enterpriseclaw/cli/ at build/parse time.
RUN chmod +x /opt/enterpriseclaw/cli/enterpriseclaw && \
    printf '%s\n' \
      '#!/bin/sh' \
      'exec nu /opt/enterpriseclaw/cli/enterpriseclaw "$@"' \
      > /usr/local/bin/enterpriseclaw && \
    chmod +x /usr/local/bin/enterpriseclaw

WORKDIR /opt/enterpriseclaw/cli

# Argo Workflow steps call: command: [enterpriseclaw], args: [main, slack, reply, ...]
ENTRYPOINT ["enterpriseclaw"]
