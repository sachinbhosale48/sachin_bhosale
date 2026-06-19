# Azure Lab Environment - Post-Deployment Readiness Checklist
**Resource Group:** rg-ailab-sachinb  
**Region:** eastus  
**Deployment Date:** 2026-06-16  
**Validator Role:** Compute Operations Engineer  

---

## SECURITY CHECKS (Priority 1)

### ✓ Check 1: NSG - App Subnet Inbound Rules Validation
**Category:** SECURITY  
**Check:** Verify that SSH (port 22) and RDP (port 3389) are ONLY accessible from Azure Bastion subnet (10.0.3.0/27)

```bash
az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-app \
  --query "[?direction=='Inbound'].{Name:name, Protocol:protocol, Port:destinationPortRange, Source:sourceAddressPrefix, Access:access}" \
  --output table
```

**Expected:**
```
Name       Protocol  Port   Source        Access
---------  --------  -----  -----------   ------
AllowSSH   Tcp       22     10.0.3.0/27   Allow
AllowRDP   Tcp       3389   10.0.3.0/27   Allow
```
(Verify NO rules allow ports 22/3389 from 0.0.0.0/0 or Internet)

**Tower Note:** Critical compute security posture baseline. Prevents direct SSH/RDP access; all admin traffic must flow through Bastion for audit logging, MFA enforcement, and session recording. Validates network perimeter isolation.

---

### ✓ Check 2: NSG - DB Subnet Inbound Rules Validation
**Category:** SECURITY  
**Check:** Verify PostgreSQL port 5432 is accessible ONLY from App subnet (10.0.1.0/24), NOT from Internet

```bash
az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --query "[?direction=='Inbound' && destinationPortRange=='5432'].{Name:name, Source:sourceAddressPrefix, Access:access}" \
  --output table
```

**Expected:**
```
Name                Source        Access
------------------  -----------   ------
AllowPostgres       10.0.1.0/24   Allow
```
(Verify port 5432 NOT accessible from 0.0.0.0/0, Internet, or any external range)

**Tower Note:** Database network isolation is foundational for compute security. Ensures PostgreSQL is reachable only from application tier via private subnet routing. Prevents lateral movement from compromised VMs outside the trusted app subnet.

---

### ✓ Check 3: VM Network Interfaces - No Public IPs Assigned
**Category:** SECURITY  
**Check:** Confirm all three VMs (vm-app, vm-db, vm-win) have NO public IP addresses

```bash
az vm list-ip-addresses \
  --resource-group rg-ailab-sachinb \
  --query "[].{VMName:virtualMachine.name, PublicIP:virtualIPAddresses[0].publicIPAddresses[0].ipAddress}" \
  --output table
```

**Expected:**
```
VMName   PublicIP
-------  --------
vm-app   None
vm-db    None
vm-win   None
```
(All VMs must return `None` for PublicIP; Bastion public IP is acceptable and expected)

**Tower Note:** Eliminates direct inbound attack surface on production VMs. Bastion-only access model ensures all traffic (SSH/RDP) is mediated, logged, and subject to conditional access policies. Prevents exposure to automated vulnerability scanners.

---

### ✓ Check 4: Azure Bastion Provisioning State & SKU Verification
**Category:** SECURITY  
**Check:** Confirm Bastion host is fully deployed, running, and configured with correct SKU (Basic)

```bash
az network bastion show \
  --resource-group rg-ailab-sachinb \
  --name bastion-ailab \
  --query "{Name:name, ProvisioningState:provisioningState, SKU:sku}" \
  --output table
```

**Expected:**
```
Name           ProvisioningState  SKU
-------------  ----------------  -----
bastion-ailab  Succeeded          Basic
```

**Tower Note:** Bastion is the single authorised admin access path. Provisioning state "Succeeded" confirms infrastructure readiness. SKU=Basic is suitable for lab environment; monitors must scale to "Standard" for production with native MFA.

---

### ✓ Check 5: Storage Account - Soft Delete & Container Delete Retention Enabled
**Category:** SECURITY / BACKUP  
**Check:** Verify blob soft-delete (7 days) and container delete retention (7 days) are active

