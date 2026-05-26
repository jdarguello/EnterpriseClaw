#Return IaC Outputs!
def --env "infra output" [
    --output-name: string               #Name of the 'output' to retrieve
    --cloud-provider:string             #Options: 'aws', 'azure' and 'gcp'
] {
    #1. cd to infra path
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)"

    #2. Capturar el valor
    let tofu_output = tofu output -json $output_name

    #3. Retornar al path original
    cd $current_directory

    #4. Retornar el valor
    return $tofu_output
}