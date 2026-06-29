# teardown.nu — graceful GitOps teardown for `enterpriseclaw destroy`.
#
# THE HARD PROBLEM
# The AWS Load Balancer Controller (the shared ALB + the agentgateway NLBs) and the in-tree
# cloud-controller (the Istio Classic ELB) create load balancers PLUS their managed security
# groups OUTSIDE Terraform's knowledge. If `tofu destroy` runs while any of them still exist,
# the VPC / subnet / security-group deletes fail with `DependencyViolation` (the LBs hold ENIs
# in the subnets and their SGs reference the node SG), and the ACM certificate delete fails with
# `ResourceInUse` (the ALB's HTTPS listener still references it).
#
# THE OLD BUG
# The previous teardown deleted the `main` app-of-apps with cascade — which removed the
# alb-controller AT THE SAME TIME as the Ingress/Service resources it had to clean up. The
# controller frequently died before it finished deprovisioning the LBs, orphaning them (and the
# blind `sleep 120sec` could not fix that race). The agentgateway NLBs were never explicitly
# accounted for at all.
#
# THE FIX (this file)
#   1. Freeze Argo CD by scaling BOTH reconcilers (application + applicationset controllers) to 0,
#      so nothing re-creates / self-heals the resources we are about to delete — and, crucially, so
#      deleting them does NOT also tear down the alb-controller. The alb-controller /
#      cloud-controller / external-dns run in their own namespaces and keep working.
#   2. Delete every load-balancer-creating resource (alb-class Ingresses + every type=LoadBalancer
#      Service) while those controllers are still alive, so they cleanly deprovision the
#      ALB / NLBs / Classic-ELB and their managed security groups (external-dns drops the DNS).
#   3. POLL AWS until no k8s-managed load balancers / security groups remain in the cluster VPC
#      (replaces the blind sleep), with a best-effort force-clean fallback on timeout, before the
#      caller proceeds to `tofu destroy`.

def "main teardown gitops" [
    --gitops-agent:   string
    --cloud-provider = "aws"
    --cluster-name   = "enterpriseclaw"
] {
    if ($gitops_agent == "argocd") {
        argo-project teardown --cloud-provider=$cloud_provider --cluster-name=$cluster_name
    }
}

def "argo-project teardown" [
    --cloud-provider = "aws"
    --cluster-name   = "enterpriseclaw"
] {
    # 1. Freeze Argo CD so manual deletes stick and the controllers are NOT torn down yet.
    print "🧊 Freezing Argo CD reconcilers (scaling application + applicationset controllers to 0)…"
    try { kubectl -n argocd scale statefulset -l app.kubernetes.io/name=argocd-application-controller --replicas=0 }
    try { kubectl -n argocd scale deployment  -l app.kubernetes.io/name=argocd-applicationset-controller --replicas=0 }
    sleep 5sec

    # 2. Delete every AWS-load-balancer-creating resource while the controllers still run, so they
    #    deprovision the LBs + managed SGs cleanly (external-dns, policy=sync, drops the DNS):
    print "🌐 Deleting LB-backing resources (Ingresses + Gateways + LoadBalancer Services)…"
    #    a) alb-class Ingresses -> the shared ALB.
    try { kubectl delete ingress --all --all-namespaces --wait=false }
    #    b) Gateway-API Gateways -> the agentgateway NLBs. Delete the Gateway (the SOURCE) BEFORE its
    #       derived type=LoadBalancer Service: the agentgateway controller is NOT Argo CD and is still
    #       running, so deleting only the Service makes it immediately re-create the Service AND a
    #       brand-new NLB (observed: the drain wedges on regenerated LBs that never go away).
    try { kubectl delete gateways.gateway.networking.k8s.io --all --all-namespaces --wait=false }
    #    c) Any remaining standalone type=LoadBalancer Services (e.g. the Istio ingress Classic ELB).
    for svc in (lb-services) {
        print $"   • deleting LoadBalancer Service ($svc.namespace)/($svc.name)"
        try { kubectl delete svc $svc.name -n $svc.namespace --wait=false }
    }

    # 3. Wait for AWS to actually release the load balancers + their managed SGs in the cluster VPC.
    if ($cloud_provider == "aws") {
        wait-for-lb-drain --cluster-name=$"($cluster_name)-cluster"
    }
}