```bash
az storage account blob-service-properties show \
  --account-name stailabsachinb \
  --resource-group rg-ailab-sachinb \
  --query "{DeleteRetentionPolicy:delete_retention_policy, ContainerDeleteRetentionPolicy:container_delete_retention_policy}" \
  --output json
```

**Expected:**
```json
{
  "DeleteRetentionPolicy": {
    "days": 7,
    "enabled": true
  },
  "ContainerDeleteRetentionPolicy": {
    "days": 7,
    "enabled": true
  }
}
```

**Tower Note:** Ransomware and accidental deletion protection for boot diagnostics artifacts. 7-day retention allows recovery window for compute incidents before permanent loss. Essential compliance baseline for compute environments processing sensitive workloads.

---

## CONNECTIVITY CHECKS (Priority 2)

### ✓ Check 6: VM-App SSH Connectivity via Bastion
**Category:** CONNECTIVITY  
**Check:** Verify SSH connectivity to vm-app (10.0.1.10) through Azure Bastion

```bash
# List available Bastion sessions (confirm host is accessible)
az network bastion tunnel \
  --resource-group rg-ailab-sachinb \
  --name bastion-ailab \
  --target-resource-id /subscriptions/{subscriptionId}/resourceGroups/rg-ailab-sachinb/providers/Microsoft.Compute/virtualMachines/vm-app
```

OR (Alternative via Azure CLI native Bastion SSH):

```bash
# Create Bastion tunnel to vm-app on port 22
az network bastion tunnel \
  --resource-group rg-ailab-sachinb \
  --name bastion-ailab \
  --target-resource-id /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-ailab-sachinb/providers/Microsoft.Compute/virtualMachines/vm-app \
  --resource-port 22 \
  --port 8080
```

Then in separate terminal:
```bash
ssh -p 8080 labadmin@localhost
```

**Expected:**
```
labadmin@vm-app:~$ hostname
vm-app
```

**Tower Note:** Validates compute-to-Bastion trust path and SSH service health on production app tier VM. Confirms labadmin credential sync from Terraform. Baseline connectivity test before application deployment.

---

### ✓ Check 7: VM-DB SSH Connectivity & PostgreSQL Network Interface
**Category:** CONNECTIVITY  
**Check:** SSH to vm-db and verify PostgreSQL is listening on correct interface (10.0.2.10)

```bash
# SSH to vm-db via Bastion tunnel (use similar tunnel command as Check 6)
ssh -p 8080 labadmin@localhost

# Once connected to vm-db, verify PostgreSQL listening interface:
sudo -u postgres psql -c "SHOW listen_addresses;"
```

**Expected:**
```
 listen_addresses
-----------------
 10.0.2.10
```

**Tower Note:** PostgreSQL must bind to private IP only, not 0.0.0.0. Validates cloud-init execution (hardcoded listen_addresses). Confirms database tier isolation and prevents accidental exposure via misconfigured firewall rules.

---

### ✓ Check 8: VM-App to VM-DB Internal Connectivity (PostgreSQL Port Test)
**Category:** CONNECTIVITY  
**Check:** From vm-app, verify port 5432 is reachable on vm-db (10.0.2.10)

```bash
# SSH into vm-app via Bastion, then:
nc -zv 10.0.2.10 5432
```

**Expected:**
```
Connection to 10.0.2.10 5432 port [tcp/postgresql] succeeded!
```

**Tower Note:** Validates east-west connectivity for application-to-database communication. NSG rules allow 10.0.1.0/24 (app subnet) to reach 5432 on db subnet. Prerequisite for application deployment and integration testing.

---

### ✓ Check 9: VM-Win RDP Connectivity via Bastion
**Category:** CONNECTIVITY  
**Check:** Verify RDP (port 3389) connectivity to vm-win (10.0.1.20) through Bastion

```bash
# Use Azure Bastion RDP tunnel (if using native Bastion RDP feature via portal)
# Or verify RDP port is reachable from vm-app:
ssh -p 8080 labadmin@localhost  # via vm-app Bastion tunnel

# Inside vm-app:
nc -zv 10.0.1.20 3389
```

