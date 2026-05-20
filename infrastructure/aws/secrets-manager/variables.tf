variable "secrets-registries" {
    description = "References of secrets registries in AWS Secrets Manager"
    type        = list(object({
        name = string
    }))
}