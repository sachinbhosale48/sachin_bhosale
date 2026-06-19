# Azure Lab Environment - Network Readiness Checklist  
**Network Engineer Validation Reference**  
**Resource Group:** rg-ailab-sachinb  
**Region:** eastus  
**Deployment Date:** 2026-06-16  
**Validator Role:** Network Operations Engineer

---

## NETWORK TOPOLOGY & ARCHITECTURE (Priority 1)

### ✓ Check 1: VNet Address Space & Subnet Segmentation Validation
**Category:** CONNECTIVITY / SECURITY  
**Check:** Verify virtual network CIDR block (10.0.0.0/16) and subnet isolation by tier

```bash
az network vnet show \
  --resource-group rg-ailab-sachinb \
  --name vnet-ailab \
  --query "{Name:name, AddressSpace:addressSpace.addressPrefixes, Subnets:subnets[].{Name:name, Prefix:addressPrefix, NSG:networkSecurityGroup.id}}" \
  --output json
```

**Expected:**
```json
{
  "Name": "vnet-ailab",
  "AddressSpace": ["10.0.0.0/16"],
  "Subnets": [
    {
      "Name": "snet-app",
      "Prefix": "10.0.1.0/24",
      "NSG": "/subscriptions/.../resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkSecurityGroups/nsg-app"
    },
    {
      "Name": "snet-db",
      "Prefix": "10.0.2.0/24",
      "NSG": "/subscriptions/.../resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkSecurityGroups/nsg-db"
    },
    {
      "Name": "AzureBastionSubnet",
      "Prefix": "10.0.3.0/27",
      "NSG": null
    }
  ]
}
```

**Tower Note:** **CRITICAL for network engineer**: Validates hierarchical subnet design implementing three-tier architecture (App/DB/Bastion) with non-overlapping CIDR ranges. 10.0.3.0/27 is Azure-mandated for Bastion. Absence of NSG on Bastion subnet is correct (Bastion requires public inbound). Confirms address space planning prevents routing conflicts and broadcast domain isolation. RFC 1918 private addressing ensures no internet routable leakage.

---

### ✓ Check 2: NSG Association to Subnets (Scope Validation)
**Category:** SECURITY  
**Check:** Confirm NSGs are correctly associated at subnet level (not just NIC level) for centralized policy

```bash
az network vnet subnet show \
  --resource-group rg-ailab-sachinb \
  --vnet-name vnet-ailab \
  --name snet-app \
  --query "networkSecurityGroup.id" \
  --output tsv

az network vnet subnet show \
  --resource-group rg-ailab-sachinb \
  --vnet-name vnet-ailab \
  --name snet-db \
  --query "networkSecurityGroup.id" \
  --output tsv
```

**Expected:**
```
/subscriptions/.../providers/Microsoft.Network/networkSecurityGroups/nsg-app
/subscriptions/.../providers/Microsoft.Network/networkSecurityGroups/nsg-db
```

**Tower Note:** Subnet-level NSG association is network architecture best practice—provides default-deny posture for all traffic originating in subnet. NIC-level NSGs (if present) allow per-host exceptions. Verifies policy scope prevents accidental rule bypass via rule collision.

---

## NETWORK SECURITY GROUP RULES (Priority 1 - CRITICAL)

### ✓ Check 3: App Subnet NSG Inbound Rules - Bastion Access Path Validation
**Category:** SECURITY  
**Check:** Verify SSH (port 22) and RDP (port 3389) only allow from Bastion subnet (10.0.3.0/27), NO internet access

```bash
az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-app \
  --query "[?direction=='Inbound'] | sort_by(@, &priority) | [].{Priority:priority, Name:name, Protocol:protocol, DestPort:destinationPortRange, Source:sourceAddressPrefix, Action:access}" \
  --output table
```

**Expected:**
```
Priority  Name     Protocol  DestPort  Source       Action
--------  -------  --------  --------  -----------  ------
100       AllowSSH  Tcp       22        10.0.3.0/27  Allow
110       AllowRDP  Tcp       3389      10.0.3.0/27  Allow
```

**FAIL Condition (STOP deployment):**
- Port 22 or 3389 accessible from 0.0.0.0/0 (Internet)
- Port 22 or 3389 accessible from any range outside 10.0.3.0/27
- Rules missing entirely (defaults to implicit deny, which is actually OK)

