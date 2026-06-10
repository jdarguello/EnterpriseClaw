# GitOps Config Toolkit

This section contains all manifests and configuration to deploy EnterpriseClaw. GitOps definitions are sectioned in three parts:

1. `config`: contains all definitions and configurations for each kube-tool (e. g., Argo CD, Argo Events, etc).
2. `helm`: defines the installation process for each kube-tool. It is customized by linking these manifests through your private repo.
3. `templates`: builds the pipeline templates for task executions. 