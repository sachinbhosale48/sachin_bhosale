output "vpc_id" {
  value = aws_vpc.lab.id
}

output "bastion_public_ip" {
  value = aws_eip.bastion.public_ip
}

output "bastion_private_ip" {
  value = aws_network_interface.bastion.private_ip
}

output "vm_app_private_ip" {
  value = aws_network_interface.app.private_ip
}

output "vm_db_private_ip" {
  value = aws_network_interface.db.private_ip
}

output "vm_win_private_ip" {
  value = aws_network_interface.win.private_ip
}

output "app_subnet_id" {
  value = aws_subnet.app.id
}

output "db_subnet_id" {
  value = aws_subnet.db.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}
