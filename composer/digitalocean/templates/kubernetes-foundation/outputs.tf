output "cluster_id" {
  description = "Kubernetes cluster ID"
  value       = module.kubernetes.id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.kubernetes.endpoint
}

output "cluster_version" {
  description = "Kubernetes cluster version"
  value       = module.kubernetes.version
}

output "kubeconfig_raw" {
  description = "Raw kubeconfig for cluster access"
  value       = module.kubernetes.kubeconfig_raw
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID used by the cluster"
  value       = local.vpc_uuid_effective
}

output "project_id" {
  description = "DigitalOcean project ID"
  value       = module.project.project_id
}

output "bastion_ip_address" {
  description = "Stable bastion Reserved IP address, when the bastion is enabled"
  value       = try(module.bastion[0].ip_address, null)
}

output "bastion_user" {
  description = "Bastion SSH user, when the bastion is enabled"
  value       = try(module.bastion[0].user, null)
}
