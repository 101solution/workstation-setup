output "resource_group_name" {
  value = azurerm_resource_group.test.name
}

output "vm_name" {
  value = azurerm_windows_virtual_machine.test.name
}

output "rdp_address" {
  value = azurerm_public_ip.test.ip_address
}

output "admin_username" {
  value = azurerm_windows_virtual_machine.test.admin_username
}

output "fresh_snapshot_id" {
  description = "Available when the post-provisioning snapshot has finished."
  value       = azurerm_snapshot.fresh.id
}

output "os_disk_id" {
  value = data.azurerm_managed_disk.os.id
}
