FROM node:20-alpine
RUN apk add --no-cache curl ca-certificates &&\
    mkdir action-token && \
    curl -sSL -o action.zip \
    https://github.com/SonarSource/sonarqube-scan-action/archive/refs/tags/v6.0.0.tar.gz && \
    tar -xzf action.zip -C action-token --strip-components=1
WORKDIR /action-token
RUN npm ci --omit=dev
ENTRYPOINT ["node", "dist/index.js"]