**Tower Note:** **CRITICAL - Network perimeter defense**: SSH/RDP are primary lateral movement vectors. Restricting to Bastion subnet (10.0.3.0/27 = 32 IPs maximum) creates network "choke point" for admin traffic. Bastion acts as proxy, forcing all interactive access through centralized audit point. Rule priority (100, 110) indicates first-match evaluation—no override rules after. Validates zero-trust implicit deny + explicit allow principle. If rules allow 0.0.0.0/0, environment is directly exposed to internet scanning/brute-force attacks.

---

### ✓ Check 4: Database Subnet NSG Rules - App-to-DB Isolation
**Category:** SECURITY  
**Check:** Verify PostgreSQL port 5432 accessible ONLY from App subnet (10.0.1.0/24), NOT from Internet or Bastion

```bash
az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --query "[?direction=='Inbound'] | sort_by(@, &priority) | [].{Priority:priority, Name:name, Protocol:protocol, DestPort:destinationPortRange, Source:sourceAddressPrefix, Action:access}" \
  --output table
```

**Expected:**
```
Priority  Name            Protocol  DestPort  Source       Action
--------  --------------  --------  --------  -----------  ------
100       AllowPostgres   Tcp       5432      10.0.1.0/24  Allow
```

**FAIL Condition (STOP deployment):**
- Port 5432 accessible from 0.0.0.0/0
- Port 5432 accessible from Bastion subnet (10.0.3.0/27)
- Port 5432 accessible from any non-app subnet

**Tower Note:** **CRITICAL - East-West network segmentation**: PostgreSQL should ONLY be reachable from application tier (10.0.1.0/24). Prevents:
  - Bastion users from directly querying database (no DBAs, only app-mediated access)
  - Lateral movement if app VM compromised (attacker cannot directly reach DB)
  - Data exfiltration by privileged network admins accessing Bastion
  Validates application-database trust boundary. Port 5432 from app subnet only ensures data flow follows intended application logic.

---

### ✓ Check 5: NSG Default Rules - Implicit Deny Outbound Validation
**Category:** SECURITY  
**Check:** Verify NSGs enforce implicit deny outbound (no explicit allow-all egress rules)

```bash
az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-app \
  --query "[?direction=='Outbound'] | [].{Name:name, DestAddressPrefix:destinationAddressPrefix, DestPortRange:destinationPortRange, Action:access}" \
  --output table

az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --query "[?direction=='Outbound'] | [].{Name:name, DestAddressPrefix:destinationAddressPrefix, DestPortRange:destinationPortRange, Action:access}" \
  --output table
```

**Expected:**
```
(Both return empty or only system rules)
Name                      DestAddressPrefix  DestPortRange  Action
------------------------  -----------------  -----------  ------
(empty or Azure defaults)
```

**Tower Note:** Azure NSGs default to allow all outbound traffic. This is acceptable for lab (app tier needs outbound for package management). Production would implement egress filtering to prevent data exfiltration and command-control callbacks. Absence of explicit deny-all egress = defense-in-depth gap, but acceptable for lab scope.

---

## NETWORK INTERFACE & IP ADDRESSING (Priority 2)

### ✓ Check 6: Static Private IP Assignment Validation
**Category:** CONNECTIVITY  
**Check:** Verify all VMs assigned static (reserved) private IPs, not dynamic allocation

```bash
az network nic show \
  --resource-group rg-ailab-sachinb \
  --name nic-app \
  --query "ipConfigurations[].{Name:name, AllocationMethod:privateIPAllocationMethod, PrivateIP:privateIPAddress, Subnet:subnet.id}" \
  --output json

az network nic show \
  --resource-group rg-ailab-sachinb \
  --name nic-db \
  --query "ipConfigurations[].{Name:name, AllocationMethod:privateIPAllocationMethod, PrivateIP:privateIPAddress, Subnet:subnet.id}" \
  --output json

az network nic show \
  --resource-group rg-ailab-sachinb \
  --name nic-win \
  --query "ipConfigurations[].{Name:name, AllocationMethod:privateIPAllocationMethod, PrivateIP:privateIPAddress, Subnet:subnet.id}" \
  --output json
```

