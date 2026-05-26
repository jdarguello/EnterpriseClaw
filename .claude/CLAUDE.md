# 1. Introduction

We're building the EnterpriseClaw project! Which will help its users to build their own AI Assistant within a corporate environment. It is designed with security principles at its core to allow it to work in heavily regulated enterprises and its based on [OpenClaw](https://openclaw.ai/)'s AI Assistant. The assistant can receive orders from its users through any corporate chat platform and their company's IDP (_Internal Developer Platforms_).

The project has three main sections:
1. A CLI that executes in the terminal using `enterpriseclaw` bash command. Its the core of the project and contains main commands to set it up and execute agents in the cloud.
2. An IaC section for multi-cloud that setups the infrastructure of the project.
3. A GitOps config toolkit that automates the project setup in the corporate's infrastructure.

## 1.1. CLI

The CLI is a single executable called enterpriseclaw, written in Nushell and managed through a Devbox environment. Its job is to go from zero to a fully running AI assistant platform on Kubernetes with a handful of commands.

Based on Nushell and built on Devbox to provisions everything the development envirnoment might need, like nushell, opentofu, kubectl, helm, argo, awscli, gh.

## 1.2. IaC

Runs OpenTofu to create the VPC, K8s cluster, DNS zones, image registries, Blob storage, and Secrets Manager entries. It reads user's environment (region, company name, domain, GitHub App credentials) from .env and generates the tfvars automatically so they never touch a Terraform variable file by hand.

## 1.3. GitOps Toolkit

Authenticates to the git-provider, clones user's GitOps config repo, and patches the Kubernetes manifests with the live infra outputs (ALB controller role ARN, certificate ARN, hosted zone IDs) so ArgoCD can apply them cleanly on first boot.

