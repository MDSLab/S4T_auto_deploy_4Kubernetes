output "instance_id" {
  description = "Created VM ID"
  value       = openstack_compute_instance_v2.s4t_vm.id
}

output "instance_name" {
  description = "Created VM name"
  value       = openstack_compute_instance_v2.s4t_vm.name
}

output "instance_ip" {
  description = "First IPv4 address"
  value       = try(openstack_compute_instance_v2.s4t_vm.access_ip_v4, null)
}
