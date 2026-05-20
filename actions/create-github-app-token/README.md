# Git Token

Conteneriza el GitHub Action de [`create-github-app-token`](https://github.com/actions/create-github-app-token) para ser implementado como `CronWorkflow` en ArgoCD. El uso de este _action_ busca refrescar el token de GitHub dentro del clúster.

## 1. Forma de uso

Para usar el _action_, se debe correr el contenedor con las variables de entorno respectivas. Por ejemplo:

```bash
docker run --name example \
	-e GITHUB_REPOSITORY=grupobancolombia-innersource/DevEx_Controls \
	-e GITHUB_OWNER=grupobancolombia-innersource \
	-e GITHUB_REPOSITORY_OWNER=grupobancolombia-innersource \
	-e 'GITHUB_SERVER_URL=https://github.com' \
	-e 'GITHUB_GRAPHQL_URL=https://api.github.com/graphql' \
	-e INPUT_SKIP-TOKEN-REVOKE=FALSE \
	-e "INPUT_APP-ID=$(cat creds/app-id.txt)" \
	-e "INPUT_PRIVATE-KEY=$(cat creds/private-key.pem)" \
	-e 'INPUT_GITHUB-API-URL=https://api.github.com' \
	git-token
```

## 2. Rotación del private-key

Este action requiere de un `app-id`, un `installation-id` y un `private-key` para funcionar correctamente. De los tres, es este último el que debe rotarse cada cierto tiempo (máximo de 90 días). Para rotarlo, se debe generar un nuevo `private-key` desde la GitHub App. Se ubica el artefacto en una ubicación de interés y se ejecuta:

```bash
jq -Rs \
	--arg url "https://github.com/grupobancolombia-innersource" \
	--arg app_id "<app-id>" \
	--arg installation_id "<installation-id>" \
	'{url: $url, githubAppID: $app_id, githubAppInstallationID: $installation_id, githubAppPrivateKey: .}' \
	inner-key.pem > payload.json
```

Esto creará un `payload.json` que usaremos con el contenido de interés para actualizar el secreto. Ahora, ejecutamos:

```bash
aws secretsmanager put-secret-value \
  --secret-id <arn:aws:secretsmanager:us-east-1:<account_id>:secret:<secret-id>> \
  --secret-string file://payload.json
```