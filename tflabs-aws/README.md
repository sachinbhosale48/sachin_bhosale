# AWS Lab Infrastructure – Terraform Translation

## Overview
This is an AWS equivalent of the Azure lab infrastructure (`../tflabs`). It uses Terraform to provision a complete lab environment with a traditional bastion host pattern for secure access to private subnets.

## Architecture Decisions

### 1. Bastion Pattern: Traditional EC2
- **Choice**: Public-subnet EC2 bastion host (vs. AWS Systems Manager Session Manager)
- **Why**: Direct SSH/RDP gateway providing explicit control and audit trail
- **Access**: Bastion has public IP; app/db subnets are private with NAT Gateway egress

### 2. Auto-Shutdown Automation
- **Choice**: Omitted for AWS (Azure had daily 08:00 UTC shutdown via DevTest Lab schedules)
- **Reason**: Can be added later via EventBridge + Lambda if needed

## Infrastructure Components

### Network Topology
```
VPC: 10.0.0.0/16
├── Public Subnet (Bastion): 10.0.3.0/24
│   └── NAT Gateway (outbound access for private subnets)
├── App Subnet (Private): 10.0.1.0/24
│   ├── Linux app VM (10.0.1.10)
│   └── Windows VM (10.0.1.20)
└── DB Subnet (Private): 10.0.2.0/24
    └── Linux DB VM with PostgreSQL (10.0.2.10)
```

### Instances
| Name | Type | OS | Subnet | IP | Size | Role |
|------|------|-----|--------|-----|------|------|
| vm-bastion | EC2 | Ubuntu 22.04 | Public | 10.0.3.10 | t3.micro | SSH gateway |
| vm-app | EC2 | Ubuntu 22.04 | App | 10.0.1.10 | t3.medium | Application |
| vm-db | EC2 | Ubuntu 22.04 | DB | 10.0.2.10 | t3.medium | PostgreSQL database |
| vm-win | EC2 | Windows Server 2022 | App | 10.0.1.20 | t3.small | Windows workload |

### Security Groups
- **bastion**: SSH (22) from anywhere (0.0.0.0/0)
- **app**: SSH (22) + RDP (3389) from bastion only
- **db**: PostgreSQL (5432) from app subnet, SSH (22) from bastion

### IAM
- EC2 instances have roles for:
  - AWS Systems Manager (SSM) access via Session Manager (alternative to SSH)
  - CloudWatch monitoring and logging

### Storage & Diagnostics
- No explicit storage account (AWS equivalent would be S3; omitted for minimal setup)
- CloudWatch monitoring enabled on all instances

### PostgreSQL Database
- User: `labuser` (password: `Lab@2024!`)
- Database: `labdb`
- Listens on: 10.0.2.10:5432
- Accepts connections from app subnet (10.0.1.0/24) via host-based authentication

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Core VPC, subnets, route tables, security groups, EC2 instances, IAM roles |
| `variables.tf` | Input variables (participant_name, aws_region, admin credentials) |
| `outputs.tf` | VPC ID, IP addresses, subnet IDs for reference |
| `terraform.tfvars` | Default values for variables |
| `user_data_db.sh` | Cloud-init script for PostgreSQL setup on db instance |

## Deployment Steps

### Prerequisites
1. AWS credentials configured (`aws configure` or environment variables)
2. Terraform >= 1.0

### Deploy
```bash
cd tflabs-aws
terraform init
terraform plan
terraform apply
```

### Access Pattern
1. **Bastion Host** (from anywhere):
   ```bash
   ssh -i <key> ec2-user@<BASTION_PUBLIC_IP>
   ```

2. **App VM** (via bastion):
   ```bash
   ssh -i <key> -J ec2-user@<BASTION_PUBLIC_IP> labadmin@10.0.1.10
   ```

3. **DB VM** (via bastion):
   ```bash
   ssh -i <key> -J ec2-user@<BASTION_PUBLIC_IP> labadmin@10.0.2.10
   ```

4. **Windows VM** (RDP via bastion jump):
   - Use SSH tunnel: `ssh -i <key> -L 3389:10.0.1.20:3389 ec2-user@<BASTION_PUBLIC_IP>`
   - Connect via localhost:3389 with RDP client

### Alternative: AWS Systems Manager Session Manager
All instances have SSM permissions; you can use:
```bash
aws ssm start-session --target <instance-id> --region <aws-region>
```

## Outputs
After `terraform apply`, retrieve:
```bash
terraform output bastion_public_ip    # Public IP of bastion
terraform output vm_app_private_ip    # App VM private IP
terraform output vm_db_private_ip     # DB VM private IP
terraform output vm_win_private_ip    # Windows VM private IP
```

## Cost Notes
- **t3.micro** (bastion): ~$0.0104/hour
- **t3.medium** (app, db): ~$0.0416/hour each
- **t3.small** (windows): ~$0.0208/hour
- **NAT Gateway**: ~$0.045/hour + data transfer charges
- **Elastic IPs**: $0.005/hour if unassociated

## Cleanup
```bash
terraform destroy
```

## Differences from Azure Version

| Aspect | Azure | AWS |
|--------|-------|-----|
| Access pattern | Azure Bastion (managed) | Traditional EC2 bastion |
| Network | VNet + NSGs | VPC + Security Groups |
| Private egress | N/A (Azure handles) | NAT Gateway |
| Auto-shutdown | DevTest Lab schedules (08:00 UTC) | Omitted |
| Compute sizing | Standard_B2ms / Standard_B2s | t3.medium / t3.small |
| Diagnostics | Storage account | CloudWatch |
| Database | PostgreSQL via cloud-init | PostgreSQL via user_data |

## Future Enhancements
- Add EventBridge + Lambda for scheduled shutdowns
- Implement CloudWatch alarms and SNS notifications
- Add backup/snapshot policies for DB volume
- Configure VPC Flow Logs for network monitoring
- Add Application Load Balancer for app tier scaling
