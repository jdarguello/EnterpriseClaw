# EnterpriseClaw CLI

This CLI was built to automate and simplify EnterpriseClaw's bootstrap and configuration in your company's infraestructure. It was built to setup your infrastructure on any of these cloud providers: AWS, Azure or GCP. For it to work correctly, you must have enough permissions to configure your cloud's network, secret management configuration and creation of resources, such as K8s clusters (e. g., EKS, AKS or GKE) and cloud servers (e. g., EC2, Azure VMs or CE), among others. 

## CLI user

If you intend to configure everything using the CLI, you should...

## Developer/Contributor

If you intend to locally configure and test the CLI, whether to include new features or to contribute to the project, you should create a `.env` file in this path (`.gitignore` file has been previously created to avoid credentials leakage). **Be careful**, as this file could contain your credentials for cloud provider access and repository registry. Below, you'll find an example of which specific credentials and variables are required in this file:

```bash
export COMPANY_NAME="your-company"
export domain_name="yourdomain.com"

#Generals
export region="us-east-1"

#Secrets registries
export github_app_registry="github-creds"
export github_webhook_registry="webhook-creds"

#GitHub
export GITHUB_APP_CLIENT_ID="bBbBaAAAaa"
export GITHUB_APP_CLIENT_SECRET="zzzXXXYYY"

#Config Repo
export CONFIG_REPO="EnterpriseClaw-Sandbox"
export ORG_NAME="jdarguello"
export BRANCH_NAME="main"

export GIT_USER="your-user"
export GIT_USER_EMAIL="youruser@gmail.com"

#GitHub Token
export GH_TOKEN="ghp_xxxyyyzz"

#--------------------------------AWS-PROVIDER--------------------------------------------

#AWS-creds 
#export AWS_ROLE="<aws-role>"
export AWS_ACCESS_KEY_ID="xxXyyYzzZ"
export AWS_SECRET_ACCESS_KEY="www-xxx.yyy/aaaa"
#export AWS_SESSION_TOKEN="<session-token>"


#-----------------------------------GitOps---------------------------------------------

export argocd_version="8.6.3"
```