**Expected:**
```
Connection to 10.0.1.20 3389 port [tcp/ms-wbt-server] succeeded!
```

**Tower Note:** Windows compute node readiness check. Validates hypervisor integration and WinRM service initialization. RDP should accept connections post-boot; high CPU/memory during Sysprep indicates normal startup sequence in multi-tier environment.

---

### ✓ Check 10: VNET & Subnet Configuration
**Category:** CONNECTIVITY  
**Check:** Verify virtual network address space, subnet configuration, and no routing conflicts

```bash
az network vnet show \
  --resource-group rg-ailab-sachinb \
  --name vnet-ailab \
  --query "{AddressSpace:addressSpace.addressPrefixes, Subnets:subnets[].{Name:name, Prefix:addressPrefix}}" \
  --output table
```

**Expected:**
```
AddressSpace: ['10.0.0.0/16']

Subnets:
Name                  Prefix
--------------------  -----------
snet-app              10.0.1.0/24
snet-db               10.0.2.0/24
AzureBastionSubnet    10.0.3.0/27
```

**Tower Note:** Validates network blueprint implementation. Confirms no overlapping CIDR ranges, subnet isolation by tier (app/db/bastion), and routing plane readiness. No address conflicts = no broadcast storms or split-brain routing on compute nodes.

---

## MONITORING & DIAGNOSTICS CHECKS (Priority 3)

### ✓ Check 11: Boot Diagnostics Storage Configuration
**Category:** MONITORING  
**Check:** Confirm all VMs have boot diagnostics enabled and pointing to correct storage account

```bash
az vm boot-diagnostics get-boot-log \
  --resource-group rg-ailab-sachinb \
  --name vm-app \
  --query "consoleLogBlobUri" \
  --output tsv
```

**Expected:**
```
https://stailabsachinb.blob.core.windows.net/bootdiagnostics-vm-app/vm-app.vmdiagnostics.serialconsole
```

(Repeat for vm-db and vm-win. Confirm blob storage exists and is accessible)

**Tower Note:** Mandatory compute diagnostics baseline. Boot logs captured before Azure Guest Agent initialization; critical for troubleshooting VMs that fail to reach RDP/SSH. Absence of boot diagnostics = debugging blind on infrastructure issues.

---

### ✓ Check 12: Resource Tags for Cost & Asset Tracking
**Category:** MONITORING  
**Check:** Verify all resources carry consistent tags (owner=sachinb)

```bash
az resource list \
  --resource-group rg-ailab-sachinb \
  --query "[].{Name:name, Type:type, Tags:tags}" \
  --output table
```

**Expected:**
```
All resources return: "owner": "sachinb" in Tags
```

**Tower Note:** Cost allocation and compliance visibility. Tagging enables showback reporting, automated cost analysis, and governance audits. Compute environments without asset tags = blind spot for FinOps and security compliance reviews.

---

### ✓ Check 13: Auto-Shutdown Schedules Active
**Category:** MONITORING / PERFORMANCE  
**Check:** Verify daily auto-shutdown schedules are enabled for all VMs (0800 UTC)

```bash
az vm auto-shutdown show \
  --resource-group rg-ailab-sachinb \
  --ids /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-ailab-sachinb/providers/Microsoft.Compute/virtualMachines/vm-app \
  --query "{Enabled:enabled, DailyRecurrenceTime:dailyRecurrenceTime, Timezone:timeZone}" \
  --output table
```

**Expected:**
```
Enabled             DailyRecurrenceTime  Timezone
------------------  -----------------   --------
True                0800                 UTC
```

(Repeat for vm-db and vm-win)

**Tower Note:** Cost optimization control. Prevents runaway compute billing for lab environments. Auto-shutdown at 0800 UTC daily is suitable for development; production requires conditional auto-shutdown (e.g., weekdays only) tied to cost center schedules.

---

## PERFORMANCE & CAPACITY CHECKS (Priority 4)

### ✓ Check 14: VM SKU & CPU/Memory Allocation Verification
**Category:** PERFORMANCE  
**Check:** Confirm VMs are deployed with correct compute SKUs (app/db = Standard_B2ms, win = Standard_B2s)

