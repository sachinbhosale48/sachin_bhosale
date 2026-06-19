output "web_vm_public_ip" {
  value = azurerm_public_ip.web.ip_address
}

output "monitor_vm_public_ip" {
  value = azurerm_public_ip.monitor.ip_address
}

output "web_vm_private_ip" {
  value = azurerm_network_interface.web.private_ip_address
}

output "monitor_vm_private_ip" {
  value = azurerm_network_interface.monitor.private_ip_address
}

output "resource_group" {
  value = azurerm_resource_group.capstone.name
}
