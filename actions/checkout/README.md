# Git Checkout

La operación de _checkout_ en GitHub Actions se emplea para clonar un repositorio. Es uno de los actions comunitarios más robustos que permite clonar con diferentes ramas e implementar submodulos, entre muchas otras configuraciones.

## 1. Forma de uso

Para usar el _action_, se debe correr el contenedor con las variables de entorno respectivas. Por ejemplo:

```bash
docker run --rm --name example \
  -e GITHUB_REPOSITORY=grupobancolombia-innersource/DevEx_Controls \
  -e GITHUB_SERVER_URL=https://github.com \
  -e GITHUB_GRAPHQL_URL=https://api.github.com/graphql \
  -e GITHUB_WORKSPACE=/tmp \
  -e RUNNER_TEMP=/tmp \
  -e "INPUT_TOKEN=$(cat secrets/token.txt)" \
  -v "$PWD/result:/tmp" \
  git-checkout
```