```bash
az vm show \
  --resource-group rg-ailab-sachinb \
  --name vm-app \
  --query "hardwareProfile.vmSize" \
  --output tsv
```

**Expected:**
```
Standard_B2ms
```

(Repeat for vm-db → Standard_B2ms; vm-win → Standard_B2s)

**Tower Note:** Capacity and burstable compute validation. B-series VMs provide 2 vCPU base + burstable to 4 vCPU (time-limited). Suitable for lab workloads with variable load; production apps would require D-series (guaranteed, non-burstable). Confirms infrastructure matches performance SLA.

---

### ✓ Check 15: OS Disk Size & Storage Type Validation
**Category:** PERFORMANCE / BACKUP  
**Check:** Verify disk sizing and storage tier (all Standard_LRS)

```bash
az vm show \
  --resource-group rg-ailab-sachinb \
  --name vm-app \
  --query "storageProfile.osDisk.{DiskSizeGB:diskSizeGb, StorageAccountType:managedDisk.storageAccountType}" \
  --output table
```

**Expected:**
```
DiskSizeGB  StorageAccountType
----------  ------------------
30          Standard_LRS
```

(Repeat for vm-db: 30 GB Standard_LRS; vm-win: 128 GB Standard_LRS)

**Tower Note:** Confirms persistent storage allocation. Standard_LRS suitable for non-critical lab; production requires Premium_LRS or Ultra_SSD for latency-sensitive apps. Disk size adequate for OS + temp space; monitor free space post-deployment (critical at <20% threshold).

---

## COMPLIANCE & BASELINE CHECKS (Priority 5)

### ✓ Check 16: PostgreSQL User & Database Creation (vm-db)
**Category:** SECURITY / BACKUP  
**Check:** Verify cloud-init created labuser account and labdb database

```bash
# SSH to vm-db via Bastion, then:
sudo -u postgres psql -l | grep labdb
```

**Expected:**
```
 labdb     | labuser | UTF8     | en_US.UTF-8 | en_US.UTF-8 |
```

Verify labuser can connect:
```bash
sudo -u postgres psql -c "\du" | grep labuser
```

**Expected:**
```
 labuser | Superuser, Create role, Create DB, Replication | {}
```

**Tower Note:** Validates infrastructure-as-code reproducibility. Cloud-init execution confirms VM initialization pipeline works; labdb + labuser ready for application onboarding. Baseline data layer readiness.

---

### ✓ Check 17: PostgreSQL Connection Limits & Listen Configuration
**Category:** PERFORMANCE  
**Check:** Verify PostgreSQL max_connections set to 20 (per cloud-init config)

```bash
# SSH to vm-db via Bastion:
sudo -u postgres psql -c "SHOW max_connections;"
```

**Expected:**
```
 max_connections
----------------
 20
```

**Tower Note:** Prevents resource exhaustion on small B2ms instance. Cloud-init sets conservative max_connections=20 for lab safety. Production would scale based on workload; monitor pg_stat_activity for connection pool saturation.

---

### ✓ Check 18: Windows Server 2022 Initial Configuration State
**Category:** MONITORING  
**Check:** Verify Windows VM OS version and initial Windows Update state (no pending reboots blocking RDP)

```bash
# SSH to vm-app, then RDP to vm-win via local tunnel, or via PowerShell from vm-app:
# If able to RDP, open PowerShell and run:
Get-ComputerInfo | Select-Object WindowsInstallationType, WindowsVersion, WindowsProductName
```

**Expected:**
```
WindowsInstallationType  : Server
WindowsVersion           : 21H2
WindowsProductName       : Windows Server 2022 Datacenter
```

Verify no pending Windows Update reboot:
```powershell
Get-PendingReboot  # Check if updates require restart
```

**Expected:**
```
No reboot pending
```

**Tower Note:** Windows compute readiness check. OS version confirms correct SKU provisioning. Pending reboots block RDP sessions and can cause transient connectivity failures during automation. Baseline must be clean post-boot.

---

### ✓ Check 19: Resource Group Location & Consistency
**Category:** MONITORING  
**Check:** Confirm all resources in resource group are co-located in specified region (eastus)

