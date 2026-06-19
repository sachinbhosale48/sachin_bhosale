terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    owner = "sachinb"
  }
}

# VPC
resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(
    local.common_tags,
    { Name = "vpc-ailab-${var.participant_name}" }
  )
}

# Internet Gateway
resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags = merge(
    local.common_tags,
    { Name = "igw-ailab-${var.participant_name}" }
  )
}

# Public Subnet (for bastion)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = merge(
    local.common_tags,
    { Name = "subnet-public-bastion" }
  )
}

# App Subnet (private)
resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = merge(
    local.common_tags,
    { Name = "subnet-app" }
  )
}

# DB Subnet (private)
resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = merge(
    local.common_tags,
    { Name = "subnet-db" }
  )
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.lab.id
  }
  tags = merge(
    local.common_tags,
    { Name = "rt-public" }
  )
}

# Public Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway EIP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = merge(
    local.common_tags,
    { Name = "eip-nat" }
  )
  depends_on = [aws_internet_gateway.lab]
}

# NAT Gateway (in public subnet)
resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = merge(
    local.common_tags,
    { Name = "nat-ailab" }
  )
  depends_on = [aws_internet_gateway.lab]
}

# Private Route Table (for app and db subnets)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }
  tags = merge(
    local.common_tags,
    { Name = "rt-private" }
  )
}

# Private Route Table Associations
resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

# Security Group for Bastion
resource "aws_security_group" "bastion" {
  name        = "bastion-ailab"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.lab.id
  tags = merge(
    local.common_tags,
    { Name = "sg-bastion" }
  )

  # SSH access from anywhere (for lab purposes)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress to all
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for App Subnet
resource "aws_security_group" "app" {
  name        = "app-ailab"
  description = "Security group for app servers"
  vpc_id      = aws_vpc.lab.id
  tags = merge(
    local.common_tags,
    { Name = "sg-app" }
  )

  # SSH from bastion only
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # RDP from bastion only
  ingress {
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Egress to all
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for DB Subnet
resource "aws_security_group" "db" {
  name        = "db-ailab"
  description = "Security group for database servers"
  vpc_id      = aws_vpc.lab.id
  tags = merge(
    local.common_tags,
    { Name = "sg-db" }
  )

  # PostgreSQL from app subnet
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.app.cidr_block]
  }

  # SSH from bastion only
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Egress to all
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Network Interfaces
resource "aws_network_interface" "bastion" {
  subnet_id           = aws_subnet.public.id
  security_groups     = [aws_security_group.bastion.id]
  private_ips         = ["10.0.3.10"]
  tags = merge(
    local.common_tags,
    { Name = "eni-bastion" }
  )
}

resource "aws_network_interface" "app" {
  subnet_id           = aws_subnet.app.id
  security_groups     = [aws_security_group.app.id]
  private_ips         = ["10.0.1.10"]
  tags = merge(
    local.common_tags,
    { Name = "eni-app" }
  )
}

resource "aws_network_interface" "db" {
  subnet_id           = aws_subnet.db.id
  security_groups     = [aws_security_group.db.id]
  private_ips         = ["10.0.2.10"]
  tags = merge(
    local.common_tags,
    { Name = "eni-db" }
  )
}

resource "aws_network_interface" "win" {
  subnet_id           = aws_subnet.app.id
  security_groups     = [aws_security_group.app.id]
  private_ips         = ["10.0.1.20"]
  tags = merge(
    local.common_tags,
    { Name = "eni-win" }
  )
}

# Elastic IP for Bastion
resource "aws_eip" "bastion" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.bastion.id
  network_interface_id      = aws_network_interface.bastion.id
  associate_with_private_ip = "10.0.3.10"
  tags = merge(
    local.common_tags,
    { Name = "eip-bastion" }
  )
  depends_on = [aws_internet_gateway.lab]
}

# IAM Role for EC2 instances (for SSM and CloudWatch)
resource "aws_iam_role" "ec2_role" {
  name = "ec2-ailab-${var.participant_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  tags = local.common_tags
}

# IAM Policy for SSM
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Policy for CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-profile-ailab-${var.participant_name}"
  role = aws_iam_role.ec2_role.name
}

# Data source for Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Data source for Windows AMI
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["801119661308"] # Amazon Windows AMI
  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Core-*"]
  }
}

# Bastion EC2 Instance (Linux)
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  network_interface {
    network_interface_id = aws_network_interface.bastion.id
    device_index         = 0
  }
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  tags = merge(
    local.common_tags,
    { Name = "vm-bastion" }
  )
  monitoring = true
}

# App EC2 Instance (Linux)
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.medium"
  network_interface {
    network_interface_id = aws_network_interface.app.id
    device_index         = 0
  }
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  tags = merge(
    local.common_tags,
    { Name = "vm-app" }
  )
  monitoring = true
}

# DB EC2 Instance (Linux with PostgreSQL)
resource "aws_instance" "db" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.medium"
  network_interface {
    network_interface_id = aws_network_interface.db.id
    device_index         = 0
  }
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  user_data            = base64encode(file("${path.module}/user_data_db.sh"))
  tags = merge(
    local.common_tags,
    { Name = "vm-db" }
  )
  monitoring = true
}

# Windows EC2 Instance
resource "aws_instance" "win" {
  ami                 = data.aws_ami.windows.id
  instance_type       = "t3.small"
  network_interface {
    network_interface_id = aws_network_interface.win.id
    device_index         = 0
  }
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  tags = merge(
    local.common_tags,
    { Name = "vm-win" }
  )
  monitoring = true
}
