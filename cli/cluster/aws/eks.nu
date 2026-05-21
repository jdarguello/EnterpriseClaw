def --env "eks connect" [
    --region
    --cluster-name
] {
    #Conectar al clúster de eks
    aws eks update-kubeconfig --region $region --name $cluster_name
}