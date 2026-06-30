module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.cluster_name}-cluster"
  kubernetes_version = var.cluster_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  endpoint_public_access = true
  enable_irsa            = true

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.irsa_ebs_csi.arn
    }
  }

  eks_managed_node_groups = {
    public = {
      name           = "frontend"
      instance_types = var.node_instance_types

      min_size     = 1
      max_size     = 3
      desired_size = 1

      subnet_ids = var.public_subnet_ids

      labels = {
        role = "frontend"
      }

      taints = {
        frontend = {
          key    = "role"
          value  = "frontend"
          effect = "NO_SCHEDULE"
        }
      }
    }

    private = {
      name           = "backend"
      instance_types = var.node_instance_types

      min_size     = 1
      max_size     = 8
      desired_size = 6

      subnet_ids = var.private_subnet_ids

      labels = {
        role = "backend"
      }
    }
  }

  node_security_group_additional_rules = {
    ingress_istio_webhook = {
      description = "Cluster API to Istiod Webhook"
      protocol    = "tcp"
      from_port   = 15017
      to_port     = 15017
      type        = "ingress"

      source_cluster_security_group = true
    }

    # The Dapr sidecar-injector serves its mutating admission webhook on pod
    # port 4000. EKS only auto-allows the control plane to nodes on a fixed set
    # of webhook ports (443/4443/6443/8443/9443/10250/10251) plus the Istio rule
    # above; 4000 is not among them, so the API server's webhook call times out
    # and (failurePolicy: Ignore) pods come up with NO daprd sidecar, silently.
    # Allow the cluster (control-plane) security group to reach nodes on 4000.
    ingress_dapr_injector_webhook = {
      description = "Cluster API to Dapr sidecar-injector Webhook"
      protocol    = "tcp"
      from_port   = 4000
      to_port     = 4000
      type        = "ingress"

      source_cluster_security_group = true
    }
  }

  tags = {
    Project = var.project
  }
}

# IRSA role for the EBS CSI driver controller (ebs-csi-controller-sa in kube-system).
# Matches the repo's established IRSA-via-OIDC pattern (iam-role-for-service-accounts,
# bound to the cluster OIDC provider) used by the ALB, external-dns and secrets roles.
# attach_ebs_csi_policy attaches the AWS-managed AmazonEBSCSIDriverPolicy.
module "irsa_ebs_csi" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name                  = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ebs_csi_oidc = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

# Least-privilege IAM policy for the agentgateway data-plane proxy to call Bedrock.
# Scoped to InvokeModel / InvokeModelWithResponseStream ONLY, on the Claude Haiku 4.5
# cross-region (system-defined) inference profile plus the underlying foundation-model
# ARNs it routes to (region-wildcard, gated by bedrock:InferenceProfileArn) — the AWS-
# documented shape for invoking via an inference profile. No bedrock:* / no Resource:*.
module "bedrock_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "${var.cluster_name}-agentgateway-bedrock-policy"
  path        = "/"
  description = "Least-privilege Bedrock InvokeModel for the agentgateway LLM-gateway proxy (Claude Haiku 4.5 inference profile)"

  policy = file("${path.module}/policies/bedrock_invoke.json")

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

# IRSA role for the agentgateway data-plane proxy ServiceAccount (kagent:agentic-gw).
# This SA is the §2.2 production LLM-gateway identity rail — only agentgateway holds
# bedrock:InvokeModel. Matches the repo's IRSA-via-OIDC pattern (iam-role-for-service-
# accounts bound to the cluster OIDC provider), same as irsa_ebs_csi above.
module "irsa_bedrock" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.cluster_name}-agentgateway-bedrock"

  oidc_providers = {
    bedrock_oidc = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kagent:agentic-gw"]
    }
  }

  policies = {
    policy = module.bedrock_policy.arn
  }

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}
