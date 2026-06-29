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
      max_size     = 5
      desired_size = 4

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
