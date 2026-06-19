variable "participant_name" {
  description = "Your participant name (lowercase, no spaces)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "admin_username" {
  description = "Admin username for EC2 instances"
  type        = string
  default     = "labadmin"
}

variable "admin_password" {
  description = "Admin password for Windows instances"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "PostgreSQL labuser password"
  type        = string
  sensitive   = true
  default     = "Lab@2024!"
}
