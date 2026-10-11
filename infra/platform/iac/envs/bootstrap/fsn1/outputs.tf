output "state_backend_policy" {
  description = "Non-sensitive policy record for the remote state bucket."
  value       = local.policy
}

output "bootstrap_state_key" {
  value = local.policy.bootstrap_state_key
}

output "staging_state_key" {
  value = local.policy.staging_state_key
}

output "encryption_at_rest" {
  value = local.policy.encryption_at_rest
}

output "locking" {
  value = local.policy.lock
}
