variable "domain_name" {
    description = "Domain name where the apps will be accessed"
    type        = string
}

variable "subdomains" {
    description = "Subdomain names where the apps will be accessed"
    type        = list(object({
        name    = string
        url     = string
    }))
}