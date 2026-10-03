output "team_roles" {
  description = "Roles granted to each team member by this configuration."
  value       = var.team_members
}

output "enabled_apis" {
  description = "APIs enabled by this configuration."
  value       = sort(tolist(var.enabled_apis))
}