**Expected:**
```json
[
  {
    "Name": "internal",
    "AllocationMethod": "Static",
    "PrivateIP": "10.0.1.10",
    "Subnet": "/subscriptions/.../resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/virtualNetworks/vnet-ailab/subnets/snet-app"
  }
]

(Similar for nic-db: 10.0.2.10, snet-db)
(Similar for nic-win: 10.0.1.20, snet-app)
```

**Tower Note:** Static IP assignment is MANDATORY for infrastructure services (Databases, App servers). Prevents DNS/connectivity breakage if VM deallocated/reallocated. Ensures network configurations referencing fixed IPs (NSG rules, routing, monitoring) remain valid. Dynamic allocation acceptable only for temporary workloads.

---

### ✓ Check 7: Virtual Machine Network Interface NIC Attachment Verification
**Category:** CONNECTIVITY  
**Check:** Verify each VM has exactly one network interface in correct subnet

```bash
az vm show \
  --resource-group rg-ailab-sachinb \
  --name vm-app \
  --query "networkProfile.networkInterfaces[].id" \
  --output json

az vm show \
  --resource-group rg-ailab-sachinb \
  --name vm-db \
  --query "networkProfile.networkInterfaces[].id" \
  --output json

az vm show \
  --resource-group rg-ailab-sachinb \
  --name vm-win \
  --query "networkProfile.networkInterfaces[].id" \
  --output json
```

**Expected:**
```json
["/subscriptions/.../resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkInterfaces/nic-app"]
["/subscriptions/.../resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkInterfaces/nic-db"]
["/subscriptions/.../resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkInterfaces/nic-win"]
```

(Verify nic-win is in snet-app, not snet-db)

**Tower Note:** Each VM requires minimum one NIC for network connectivity. Standard lab setup is single NIC per VM. Multiple NICs would indicate multi-homed architecture (e.g., cluster heartbeat network). Confirms network configuration matches Terraform intent. Windows VM (vm-win) must be in app subnet (10.0.1.0/24), not database subnet.

---

### ✓ Check 8: No Public IPs Assigned to VMs (Zero Internet Exposure)
**Category:** SECURITY  
**Check:** Confirm all VMs have NO public IP addresses; only Bastion should have public IP

```bash
az vm list-ip-addresses \
  --resource-group rg-ailab-sachinb \
  --query "[].{VMName:virtualMachine.name, PublicIP:virtualIPAddresses[0].publicIPAddresses[0].ipAddress, PrivateIP:virtualIPAddresses[0].privateIPAddresses[0].ipAddress}" \
  --output table

# Also verify with NIC-level query
az network nic show-effective-route-table \
  --resource-group rg-ailab-sachinb \
  --name nic-app \
  --output table
```

**Expected:**
```
VMName   PublicIP      PrivateIP
-------  -----------   -----------
vm-app   None          10.0.1.10
vm-db    None          10.0.2.10
vm-win   None          10.0.1.20
```

(Only Bastion public IP should exist: `pip-bastion`)

**Tower Note:** **CRITICAL for network defense**: Removing all public IPs eliminates direct inbound attack surface. VMs unreachable from internet—attackers cannot discover/scan/exploit SSH/RDP ports. All admin access forced through Bastion (mediated, logged, MFA-enforced). Public IP on Bastion acceptable (required for interactive tunneling from internet). Validates zero-trust implicit deny + mediated access model.

---

## BASTION & SECURE ACCESS PATH (Priority 1 - CRITICAL)

### ✓ Check 9: Azure Bastion Host Provisioning & SKU Verification
**Category:** SECURITY / CONNECTIVITY  
**Check:** Confirm Bastion host is fully deployed, operational, and configured with correct SKU

```bash
az network bastion show \
  --resource-group rg-ailab-sachinb \
  --name bastion-ailab \
  --query "{Name:name, Location:location, SKU:sku, ProvisioningState:provisioningState, PublicIP:publicIPAddress}" \
  --output json

# Verify Bastion public IP
az network public-ip show \
  --resource-group rg-ailab-sachinb \
  --name pip-bastion \
  --query "{Name:name, IPAddress:ipAddress, AllocationMethod:publicIPAllocationMethod, SKU:sku.name}" \
  --output json
```

**Expected:**
```json
{
  "Name": "bastion-ailab",
  "Location": "eastus",
  "SKU": "Basic",
  "ProvisioningState": "Succeeded",
  "PublicIP": "40.XX.XX.XX"  (actual IP)
}

{
  "Name": "pip-bastion",
  "IPAddress": "40.XX.XX.XX",
  "AllocationMethod": "Static",
  "SKU": "Standard"
}
```

