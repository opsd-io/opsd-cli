variable "digitalocean_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "scenario-kubernetes-foundation"
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}

variable "kubernetes_version" {
  description = "Kubernetes version slug or latest"
  type        = string
  default     = "latest"
}

variable "cluster_tags" {
  description = "Kubernetes cluster tags"
  type        = set(string)
  default     = ["opsd", "kubernetes", "scenario"]
}

variable "auto_upgrade" {
  description = "Enable automatic Kubernetes version upgrades"
  type        = bool
  default     = true
}

variable "surge_upgrade" {
  description = "Enable surge upgrades for node pools"
  type        = bool
  default     = true
}

variable "ha" {
  description = "Enable high availability control plane"
  type        = bool
  default     = false
}

variable "create_vpc" {
  description = "Create dedicated VPC for this scenario"
  type        = bool
  default     = true
}

variable "vpc_uuid" {
  description = "Existing VPC UUID when create_vpc = false"
  type        = string
  default     = null

  validation {
    condition     = var.create_vpc ? true : (var.vpc_uuid != null && trimspace(var.vpc_uuid) != "")
    error_message = "vpc_uuid must be set when create_vpc = false."
  }
}

variable "vpc_name" {
  description = "VPC name"
  type        = string
  default     = "scenario-kubernetes-foundation-vpc"
}

variable "vpc_description" {
  description = "VPC description"
  type        = string
  default     = "Scenario kubernetes-foundation VPC managed by OPSd"
}

variable "vpc_ip_range" {
  description = "Optional VPC CIDR range"
  type        = string
  default     = null
}

variable "node_pool_name" {
  description = "Default node pool name"
  type        = string
  default     = "default"
}

variable "node_size" {
  description = "Default node pool size"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_count" {
  description = "Node count when autoscaling is disabled"
  type        = number
  default     = 1
}

variable "node_auto_scale" {
  description = "Enable node autoscaling"
  type        = bool
  default     = false
}

variable "node_min_nodes" {
  description = "Minimum nodes when autoscaling is enabled"
  type        = number
  default     = 1
}

variable "node_max_nodes" {
  description = "Maximum nodes when autoscaling is enabled"
  type        = number
  default     = 3
}

variable "node_tags" {
  description = "Node tags"
  type        = set(string)
  default     = []
}

variable "node_labels" {
  description = "Node labels"
  type        = map(string)
  default     = {}
}

variable "maintenance_day" {
  description = "Optional maintenance day"
  type        = string
  default     = null
}

variable "maintenance_start_time" {
  description = "Optional maintenance start time (UTC, HH:MM)"
  type        = string
  default     = null
}

variable "maintenance_duration" {
  description = "Optional maintenance duration in hours"
  type        = string
  default     = null
}

variable "project_name" {
  description = "DigitalOcean project name"
  type        = string
  default     = "scenario-kubernetes-foundation"
}

variable "project_description" {
  description = "DigitalOcean project description"
  type        = string
  default     = "Scenario kubernetes-foundation managed by OPSd"
}

variable "project_purpose" {
  description = "DigitalOcean project purpose"
  type        = string
  default     = "Service or API"
}

variable "project_environment" {
  description = "DigitalOcean project environment"
  type        = string
  default     = "Development"
}