```bash
az resource list \
  --resource-group rg-ailab-sachinb \
  --query "[].location" | sort | uniq -c
```

**Expected:**
```
4 eastus
```
(All resources report eastus; no geo-redundancy or cross-region replication in basic configuration)

**Tower Note:** Latency and compliance baseline. Co-location eliminates cross-region egress charges and minimizes RTO/RPO. Validates region selection matches compute SLA and data residency requirements.

---

### ✓ Check 20: Terraform State File Integrity (Local Validation)
**Category:** MONITORING / BACKUP  
**Check:** Verify Terraform state file exists and matches deployed infrastructure

```powershell
# On management workstation (where terraform apply was run):
cd c:\Users\labuser\Documents\training\tflabs
terraform state list
```

**Expected:**
```
azurerm_bastion_host.lab
azurerm_dev_test_global_vm_shutdown_schedule.app
azurerm_dev_test_global_vm_shutdown_schedule.db
azurerm_dev_test_global_vm_shutdown_schedule.win
azurerm_linux_virtual_machine.app
azurerm_linux_virtual_machine.db
azurerm_network_interface.app
azurerm_network_interface.db
azurerm_network_interface.win
azurerm_network_security_group.app
azurerm_network_security_group.db
azurerm_public_ip.bastion
azurerm_resource_group.lab
azurerm_storage_account.lab
azurerm_subnet.app
azurerm_subnet.bastion
azurerm_subnet.db
azurerm_subnet_network_security_group_association.app
azurerm_subnet_network_security_group_association.db
azurerm_virtual_network.lab
azurerm_windows_virtual_machine.win
```

Then verify no drift:
```powershell
terraform plan -out=/tmp/tfplan
# Should show "No changes" or minimal changes
```

**Tower Note:** IaC state is single source of truth for compute infrastructure. Drift detection prevents configuration creep and ensures reproducibility. Regular state validation prevents orphaned resources and compliance violations.

---

## SUMMARY VALIDATION

| Category | Count | Status |
|----------|-------|--------|
| SECURITY | 5 | ✓ |
| CONNECTIVITY | 5 | ✓ |
| MONITORING | 4 | ✓ |
| PERFORMANCE | 3 | ✓ |
| BACKUP | 3 | ✓ |
| **TOTAL** | **20** | ✓ |

---

## Quick Pass/Fail Decision Matrix

| Tier | Item | FAIL Condition (Do NOT Proceed to Prod) |
|------|------|----------------------------------------|
| **CRITICAL** | Check 1 (NSG SSH/RDP rules) | Port 22/3389 accessible from 0.0.0.0/0 |
| **CRITICAL** | Check 3 (No Public IPs) | Any VM has public IP assigned |
| **CRITICAL** | Check 5 (Soft Delete) | Soft-delete retention < 7 days or disabled |
| **CRITICAL** | Check 6-9 (Bastion Connectivity) | Cannot SSH/RDP to any VM |
| **CRITICAL** | Check 14 (SKU Size) | VM not running Standard_B2ms/B2s |
| **HIGH** | Check 2 (DB NSG PostgreSQL) | Port 5432 accessible from non-app subnets |
| **HIGH** | Check 4 (Bastion Provisioning) | ProvisioningState ≠ Succeeded |
| **HIGH** | Check 16 (PostgreSQL DB/User) | labdb or labuser missing |
| **MEDIUM** | Check 11 (Boot Diagnostics) | Boot logs not accessible |
| **MEDIUM** | Check 13 (Auto-Shutdown) | Auto-shutdown disabled |

---

## Checkpoint Sign-Off

- [ ] All 20 checklist items completed and documented
- [ ] Zero CRITICAL failures observed
- [ ] NSG rules match Terraform design specification
- [ ] Bastion access path validated end-to-end
- [ ] All VMs responding to SSH/RDP via Bastion
- [ ] PostgreSQL 14 operational, accepting connections from app tier
- [ ] Boot diagnostics functional for all VMs
- [ ] Resource tags applied consistently
- [ ] Terraform state integrity confirmed
- [ ] **READY FOR APPLICATION DEPLOYMENT** ✓

**Validator Name:** ___________________ **Date:** ___________________ **Time:** ___________________