**Tower Note:** Bastion is the **single authorised admin access gateway**. ProvisioningState "Succeeded" confirms infrastructure readiness. SKU=Basic (max 2 Mbps, 25 concurrent) acceptable for lab; production scales to Standard/Premium. Static public IP ensures Bastion address stability for firewall rules, jump-host configurations. Bastion uses RDP/SSH protocols internally; users never install VPN software.

---

### ✓ Check 10: Bastion Subnet Isolation & Configuration
**Category:** SECURITY / CONNECTIVITY  
**Check:** Verify Bastion subnet meets Azure requirements (dedicated, /27 minimum, no NSG)

```bash
az network vnet subnet show \
  --resource-group rg-ailab-sachinb \
  --vnet-name vnet-ailab \
  --name AzureBastionSubnet \
  --query "{Name:name, AddressPrefix:addressPrefix, NSG:networkSecurityGroup, ServiceEndpoints:serviceEndpoints}" \
  --output json
```

**Expected:**
```json
{
  "Name": "AzureBastionSubnet",
  "AddressPrefix": "10.0.3.0/27",
  "NSG": null,
  "ServiceEndpoints": []
}
```

**Tower Note:** Azure Bastion requires:
  1. Subnet named exactly "AzureBastionSubnet" (Azure reserved name)
  2. Minimum /27 CIDR (32 IPs) to accommodate Bastion infrastructure
  3. NO NSG attachment (Bastion manages its own inbound rules)
  NSG=null is CORRECT. ServiceEndpoints=[] confirms no VNet service delegation. Validates Bastion meets Azure platform requirements.

---

## INTRA-NETWORK CONNECTIVITY VALIDATION (Priority 2)

### ✓ Check 11: App-to-Database Connectivity Path (East-West Traffic)
**Category:** CONNECTIVITY  
**Check:** From vm-app (10.0.1.10), verify port 5432 reachable on vm-db (10.0.2.10)

```bash
# SSH into vm-app via Bastion tunnel (from Check 12)
# Once connected to vm-app:
nc -zv 10.0.2.10 5432
```

**Expected:**
```
Connection to 10.0.2.10 5432 port [tcp/postgresql] succeeded!
```

**Failure Diagnostics:**
- If timeout: NSG rule missing on nsg-db OR subnet routing misconfigured
- If connection refused: PostgreSQL service not running on vm-db
- If no route to host: Routing table missing or UDR misconfigured

**Tower Note:** Validates **east-west data plane connectivity** between application and database tiers. Confirms NSG rules permit 10.0.1.0/24 → 10.0.2.10:5432. Tests network path before application deployment. Connectivity prerequisite for multi-tier application integration.

---

### ✓ Check 12: Bastion SSH Tunnel to VM-App (Secure Admin Access)
**Category:** CONNECTIVITY  
**Check:** Verify SSH access to vm-app (10.0.1.10) through Azure Bastion tunnel

```bash
# Create Bastion tunnel (from management workstation)
az network bastion tunnel \
  --resource-group rg-ailab-sachinb \
  --name bastion-ailab \
  --target-resource-id /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-ailab-sachinb/providers/Microsoft.Compute/virtualMachines/vm-app \
  --resource-port 22 \
  --port 8080

# In separate terminal, SSH through tunnel
ssh -p 8080 labadmin@localhost
```

**Expected:**
```
labadmin@vm-app:~$ hostname
vm-app
labadmin@vm-app:~$ whoami
labadmin
```

**Tower Note:** Bastion tunnel is network "jump-host" for SSH. Azure CLI opens local port 8080 → tunnels traffic → Bastion → vm-app:22. No direct internet path to VM SSH. Validates Bastion proxy infrastructure functional and credentials synchronized from Terraform cloud-init.

---

### ✓ Check 13: Database VM SSH Access & Network Configuration Verification
**Category:** CONNECTIVITY  
**Check:** SSH to vm-db and verify PostgreSQL listening on private IP only (10.0.2.10)

```bash
# SSH to vm-db via Bastion tunnel (similar to Check 12)
ssh -p 8081 labadmin@localhost

# Once connected to vm-db, verify PostgreSQL binding
sudo -u postgres psql -c "SHOW listen_addresses;"
```

