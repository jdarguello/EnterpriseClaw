#Return IaC Outputs!
def --env "infra output" [
    --output-name: string               #Name of the 'output' to retrieve
    --cloud-provider:string             #Options: 'aws', 'azure' and 'gcp'
] {
    #1. cd to infra path
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)"

    #2. Capture values
    let tofu_output = tofu output -json $output_name

    #3. Returns to original path
    cd $current_directory

    #4. Returns output
    return $tofu_output
}