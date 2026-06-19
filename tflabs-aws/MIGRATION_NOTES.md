# Azure to AWS Migration Notes

## Key Translation Mapping

### Azure → AWS Resource Mappings

| Azure | AWS | Notes |
|-------|-----|-------|
| Resource Group | AWS Account + Region tags | Implicit in AWS |
| Virtual Network (VNet) | VPC | Both /16 CIDR, same address space |
| Subnet | Subnet | Same CIDR blocks preserved (10.0.1.0/24, etc.) |
| Azure Bastion | EC2 bastion + Security Group | Traditional pattern vs. managed service |
| Network Security Group (NSG) | Security Group | Rules translated identically |
| Public IP (Standard SKU) | Elastic IP | Associated with bastion host |
| Network Interface | Network Interface | Private IP addresses preserved |
| Linux VM (Standard_B2ms) | EC2 t3.medium | Similar compute; AWS uses different sizing |
| Windows VM (Standard_B2s) | EC2 t3.small | Similar compute; no direct match |
| Storage Account (blob) | S3 (future) | Not provisioned; can add for logs |
| DevTest Lab shutdown schedule | EventBridge + Lambda (future) | Omitted in initial translation |

### Network Configuration

#### Azure Subnets
```
VNet: 10.0.0.0/16
- snet-app:     10.0.1.0/24  (app servers)
- snet-db:      10.0.2.0/24  (database)
- AzureBastionSubnet: 10.0.3.0/27 (Azure Bastion - managed)
```

#### AWS Subnets (Translated)
```
VPC: 10.0.0.0/16
- subnet-public-bastion: 10.0.3.0/24  (bastion EC2 in public subnet)
- subnet-app:            10.0.1.0/24  (app servers in private subnet)
- subnet-db:             10.0.2.0/24  (database in private subnet)
```

**Key Difference**: 
- Azure Bastion is a managed service that doesn't consume subnet resources; the /27 is just reserved.
- AWS bastion is a traditional EC2 in a /24 public subnet, which provides more control and flexibility.

### Security Groups vs. NSGs

Both translate directly, but note:
- **Azure NSGs**: Stateful by default; rules are unidirectional (inbound/outbound separate)
- **AWS Security Groups**: Stateful by default; inbound/egress rules work similarly
- **Ports and protocols**: Identical (SSH 22, RDP 3389, PostgreSQL 5432)

### IAM Roles & Permissions

**Added for AWS** (Azure didn't require):
- EC2 instances get IAM roles with:
  - `AmazonSSMManagedInstanceCore` (for Systems Manager Session Manager access)
  - `CloudWatchAgentServerPolicy` (for monitoring and logs)

This provides:
1. Alternative to bastion SSH (use `aws ssm start-session`)
2. CloudWatch integration for diagnostics

### Database Setup

#### Azure (cloud-init via CustomData)
```yaml
package_update: true
packages:
  - postgresql-14
runcmd:
  - systemctl enable postgresql
  - ... (PostgreSQL config)
```

#### AWS (user_data script)
```bash
#!/bin/bash
apt-get update
apt-get install -y postgresql-14
... (PostgreSQL config)
```

**Differences**:
- Azure uses YAML cloud-config format
- AWS uses shell script format
- Functionality is identical
- Both are base64-encoded and passed to instance at launch

### Instance Sizing Comparison

| Azure | vCPU | RAM | AWS | vCPU | RAM | Cost/hr |
|-------|------|-----|-----|------|-----|---------|
| Standard_B2ms | 2 | 8GB | t3.medium | 2 | 4GB | $0.0416 |
| Standard_B2s | 2 | 4GB | t3.small | 2 | 2GB | $0.0208 |
| - | - | - | t3.micro | 1 | 1GB | $0.0104 |

**Note**: AWS t3 instances are burstable (CPU credits); better for lab workloads with variable load.

### Outbound Internet Access

**Azure**: No explicit NAT; outbound is implicit through Azure infrastructure.

**AWS**: 
- Bastion: Uses Internet Gateway (in public subnet)
- App/DB: Use NAT Gateway (in public subnet) for outbound egress
- Cost: $0.045/hour + per-GB data transfer charges

This must be provisioned explicitly in AWS.

### Monitoring & Diagnostics

**Azure**:
- Boot diagnostics → Storage Account blob
- DevTest Lab shutdown schedules → Automatic 08:00 UTC shutdown

**AWS**:
- CloudWatch monitoring (enabled on all instances)
- Logs → CloudWatch Logs (can integrate with EC2 systems for boot logs)
- No auto-shutdown (omitted per requirements)

### Auto-Shutdown Feature

**Azure**: 
- DevTest Lab resource type with `azurerm_dev_test_global_vm_shutdown_schedule`
- Daily 08:00 UTC shutdown

**AWS Equivalent** (not implemented):
- EventBridge Scheduler + SSM Automation
- Triggers EC2 stop action daily at 08:00 UTC
- Cost savings but adds complexity

Can be added in future iteration if needed.

## Operational Differences

### Authentication
**Azure**: SSH keys or password authentication via Azure portal/Bastion

**AWS**: 
- EC2 Key Pairs (SSH)
- Systems Manager Session Manager (IAM-based, no keys needed)
- Windows: RDP with password (via User Data or Systems Manager)

### Cost Model
- **Azure**: Resource Group–level charges; billing by resource type/size
- **AWS**: Region-level consumption; hourly rates + data transfer

### Multi-AZ Considerations
Current deployment uses single AZ. For HA:
- Azure: Availability Sets (implicit in this lab)
- AWS: Could add second subnet in different AZ + Route 53 health checks

## Testing Checklist

- [ ] VPC created with correct CIDR (10.0.0.0/16)
- [ ] Three subnets created with correct CIDRs
- [ ] Internet Gateway attached to VPC
- [ ] NAT Gateway deployed in public subnet
- [ ] Route tables configured (public and private)
- [ ] Security groups created with correct rules
- [ ] Four EC2 instances launched (bastion, app, db, windows)
- [ ] Bastion has public IP and security group allows SSH from 0.0.0.0/0
- [ ] App/DB security groups restrict SSH to bastion only
- [ ] DB PostgreSQL responds on 10.0.2.10:5432
- [ ] App VM can SSH to DB VM via bastion jump
- [ ] Windows VM can RDP via bastion tunnel
- [ ] All instances reachable via Systems Manager Session Manager
- [ ] CloudWatch metrics visible for all instances

## Rollback / Cleanup

If deployment fails or needs to restart:
```bash
terraform destroy
```

This will remove all AWS resources. (Note: Elastic IPs may take a few seconds to release.)

## Future Enhancements

1. **S3 + CloudTrail** for audit logs (Azure Storage equivalent)
2. **EventBridge Scheduler** for auto-shutdown at 08:00 UTC
3. **VPC Flow Logs** for network monitoring
4. **RDS PostgreSQL** instead of EC2 PostgreSQL (managed database)
5. **Application Load Balancer** in front of app subnet
6. **Auto Scaling Group** for dynamic capacity
7. **Secrets Manager** for database credentials rotation