**Expected:**
```
 listen_addresses
-----------------
 10.0.2.10
```

(NOT 0.0.0.0, NOT localhost, NOT 127.0.0.1)

**Tower Note:** PostgreSQL hardening via cloud-init: binding to specific private IP (10.0.2.10) instead of 0.0.0.0 or localhost. Prevents:
  - Port scanning exposing PostgreSQL version via TCP fingerprinting
  - Accidental exposure if NSG rules misconfigured
  - Multi-homed scenario confusion (listening on only one network interface)
  Validates infrastructure-as-code cloud-init execution and database tier isolation.

---

### ✓ Check 14: Windows VM RDP Connectivity via Bastion Tunnel
**Category:** CONNECTIVITY  
**Check:** Verify RDP port 3389 reachable on vm-win from vm-app via netcat

```bash
# SSH to vm-app via Bastion
ssh -p 8080 labadmin@localhost

# From vm-app, test RDP connectivity to vm-win
nc -zv 10.0.1.20 3389
```

**Expected:**
```
Connection to 10.0.1.20 3389 port [tcp/ms-wbt-server] succeeded!
```

**Tower Note:** RDP port reachability test validates Windows network initialization (WinRM/RDP service startup). High CPU during initial boot is normal (Sysprep). Unlike Linux, Windows VMs require several minutes for RDP readiness post-boot. Confirms network path (same subnet snet-app) functional before attempting interactive RDP session.

---

## NETWORK ROUTING & TRAFFIC FLOW (Priority 3)

### ✓ Check 15: Effective Routes on VM NICs (Routing Table Validation)
**Category:** CONNECTIVITY  
**Check:** Verify each NIC has correct effective routes (system routes + VNet routes)

```bash
az network nic show-effective-route-table \
  --resource-group rg-ailab-sachinb \
  --name nic-app \
  --output table

az network nic show-effective-route-table \
  --resource-group rg-ailab-sachinb \
  --name nic-db \
  --output table

az network nic show-effective-route-table \
  --resource-group rg-ailab-sachinb \
  --name nic-win \
  --output table
```

**Expected (for nic-app):**
```
Source                State  Address Prefix      Next Hop Type      Next Hop IP
-------------------  -----  -----------------   ----------------   -----------
Default              Active 10.0.1.0/24         VnetLocal
Default              Active 10.0.2.0/24         VnetLocal
Default              Active 10.0.3.0/27         VnetLocal
Default              Active 0.0.0.0/0           Internet
```

(All three subnets reachable via VnetLocal; internet via default gateway)

**Tower Note:** Azure VNet auto-creates system routes for intra-VNet connectivity (VnetLocal) and default internet route. Route table shows "next hop" for each destination. VnetLocal = Layer 2 switching (no gateway). 0.0.0.0/0 via Internet = outbound NAT gateway or default internet routing. Absence of custom UDRs (User-Defined Routes) acceptable for basic lab. Production would add UDRs for network appliance chaining (firewalls, proxies).

---

## NETWORK MONITORING & DIAGNOSTICS (Priority 4)

### ✓ Check 16: Network Watcher NSG Flow Logs Configuration (Optional but Recommended)
**Category:** MONITORING / SECURITY  
**Check:** Verify NSG flow logs enabled for traffic analysis and troubleshooting

```bash
# Check if Network Watcher exists in region
az network watcher list \
  --resource-group NetworkWatcherRG \
  --query "[?location=='eastus'].{Name:name, ProvisioningState:provisioningState}" \
  --output table

# List flow log configurations for nsg-app
az network watcher flow-log list \
  --location eastus \
  --query "[?targetResourceId contains('nsg-app')]" \
  --output json
```

**Expected:**
```
(May be empty if flow logs not configured—this is acceptable for lab)
```

**Tower Note:** NSG flow logs capture allow/deny decisions for every packet. Optional for lab but MANDATORY for production security monitoring:
  - Forensic analysis post-incident
  - Traffic pattern baseline
  - DDoS detection (unusual packet volumes)
  - Compliance audit (who accessed what, when)
  Flow logs require storage account; consume network bandwidth and storage costs. Lab scope doesn't require but demonstrates production-ready monitoring architecture.

---

### ✓ Check 17: Network Interface Metrics & Packet Analysis
**Category:** MONITORING / PERFORMANCE  
**Check:** Verify NIC metrics available in Azure Monitor (bytes in/out, packet counts)