# Every type=LoadBalancer Service across all namespaces, as {namespace,name} records.
def "lb-services" [] {
    kubectl get svc --all-namespaces -o json
    | from json | get items
    | where {|s| ($s.spec.type? | default "") == "LoadBalancer" }
    | each {|s| { namespace: $s.metadata.namespace, name: $s.metadata.name } }
}

# Poll until no k8s-managed load balancers / security groups remain in the cluster VPC.
# Replaces the old blind `sleep 120sec`, which raced the controller teardown.
def "wait-for-lb-drain" [
    --cluster-name: string                  # full EKS cluster name, e.g. enterpriseclaw-cluster
    --timeout    = 600                       # max seconds to wait before force-cleaning
    --interval   = 15
] {
    let region = ($env.region? | default "us-east-1")
    let vpc = (aws eks describe-cluster --name $cluster_name --region $region
        --query 'cluster.resourcesVpcConfig.vpcId' --output text | str trim)
    print $"⏳ Waiting for load balancers + managed SGs to drain from VPC ($vpc) …"

    mut waited = 0
    loop {
        let elbv2   = (aws elbv2 describe-load-balancers --region $region --output json
            | from json | get LoadBalancers | where VpcId == $vpc | length)
        let classic = (aws elb describe-load-balancers --region $region --output json
            | from json | get LoadBalancerDescriptions | where VPCId == $vpc | length)
        let k8s_sgs = (aws ec2 describe-security-groups --region $region
            --filters $"Name=vpc-id,Values=($vpc)" --output json
            | from json | get SecurityGroups | where {|s| $s.GroupName | str starts-with "k8s-" } | length)

        print $"   elbv2=($elbv2)  classic=($classic)  k8s-SGs=($k8s_sgs)  \(waited ($waited)s)"
        if ($elbv2 == 0 and $classic == 0 and $k8s_sgs == 0) {
            print "✅ All load balancers + managed security groups released."
            return
        }
        if ($waited >= $timeout) {
            print $"⚠️  Timed out after ($timeout)s — force-cleaning remaining LBs/SGs before tofu destroy."
            force-clean-lbs --vpc=$vpc --region=$region
            return
        }
        sleep ($interval * 1sec)
        $waited = ($waited + $interval)
    }
}

# Best-effort fallback: directly delete leftover load balancers + their k8s-managed SGs so
# `tofu destroy` is not blocked by DependencyViolation. Only runs if the graceful drain times out.
def "force-clean-lbs" [ --vpc: string --region: string ] {
    print "🧹 Force-deleting leftover load balancers…"
    let albs = (aws elbv2 describe-load-balancers --region $region --output json
        | from json | get LoadBalancers | where VpcId == $vpc | get LoadBalancerArn)
    for arn in $albs { try { aws elbv2 delete-load-balancer --region $region --load-balancer-arn $arn } }
    let clbs = (aws elb describe-load-balancers --region $region --output json
        | from json | get LoadBalancerDescriptions | where VPCId == $vpc | get LoadBalancerName)
    for name in $clbs { try { aws elb delete-load-balancer --region $region --load-balancer-name $name } }

    print "   waiting 45s for ENIs to release…"
    sleep 45sec
    print "🧹 Force-deleting leftover k8s-managed security groups…"
    let sgs = (aws ec2 describe-security-groups --region $region --filters $"Name=vpc-id,Values=($vpc)"
        --output json | from json | get SecurityGroups | where {|s| $s.GroupName | str starts-with "k8s-" })
    for sg in $sgs { try { aws ec2 delete-security-group --region $region --group-id $sg.GroupId } }
    print "   force-clean pass complete (any residual items will be retried by tofu destroy)."
}
