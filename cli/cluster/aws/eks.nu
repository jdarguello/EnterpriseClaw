def --env "eks connect" [
    --region:           string
    --cluster-name:     string
] {
    #Conectar al clúster de eks
    aws eks update-kubeconfig --region $region --name $cluster_name
}