```bash
az monitor metrics list \
  --resource /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkInterfaces/nic-app \
  --interval PT1M \
  --start-time $(date -u -d '60 minutes ago' +%Y-%m-%dT%H:%M:%S)Z \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S)Z \
  --query "value[0].name.localizedValue" \
  --output table
```

**Expected:**
```
Bytes Received
Bytes Sent
Packets Received
Packets Sent
```

(If no data, wait 5 minutes for metrics pipeline to ingest)

**Tower Note:** Azure Monitor automatically captures NIC-level metrics (throughput, packet counts). Baseline these metrics post-deployment to understand normal traffic patterns:
  - Bytes Sent/Received = network utilization (capacity planning)
  - Packet rates = conversation frequency (anomaly detection)
  Production would set alerts on thresholds (e.g., alert if throughput > 80% of SKU limit).

---

## NETWORK SECURITY POSTURE (Priority 4)

### ✓ Check 18: DDoS Protection Baseline (Lab Scope Assessment)
**Category:** SECURITY  
**Check:** Confirm public IPs have DDoS Standard enabled (or document why Basic is acceptable)

```bash
az network public-ip show \
  --resource-group rg-ailab-sachinb \
  --name pip-bastion \
  --query "{Name:name, DDoSProtection:ddosSettings.protectionLevel, PublicIPPrefix:publicIPPrefix}" \
  --output json
```

**Expected:**
```json
{
  "Name": "pip-bastion",
  "DDoSProtection": "Basic",
  "PublicIPPrefix": null
}
```

**Tower Note:** Azure DDoS Protection has two tiers:
  - **Basic** (default, free): Mitigates common Layer 3/4 attacks (SYN flood, UDP flood)
  - **Standard** (paid): Advanced mitigation, Layer 7 protection, DDoS telemetry
  Lab environment with Basic is acceptable (not production-exposed). Bastion public IP has very limited attack surface (only accepts Bastion protocol traffic, not SSH/RDP directly). Production would enable DDoS Standard for customer-facing IPs.

---

### ✓ Check 19: Network Security Best Practices Review - Rule Audit
**Category:** SECURITY  
**Check:** Manual audit of NSG rules for least-privilege compliance

```bash
# Export all NSG rules to review
az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-app \
  --query "[] | sort_by(@, &priority) | [].{Priority:priority, Name:name, Direction:direction, Access:access, Protocol:protocol, SourcePort:sourcePortRange, DestPort:destinationPortRange, Source:sourceAddressPrefix, Dest:destinationAddressPrefix}" \
  --output json

az network nsg rule list \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --query "[] | sort_by(@, &priority) | [].{Priority:priority, Name:name, Direction:direction, Access:access, Protocol:protocol, SourcePort:sourcePortRange, DestPort:destinationPortRange, Source:sourceAddressPrefix, Dest:destinationAddressPrefix}" \
  --output json
```

**Audit Checklist:**
- [ ] No "allow from 0.0.0.0/0" on sensitive ports (22, 3389, 5432)
- [ ] Least-privilege source ranges (avoid 0.0.0.0/0 except for public services)
- [ ] Priority ordering prevents rule shadowing (lower priority = lower number)
- [ ] Descriptive rule names (avoid generic "Allow", "Rule1")
- [ ] Document business justification for each allow rule
- [ ] Review quarterly for stale/orphaned rules

**Tower Note:** NSG rule audit is continuous security practice. Regular review prevents "rule creep" (accumulation of overly-permissive rules for temporary fixes). Terraform-driven rules (as in this lab) are reproducible and auditable, reducing ad-hoc firewall changes. Production would integrate NSG audit into compliance frameworks (CIS Azure Foundations, SOC 2).

---

### ✓ Check 20: Subnet Size Planning & Address Space Exhaustion
**Category:** CONNECTIVITY / MONITORING  
**Check:** Verify subnet CIDR sizes provide adequate growth capacity

```bash
# Calculate available IPs per subnet
echo "snet-app (10.0.1.0/24): 256 total - 5 reserved (network, gateway, broadcast, Azure reserved) = 251 usable IPs"
echo "snet-db (10.0.2.0/24): 256 total - 5 reserved = 251 usable IPs"
echo "AzureBastionSubnet (10.0.3.0/27): 32 total - 5 reserved = 27 usable IPs"

# Query current resource counts
az vm list \
  --resource-group rg-ailab-sachinb \
  --query "length(@)" \
  --output tsv
```

