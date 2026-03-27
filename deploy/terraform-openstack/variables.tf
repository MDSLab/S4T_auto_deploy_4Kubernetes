variable "auth_url" {
  description = "OpenStack Identity endpoint"
  type        = string
}

variable "tenant_name" {
  description = "OpenStack project name"
  type        = string
}

variable "user_name" {
  description = "OpenStack username"
  type        = string
}

variable "password" {
  description = "OpenStack password"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "OpenStack region"
  type        = string
  default     = "RegionOne"
}

variable "instance_name" {
  description = "VM name"
  type        = string
  default     = "s4t-deploy-vm"
}

variable "image_name" {
  description = "OpenStack image name"
  type        = string
}

variable "flavor_name" {
  description = "OpenStack flavor name"
  type        = string
}

variable "network_name" {
  description = "OpenStack network name"
  type        = string
}

variable "key_pair" {
  description = "OpenStack SSH key pair"
  type        = string
}

variable "security_groups" {
  description = "Security groups for the VM"
  type        = list(string)
  default     = ["default"]
}
