FROM public.ecr.aws/docker/library/node:24.11.0-alpine3.22
RUN apk add --no-cache git openssh curl ca-certificates tar &&\
    mkdir action-checkout && \
    curl -sSL -o action.zip \
    https://github.com/actions/checkout/archive/refs/tags/v5.0.0.tar.gz && \
    tar -xzf action.zip -C action-checkout --strip-components=1
WORKDIR /action-checkout
RUN npm ci --omit=dev
RUN printf '%s\n' '#!/bin/sh' \
  'set -e' \
  'WS="${GITHUB_WORKSPACE:-/workspace}"' \
  'mkdir -p "$WS"' \
  'cd "$WS"' \
  'git init >/dev/null 2>&1 || true' \
  'exec node /action-checkout/dist/index.js' > /entrypoint.sh \
  && chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]