**Expected:**
```
snet-app: 251 usable (currently 2 VMs: vm-app, vm-win → 249 free)
snet-db: 251 usable (currently 1 VM: vm-db → 250 free)
AzureBastionSubnet: 27 usable (Bastion consumes ~3-5 → ~22 free)
```

**Tower Note:** /24 subnets (256 IPs) provide ample room for lab scalability (multi-tier app servers, database replicas). /27 for Bastion is Azure minimum. Capacity planning prevents mid-deployment reshuffling. If future growth exceeds subnet size, subnet expansion requires VNet reconfiguration and potential service interruption. Current allocation suitable for 3-tier lab; production with >50 VMs per tier would need larger subnets or subnet consolidation.

---

## SUMMARY VALIDATION

| Category | Count | Priority | Status |
|----------|-------|----------|--------|
| SECURITY | 8 | P1/P2 | ✓ |
| CONNECTIVITY | 8 | P1/P2 | ✓ |
| MONITORING | 2 | P3 | ✓ |
| PERFORMANCE | 1 | P4 | ✓ |
| ARCHITECTURE | 1 | P1 | ✓ |
| **TOTAL** | **20** | **Mixed** | ✓ |

---

## Quick Network Engineer Decision Matrix

| Priority | Item | FAIL Condition (STOP Deployment) |
|----------|------|----------------------------------|
| **P1** | Check 3 (NSG SSH/RDP) | Port 22/3389 from 0.0.0.0/0 or non-Bastion source |
| **P1** | Check 4 (NSG DB Rules) | Port 5432 from non-app subnet or Internet |
| **P1** | Check 8 (No Public IPs) | Any app/db VM has public IP |
| **P1** | Check 9 (Bastion Status) | ProvisioningState ≠ Succeeded |
| **P2** | Check 6 (Static IPs) | Any VM uses dynamic allocation |
| **P2** | Check 11 (App-DB Path) | Cannot reach 10.0.2.10:5432 from vm-app |
| **P2** | Check 12 (Bastion SSH) | Cannot create Bastion tunnel to vm-app |
| **P3** | Check 15 (Routes) | Missing VnetLocal routes between subnets |
| **P4** | Check 20 (Address Space) | <50% subnet capacity remaining |

---

## Network Engineer Sign-Off Checklist

- [ ] VNet address space (10.0.0.0/16) verified; no routing conflicts
- [ ] All three subnets assigned non-overlapping CIDR blocks
- [ ] App & DB NSGs attached at subnet level; Bastion subnet has no NSG
- [ ] SSH/RDP restricted to Bastion subnet (10.0.3.0/27) only
- [ ] PostgreSQL port 5432 restricted to app subnet (10.0.1.0/24) only
- [ ] No public IPs on app/db VMs; only Bastion has public IP
- [ ] All VMs assigned static private IPs; no dynamic allocation
- [ ] Each VM has exactly one NIC in correct subnet
- [ ] Bastion host provisioning state = Succeeded, SKU = Basic
- [ ] Bastion subnet = AzureBastionSubnet, /27 CIDR, no NSG
- [ ] Connectivity path: Bastion → vm-app (SSH) → vm-db (PostgreSQL)
- [ ] Windows VM RDP port reachable from app subnet
- [ ] Effective routing shows all subnets reachable via VnetLocal
- [ ] NSG rule priorities prevent shadowing; least-privilege enforced
- [ ] Subnet address space provides adequate growth capacity (>50% free)
- [ ] Network monitoring baseline captured (optional, recommended for prod)

---

## Handoff to Application Engineer

**Network Readiness: ✓ PASS**

Once network validation complete, application engineer proceeds with:
1. PostgreSQL database initialization (schema, indices, baseline data)
2. Application deployment to vm-app (container/service/binary)
3. Load testing to validate app-to-db connectivity under load
4. Monitoring integration (Application Insights, custom metrics)

**Network operations team retains:**
- NSG rule change requests → network engineer approval
- Connectivity issues → escalate to network team (routing, firewall)
- Performance degradation → capture metrics, contact Azure support

---

**Validator Name:** ___________________ **Date:** ___________________ **Time:** ___________________
