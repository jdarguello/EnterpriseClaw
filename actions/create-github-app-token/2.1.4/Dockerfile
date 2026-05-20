FROM public.ecr.aws/docker/library/node:20-alpine
RUN apk add --no-cache curl ca-certificates &&\
    mkdir action-token && \
    curl -sSL -o action.zip \
    https://github.com/actions/create-github-app-token/archive/refs/tags/v2.1.4.tar.gz && \
    tar -xzf action.zip -C action-token --strip-components=1
WORKDIR /action-token
RUN npm ci --omit=dev
ENTRYPOINT ["node", "main.js"]