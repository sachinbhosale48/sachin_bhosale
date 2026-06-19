# Azure Environment Resilience Test Plan
**Date:** 2026-06-16  
**Environment:** rg-ailab-sachinb (East US)  
**Participant:** sachinb  
**Test Lead:** Senior Cloud Resilience Engineer

---

## Infrastructure Overview

### VMs & Configuration
| Component | OS | VM Size | Private IP | Key Service |
|-----------|-----|---------|-----------|-------------|
| **vm-app** | Ubuntu 22.04 LTS | Standard_B2ms | 10.0.1.10 | Payment service (custom app) |
| **vm-db** | Ubuntu 22.04 LTS | Standard_B2ms | 10.0.2.10 | PostgreSQL 14 (max_connections=20) |
| **vm-win** | Windows Server 2022 | Standard_B2s | 10.0.1.20 | IIS/Reporting Service |

### Network Architecture
- **vNET:** 10.0.0.0/16
- **App Subnet:** 10.0.1.0/24 (vm-app, vm-win)
- **DB Subnet:** 10.0.2.0/24 (vm-db)
- **Bastion Subnet:** 10.0.3.0/27 (Azure Bastion Basic)
- **Access Control:** SSH/RDP from Bastion only; DB port 5432 from app subnet only
- **Storage:** Standard LRS with 7-day soft-delete

### Database Configuration
```
User: labuser
Password: Lab@2024!
Database: labdb
Listen: 10.0.2.10:5432
Max Connections: 20
Client Connections: 10.0.1.0/24
```

---

## Pre-Test Checklist

### Verify System Baseline
Execute these commands before **each** test scenario to establish baseline metrics:

```bash
# On vm-app: Check disk, CPU, memory
df -h /
free -h
uptime
systemctl status | grep running

# On vm-db: Check PostgreSQL status and connections
sudo -u postgres psql -c "SELECT version();"
sudo -u postgres psql -c "SELECT count(*) as current_connections FROM pg_stat_activity;"
```

### Connectivity Validation
```bash
# From vm-app to vm-db (test PostgreSQL connectivity)
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;"

# From vm-win to vm-db (if test requires)
powershell -Command "Test-NetConnection -ComputerName 10.0.2.10 -Port 5432 -InformationLevel Quiet"
```

### Backup Current State (Pre-Test)
```bash
# Capture PostgreSQL connection limit before test
sudo -u postgres psql -c "SHOW max_connections;" > /tmp/pg_baseline.txt

# Snapshot current disk usage
df -h / > /tmp/disk_baseline.txt
```

---

## Test Scenario A: VM-App CPU Exhaustion (Payment Service Under Load)

### 1. Scenario Name & Description
**Name:** CPU Exhaustion - Payment Service Peak Load  
**Description:** Simulate sustained high CPU load (95%+) on vm-app to test payment service degradation, monitoring alerting, and auto-recovery.

**Business Context:**  
- Payment processing typically spikes during peak hours
- CPU exhaustion can cause payment timeouts and customer failures
- Test validates whether load can be shed or scaled

---

### 2. Failure Being Simulated
- **Root Cause:** Computationally intensive payment processing or runaway service thread
- **Symptoms:** Payment API response times >2s, timeouts, kernel OOM killer
- **User Impact:** Payment failures, degraded user experience, potential revenue impact
- **Component Impact:**
  - **vm-app:** CPU 95%+, IO wait increased, memory pressure
  - **vm-db:** No direct impact initially; may see connection starvation if app exhausts pool
  - **vm-win:** No impact

---

### 3. Trigger Command (Safe & Reversible)

#### Option A: CPU Load via stress-ng (Recommended — easiest cleanup)
```bash
# SSH into vm-app via Bastion
# Install stress-ng if needed
sudo apt-get install -y stress-ng

# Trigger sustained 95% CPU load on 2 cores (B2ms = 2 vCPU)
stress-ng --cpu 2 --cpu-load 95 --timeout 5m &

# Capture PID for later cleanup
STRESS_PID=$!
echo "Stress process PID: $STRESS_PID" | tee /tmp/stress_pid.txt
```

#### Option B: dd/dd-based disk IO if CPU load via compute isn't feasible
```bash
# Alternative: Heavy disk I/O to spike CPU
dd if=/dev/zero of=/tmp/testfile bs=1M count=5000 &
```

---

### 4. Expected Impact on Each Component

| Component | Expected Behavior | Metric |
|-----------|------------------|--------|
| **vm-app** | CPU utilization: 95%+ | `top`: CPU%: 95+, load avg: >2.0 |
| | Memory pressure increases | Free memory: < 20% of 8GB (~1.6GB free) |
| | I/O wait elevated | `iostat`: %wa > 10% |
| | Payment API latency increases | Response time: baseline 100ms → 2000ms+ |
| **vm-db** | Connection pool utilization ↑ | `pg_stat_activity`: 15–18 active connections |
| | Query queueing possible | Query wait time: baseline 1ms → 50ms+ |
| | I/O reads/writes stable (no CPU spike on db) | Disk throughput: unchanged |
| **vm-win** | No change | N/A |

---

### 5. Recovery Command

```bash
# Method 1: Kill stress-ng process (fastest)
sudo pkill -9 stress-ng

# Method 2: If using dd, kill dd process
sudo pkill -9 dd

# Verify cleanup
ps aux | grep stress-ng
ps aux | grep dd
```

**Recovery Time:** < 30 seconds (immediate process termination)

---

### 6. Validation Command (Confirms Recovery Complete)

```bash
# Verify CPU returned to baseline
top -bn1 | grep "Cpu(s)" | grep -oP '\d+\.\d+(?=%us)'
# Should return value < 20% (normal idle background processes)

# Confirm no stress-ng processes running
pgrep stress-ng || echo "✓ stress-ng cleanup complete"

# Check payment service is responding
curl -X GET http://localhost:8080/health 2>/dev/null | jq '.status'
# Expected: "healthy" or "ok"

# Verify system load average dropped
uptime | grep -oP 'load average: \K.*'
# Expected: all three values < 1.0 within 60 seconds
```

**Expected Output on Recovery:**
```
✓ Cpu(s) output: 5.2% (or similar low value)
✓ stress-ng cleanup complete
✓ Payment service: healthy
✓ Load average: 0.15, 0.12, 0.10
```

---

### 7. RTO Target & SLA

| Metric | Target | Acceptance Criteria |
|--------|--------|-------------------|
| **Time to Detect** | < 1 minute | Monitoring alert triggered when CPU > 85% for 30s |
| **Time to Mitigate** | < 2 minutes | Manual kill or auto-scaling policy activated |
| **Time to Recovery** | < 5 minutes | CPU < 30%, payment API latency < 500ms |
| **RTO (Total)** | **< 5 minutes** | Service availability restored, no data loss |

---

### 8. Go/No-Go Checklist (Execute Before Test)

**Run these commands and verify all show expected status:**

```bash
# ✓ Check baseline CPU < 15%
uptime | awk '{print "Load avg (1/5/15):", $(NF-2), $(NF-1), $NF}'

# ✓ Verify vm-app can reach vm-db
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "✓ DB connectivity OK"

# ✓ Confirm stress-ng is available
which stress-ng || echo "⚠ WARNING: stress-ng not installed, will need: sudo apt-get install stress-ng"

# ✓ Verify payment service is running (if applicable)
curl -s http://localhost:8080/health | jq '.status' && echo "✓ Service healthy"

# ✓ Check disk space (need >1GB free)
df -h / | awk 'NR==2 {if ($4 ~ /G/) print "✓ Disk space OK: "$4" available"; else print "⚠ Low disk: "$4}'
```

**Go/No-Go Decision:**
- ✓ **GO** if: All checks pass, CPU baseline < 15%, DB connectivity confirmed
- ⛔ **NO-GO** if: Any check fails, CPU > 30%, stress-ng not available, disk < 1GB free

---

## Test Scenario B: DB Connection Pool Exhaustion (max_connections Reached)

### 1. Scenario Name & Description
**Name:** PostgreSQL Connection Pool Exhaustion  
**Description:** Reach max_connections limit (20) to trigger new connection rejections and test failover/queuing behavior.

**Business Context:**  
- max_connections = 20 is very conservative; real prod typically 100–500
- Simulates sustained connection leaks or connection storms
- Test validates graceful degradation vs. hard failure

---

### 2. Failure Being Simulated
- **Root Cause:** Connection leak in app layer (not closing connections) or connection storm
- **Symptoms:** "FATAL: sorry, too many clients already" errors
- **User Impact:** Payment service cannot reach database; new transactions fail immediately
- **Component Impact:**
  - **vm-db:** New connection attempts rejected; existing connections function normally
  - **vm-app:** Payment service receives connection refused errors; circuit breaker may activate
  - **vm-win:** No direct impact

---

### 3. Trigger Command (Safe & Reversible)

```bash
# SSH into vm-db via Bastion

# Step 1: Verify current connection count
sudo -u postgres psql -c "SELECT count(*) as active_connections FROM pg_stat_activity;"
# Expected output: ~2–4 (normal system connections)

# Step 2: Open 16–18 "idle" connections (leave 2 slots for admin/monitoring)
for i in {1..16}; do
  psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT pg_sleep(600);" &
done

# Wait 5 seconds for connections to establish
sleep 5

# Step 3: Verify connection count now ~18
sudo -u postgres psql -c "SELECT count(*) as active_connections FROM pg_stat_activity;"
# Expected: ~16–18

# Step 4: Try new connection (should succeed but with warning or wait)
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" --connect-timeout=2
# May show warning or slight delay
```

---

### 4. Expected Impact on Each Component

| Component | Expected Behavior | Metric |
|-----------|------------------|--------|
| **vm-db** | Connection slot occupation: 16–18 of 20 | `pg_stat_activity`: connections > 15 |
| | New connection attempts: Timeout or rejected | Connection refused errors in vm-app logs |
| | Query performance: Normal (no query slowdown) | Existing query latency: baseline |
| | Memory usage: Steady (not memory-driven failure) | `free -h`: unchanged |
| **vm-app** | Payment service: Connection failures | Error rate: baseline 0% → 5–10% |
| | API response time: Increased (waiting for slots) | Latency: baseline 100ms → timeout (30s+) |
| | Logs: "sorry, too many clients already" | `tail -f /var/log/app/error.log` |
| **vm-win** | No impact | N/A |

---

### 5. Recovery Command

```bash
# Option A: Kill idle psql processes (most direct)
pkill -f "pg_sleep(600)" || echo "No idle connections to kill"

# Verify process cleanup
ps aux | grep psql | grep -v grep || echo "✓ All idle sessions terminated"

# Option B: Restart PostgreSQL service (more forceful)
sudo systemctl restart postgresql
```

**Recovery Time:** < 30 seconds (process termination or systemctl restart)

---

### 6. Validation Command (Confirms Recovery Complete)

```bash
# Verify connection count returned to baseline
sudo -u postgres psql -c "SELECT count(*) as active_connections FROM pg_stat_activity;"
# Expected: < 5

# Confirm new connections succeed
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "✓ New connections accepted"

# Check payment service recovered (from vm-app)
curl -s http://localhost:8080/db-check | jq '.database' 
# Expected: "connected" or "ok"

# Verify no errors in PostgreSQL logs (within last 1 min)
sudo tail -n 20 /var/log/postgresql/postgresql-14-main.log | grep -i 'FATAL\|ERROR' || echo "✓ No recent errors"
```

**Expected Output on Recovery:**
```
active_connections: 3
✓ New connections accepted
✓ Database: connected
✓ No recent errors
```

---

### 7. RTO Target & SLA

| Metric | Target | Acceptance Criteria |
|--------|--------|-------------------|
| **Time to Detect** | < 30 seconds | Monitoring alert when active_connections > 18 |
| **Time to Mitigate** | < 1 minute | Kill idle sessions or restart service |
| **Time to Recovery** | < 3 minutes | New connections accepted, error rate = 0% |
| **RTO (Total)** | **< 5 minutes** | Payment service fully operational, no data loss |
| **Data Loss** | **Zero** | All committed transactions preserved |

---

### 8. Go/No-Go Checklist (Execute Before Test)

```bash
# ✓ Verify PostgreSQL is running
sudo systemctl is-active postgresql && echo "✓ PostgreSQL running"

# ✓ Check baseline connection count < 5
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;" | grep -E '[0-4]$' && echo "✓ Baseline connections normal"

# ✓ Confirm max_connections = 20
sudo -u postgres psql -c "SHOW max_connections;" | grep 20 && echo "✓ max_connections=20"

# ✓ Test connectivity from vm-app
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" && echo "✓ App→DB connectivity OK"

# ✓ Verify at least 18 available slots (20 total - 2 reserved for superuser)
sudo -u postgres psql -c "SELECT count(*), 20 - count(*) as available_slots FROM pg_stat_activity;" 
# Expected: ~2–4 active, 16–18 available
```

**Go/No-Go Decision:**
- ✓ **GO** if: PostgreSQL running, baseline < 5 connections, max_connections verified, app connectivity confirmed
- ⛔ **NO-GO** if: PostgreSQL down, baseline > 10 connections, max_connections ≠ 20, app cannot reach DB

---

## Test Scenario C: Disk Fill on vm-app (Production Write Failures)

### 1. Scenario Name & Description
**Name:** Disk Exhaustion - Application Write Failures  
**Description:** Fill disk to 95% on vm-app to trigger write failures, payment service crashes, and test cleanup/alerting.

**Business Context:**  
- Disk fill is common in production (logs, temp files, queue data)
- Application may crash ungracefully or hang when writes fail
- Critical to detect and respond within RTO

---

### 2. Failure Being Simulated
- **Root Cause:** Uncontrolled log growth, temp file accumulation, or stuck processes writing data
- **Symptoms:** "No space left on device" errors, service crashes, payment transactions fail
- **User Impact:** Complete service outage for write operations; reads may work temporarily
- **Component Impact:**
  - **vm-app:** Writes fail; logs stop being written; payment service unavailable
  - **vm-db:** No direct impact (separate vm-db disk); may see replication lag if applicable
  - **vm-win:** No impact

---

### 3. Trigger Command (Safe & Reversible)

```bash
# SSH into vm-app via Bastion

# Step 1: Check baseline disk usage
df -h /
# Expected: ~10–15GB used of 30GB (50–60% free)

# Step 2: Create large file to consume 70% of remaining space
# Calculate target: 30GB disk; want 95% full = 28.5GB used
# Assuming 10GB currently used, need 18.5GB more

dd if=/dev/zero of=/tmp/disktest-large.bin bs=1M count=18000 &

# Capture PID for cleanup
FILL_PID=$!
echo "Disk fill PID: $FILL_PID" | tee /tmp/diskfill_pid.txt

# Step 3: Monitor fill progress (in separate terminal)
watch -n 1 'df -h / && echo "---" && ps aux | grep dd | grep -v grep'

# Step 4: When disk reaches 95%, stop and verify
sleep 120  # Wait ~2 minutes for ~18GB write
kill $FILL_PID 2>/dev/null || wait $FILL_PID

# Verify disk is now ~95% full
df -h /
# Expected output: Used: 28GB+ of 30GB, Available: <2GB
```

---

### 4. Expected Impact on Each Component

| Component | Expected Behavior | Metric |
|-----------|------------------|--------|
| **vm-app** | Disk usage: 95%+ | `df -h /`: Available < 2GB |
| | Write operations: Fail | Errors: "No space left on device" |
| | Application logs: Stop growing | `tail -f /var/log/app.log`: Last entry time frozen |
| | Payment service: Degraded or down | Status: HTTP 503 or timeouts |
| | Kernel behavior: Cache pressure | `cat /proc/pressure/io`: >50% |
| **vm-db** | No impact (separate disk/vm) | Disk: unchanged, connections: unchanged |
| **vm-win** | No impact | N/A |

---

### 5. Recovery Command

```bash
# Method 1: Remove the large test file (fastest)
sudo rm -f /tmp/disktest-large.bin

# Verify file removed and disk space reclaimed
df -h /
# Expected: Available space returned to ~18GB

# Method 2: If application corrupted, clear logs
sudo journalctl --vacuum=100M  # Clear journal
sudo find /var/log -name "*.log" -type f -exec truncate -s 0 {} \;

# Restart application service to clear any error states
sudo systemctl restart app  # If app has systemd service
# OR
pkill -9 payment-service  # Manual kill if running as process
```

**Recovery Time:** < 30 seconds (file deletion instant; optional log cleanup 5–10 seconds)

---

### 6. Validation Command (Confirms Recovery Complete)

```bash
# Verify disk space reclaimed
df -h / | awk 'NR==2 {if ($5 ~ /[0-9][0-9]%/) perc=$5; else perc=$4; print "Disk usage: " perc}'
# Expected: < 60%

# Confirm test file is gone
ls -la /tmp/disktest-large.bin 2>&1 | grep "No such file" && echo "✓ Test file removed"

# Check payment service is running
systemctl is-active app || pgrep -f payment-service > /dev/null && echo "✓ Service running"

# Verify new writes succeed
touch /tmp/test-write.txt && echo "test data" >> /tmp/test-write.txt && echo "✓ Writes working" && rm /tmp/test-write.txt

# Check application logs are writing again
tail -n 5 /var/log/app/error.log | awk '{print "Last log entry: " $0}' || echo "⚠ Logs not yet recovered"
```

**Expected Output on Recovery:**
```
Disk usage: 45%
✓ Test file removed
✓ Service running
✓ Writes working
Last log entry: [2026-06-16T12:34:56Z] INFO Payment service resumed
```

---

### 7. RTO Target & SLA

| Metric | Target | Acceptance Criteria |
|--------|--------|-------------------|
| **Time to Detect** | < 1 minute | Alert when disk > 90% free space lost |
| **Time to Mitigate** | < 2 minutes | Remove large files, clear logs, restart service |
| **Time to Recovery** | < 5 minutes | Writes functioning, disk < 85%, service healthy |
| **RTO (Total)** | **< 5 minutes** | Payment service operational, no data loss |

---

### 8. Go/No-Go Checklist (Execute Before Test)

```bash
# ✓ Verify current disk usage is 50–60% (not already high)
df -h / | awk 'NR==2 {perc=$5; gsub(/%/,"",perc); if (perc>=50 && perc<=60) print "✓ Baseline OK: "perc"% used"; else print "⚠ Baseline out of range: "perc"% used"}'

# ✓ Confirm at least 15GB free space available
df -h / | awk 'NR==2 {print $4}' | grep -E '[0-9]{2}G|[0-9]T' && echo "✓ Sufficient free space"

# ✓ Verify payment service is running and healthy
curl -s http://localhost:8080/health | jq '.status' && echo "✓ Service healthy"

# ✓ Check disk write performance (ensure not already slow)
time dd if=/dev/zero of=/tmp/write-test bs=1M count=100 2>/dev/null && rm /tmp/write-test && echo "✓ Write performance baseline OK"

# ✓ Verify journalctl/logs are operational
sudo journalctl -n 5 > /dev/null && echo "✓ Logging OK"
```

**Go/No-Go Decision:**
- ✓ **GO** if: Disk 50–60% full, >15GB free, service healthy, writes performing normally
- ⛔ **NO-GO** if: Disk already >80% full, <5GB free, service degraded, write latency >1s per 100MB

---

## Test Scenario D: Network Routing Misconfiguration (App Cannot Reach DB)

### 1. Scenario Name & Description
**Name:** Database Network Isolation - Broken Connectivity  
**Description:** Block network traffic between vm-app (10.0.1.0/24) and vm-db (10.0.2.0/24) by removing NSG rule to simulate misconfiguration or network outage.

**Business Context:**  
- Network misconfiguration is a common root cause in production
- Could be NSG rule deletion, subnet route table misconfiguration, or firewall block
- Test validates detection time and failover/retry behavior

---

### 2. Failure Being Simulated
- **Root Cause:** Network configuration error (NSG rule removed, route table deleted, or network appliance misconfiguration)
- **Symptoms:** "Connection timed out" (port 5432) or "Network is unreachable"
- **User Impact:** All database queries fail; payment transactions cannot complete; service down
- **Component Impact:**
  - **vm-app:** Outbound traffic to 10.0.2.0/24 fails; logs show connection timeout
  - **vm-db:** Normal operation; no incoming traffic from app layer
  - **vm-win:** No impact (different subnet interaction)

---

### 3. Trigger Command (Safe & Reversible)

**Option A: Modify NSG rule via Azure CLI (Recommended)**

```bash
# From local machine or via Bastion with Azure CLI installed

# Step 1: Get NSG rule ID for PostgreSQL allow rule
az network nsg rule show \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --query id -o tsv

# Expected output:
# /subscriptions/{sub-id}/resourceGroups/rg-ailab-sachinb/providers/Microsoft.Network/networkSecurityGroups/nsg-db/securityRules/AllowPostgres

# Step 2: DISABLE the rule (change Action from Allow to Deny)
az network nsg rule update \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --access Deny \
  --direction Inbound \
  --priority 100 \
  --protocol Tcp \
  --source-address-prefixes "10.0.1.0/24" \
  --destination-port-ranges 5432

# Verify rule is now Deny
az network nsg rule show \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --query access -o tsv
# Expected: Deny
```

**Option B: Via iptables on vm-db (If Azure CLI unavailable)**

```bash
# SSH into vm-db

# Step 1: Block incoming traffic on port 5432
sudo iptables -I INPUT -p tcp --dport 5432 -j DROP

# Save iptables rules (persists across reboot)
sudo iptables-save > /tmp/iptables-backup.txt
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null

# Verify rule is in place
sudo iptables -L INPUT -n | grep 5432
# Expected: Chain INPUT ... DROP tcp -- anywhere anywhere tcp dpt:5432
```

---

### 4. Expected Impact on Each Component

| Component | Expected Behavior | Metric |
|-----------|------------------|--------|
| **vm-app** | Connectivity: Cannot reach DB | `psql -h 10.0.2.10 -d labdb`: Connection timeout (after 3–10s) |
| | Payment service: Failures | Error logs: "Connection refused" or "timeout" |
| | API response: Error 503 | `curl http://localhost:8080/payments`: HTTP 503 Service Unavailable |
| | Connection pooling: Exhausted | Retry attempts spike; eventual pool exhaustion |
| **vm-db** | Incoming connections: Rejected | `sudo netstat -tnp` shows NO connections from 10.0.1.x |
| | PostgreSQL: Normal operation | `systemctl is-active postgresql`: active |
| | Logs: Connection rejected silently | No error in PostgreSQL logs; NSG silently drops |
| **vm-win** | No impact | N/A |

---

### 5. Recovery Command

**Option A: Via Azure CLI (Restore NSG rule)**

```bash
# Re-enable the PostgreSQL rule (change Deny back to Allow)
az network nsg rule update \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --access Allow \
  --direction Inbound \
  --priority 100 \
  --protocol Tcp \
  --source-address-prefixes "10.0.1.0/24" \
  --destination-port-ranges 5432

# Verify rule is Allow
az network nsg rule show \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --query access -o tsv
# Expected: Allow
```

**Option B: Via iptables on vm-db (Restore iptables)**

```bash
# SSH into vm-db

# Remove the DROP rule for port 5432
sudo iptables -D INPUT -p tcp --dport 5432 -j DROP

# Verify rule is removed
sudo iptables -L INPUT -n | grep 5432
# Expected: (no output)

# Restore from backup if needed
sudo iptables-restore < /tmp/iptables-backup.txt
```

**Recovery Time:** < 10 seconds (rule change immediate; traffic flows on next packet)

---

### 6. Validation Command (Confirms Recovery Complete)

```bash
# From vm-app: Verify connectivity restored
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "✓ DB connectivity restored"
# Expected: Output "1" and success

# From vm-app: Test payment service can reach DB
curl -s http://localhost:8080/db-check | jq '.database_status'
# Expected: "connected" or "healthy"

# From vm-app: Run health check query
psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT count(*) as active_connections FROM pg_stat_activity WHERE datname='labdb';"
# Expected: Output a number >= 1

# From vm-db: Verify rule is Allow (if using Azure CLI)
az network nsg rule show \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --query access -o tsv
# Expected: Allow

# Monitor application logs show connection success
tail -n 10 /var/log/app/error.log | grep -i "connected" && echo "✓ App logged DB connection success"
```

**Expected Output on Recovery:**
```
✓ DB connectivity restored
✓ Database status: connected
active_connections: 2
✓ Access: Allow
✓ App logged DB connection success
```

---

### 7. RTO Target & SLA

| Metric | Target | Acceptance Criteria |
|--------|--------|-------------------|
| **Time to Detect** | < 30 seconds | Monitoring alert on failed DB queries or NSG rule change event |
| **Time to Mitigate** | < 1 minute | NSG rule restored or iptables rule removed |
| **Time to Recovery** | < 3 minutes | DB connectivity re-established, payment service operational |
| **RTO (Total)** | **< 5 minutes** | Full service availability, no data loss |

---

### 8. Go/No-Go Checklist (Execute Before Test)

```bash
# ✓ Verify NSG rule AllowPostgres is currently Allow
az network nsg rule show \
  --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db \
  --name AllowPostgres \
  --query access -o tsv | grep -q Allow && echo "✓ NSG rule is Allow"

# ✓ Confirm current app→db connectivity
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "✓ Baseline connectivity confirmed"

# ✓ Verify PostgreSQL listening on 5432
sudo netstat -tlnp | grep 5432 && echo "✓ PostgreSQL listening"

# ✓ Check payment service health
curl -s http://localhost:8080/health | jq '.status' && echo "✓ Payment service healthy"

# ✓ Baseline: Document connected clients before test
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;" | tail -1
```

**Go/No-Go Decision:**
- ✓ **GO** if: NSG rule is Allow, connectivity confirmed, PostgreSQL listening, service healthy
- ⛔ **NO-GO** if: NSG rule is Deny, connectivity already broken, PostgreSQL down, service unhealthy

---

## Test Scenario E: Windows IIS Service Failure (Reporting Service Down)

### 1. Scenario Name & Description
**Name:** IIS Service Failure - Reporting Service Outage  
**Description:** Stop the IIS service on vm-win to simulate service crash or resource starvation, test failover, and validate monitoring alerting.

**Business Context:**  
- Reporting/dashboard service on Windows IIS serves real-time analytics
- Service crashes due to memory leaks, deadlocks, or resource exhaustion are common
- Test validates quick detection and service restart capability

---

### 2. Failure Being Simulated
- **Root Cause:** IIS service crash, worker process hang, or manual service stop
- **Symptoms:** Service unavailable (HTTP 503), reporting dashboards blank, slow load times
- **User Impact:** Analytics unavailable; business intelligence delays; no alerts to ops
- **Component Impact:**
  - **vm-win:** IIS down; HTTP endpoints return 503 or connection refused
  - **vm-app:** No direct impact (independent payment service)
  - **vm-db:** No impact (no direct IIS→DB traffic in this scenario)

---

### 3. Trigger Command (Safe & Reversible)

```powershell
# RDP/Bastion into vm-win

# Method 1: Stop IIS service (cleanest)
Stop-Service -Name W3SVC -Force -ErrorAction SilentlyContinue
# Expected: Returns without output if successful

# Verify IIS is stopped
Get-Service -Name W3SVC | Select-Object Status
# Expected output: Status: Stopped

# Method 2: Alternative - Stop specific app pool (if testing single app failure)
Stop-WebAppPool -Name "DefaultAppPool" -ErrorAction SilentlyContinue

# Method 3: Disable HTTP Binding (alternate network isolation)
# Get-WebSite -Name "Default Web Site" | Stop-Website
```

---

### 4. Expected Impact on Each Component

| Component | Expected Behavior | Metric |
|-----------|------------------|--------|
| **vm-win** | IIS service: Stopped | `Get-Service W3SVC`: Status = Stopped |
| | HTTP port 80/443: Listening stopped | `netstat -an` shows no LISTENING on :80/:443 |
| | Reporting endpoints: Unavailable | `curl http://10.0.1.20/reports`: Connection refused |
| | CPU/Memory: Low (no worker processes) | Task Manager: w3wp.exe not present |
| **vm-app** | No direct impact | Normal operation; payment service unaffected |
| **vm-db** | No impact | Connections: unchanged; queries: normal latency |
| **Monitoring** | Alert triggered | Dashboard shows vm-win IIS unhealthy |

---

### 5. Recovery Command

```powershell
# Start IIS service
Start-Service -Name W3SVC

# Wait for service startup (typically 5–10 seconds)
Start-Sleep -Seconds 10

# Verify service is running
Get-Service -Name W3SVC | Select-Object Status
# Expected: Status: Running

# Alternative: Restart instead of just start
Restart-Service -Name W3SVC -Force
```

**Recovery Time:** 10–15 seconds (service startup time)

---

### 6. Validation Command (Confirms Recovery Complete)

```powershell
# Verify IIS service is running
Get-Service -Name W3SVC | Where-Object {$_.Status -eq 'Running'} | 
  Select-Object Name, Status | ConvertTo-Json
# Expected: W3SVC, Running

# Confirm HTTP endpoint is responding
$response = Invoke-WebRequest -Uri "http://10.0.1.20/health" -UseBasicParsing -ErrorAction SilentlyContinue
if ($response.StatusCode -eq 200) {
  Write-Host "✓ IIS responding to HTTP requests"
} else {
  Write-Host "⚠ IIS not responding correctly"
}

# Verify app pools are started
Get-WebAppPool | Where-Object {$_.State -eq 'Started'} | 
  Select-Object Name, State
# Expected: DefaultAppPool (or relevant pool), Started

# Check reporting service is operational
$report_result = Invoke-WebRequest -Uri "http://10.0.1.20/reports/status" -UseBasicParsing -ErrorAction SilentlyContinue
if ($report_result.StatusCode -eq 200) {
  Write-Host "✓ Reporting service operational"
}

# Verify application is using memory normally
Get-Process w3wp | Measure-Object -Property WorkingSet -Sum | 
  Select-Object @{Name="Total_MB";Expression={[math]::Round($_.Sum / 1MB, 2)}}
# Expected: 50–200 MB (normal) not > 500MB
```

**Expected Output on Recovery:**
```
Name    Status
----    ------
W3SVC   Running

✓ IIS responding to HTTP requests

Name               State
----               -----
DefaultAppPool     Started

✓ Reporting service operational
Total_MB: 85.3
```

---

### 7. RTO Target & SLA

| Metric | Target | Acceptance Criteria |
|--------|--------|-------------------|
| **Time to Detect** | < 30 seconds | Health check fails; alert triggered on HTTP 503 |
| **Time to Mitigate** | < 1 minute | Restart IIS service (manual or auto-restart) |
| **Time to Recovery** | < 2 minutes | IIS running, HTTP 200, reporting dashboards loading |
| **RTO (Total)** | **< 5 minutes** | Full service availability, no data loss |

---

### 8. Go/No-Go Checklist (Execute Before Test)

```powershell
# ✓ Verify IIS is currently running
Get-Service -Name W3SVC | Where-Object {$_.Status -eq 'Running'} | 
  Select-Object Name | ConvertTo-Json
# Expected: W3SVC

# ✓ Confirm HTTP endpoint responds
$health = Invoke-WebRequest -Uri "http://10.0.1.20/health" -UseBasicParsing -ErrorAction SilentlyContinue
if ($health.StatusCode -eq 200) { Write-Host "✓ HTTP health check OK" }

# ✓ Verify at least one app pool is running
$pools = Get-WebAppPool | Where-Object {$_.State -eq 'Started'} | Measure-Object
if ($pools.Count -gt 0) { Write-Host "✓ App pools running" }

# ✓ Check reporting endpoint is accessible
$report = Invoke-WebRequest -Uri "http://10.0.1.20/reports" -UseBasicParsing -ErrorAction SilentlyContinue
if ($report.StatusCode -eq 200) { Write-Host "✓ Reporting service accessible" }

# ✓ Baseline: Document current memory usage
Get-Process w3wp | Measure-Object -Property WorkingSet -Sum | 
  Select-Object @{Name="Baseline_MB";Expression={[math]::Round($_.Sum / 1MB, 2)}}
```

**Go/No-Go Decision:**
- ✓ **GO** if: IIS running, HTTP health check 200, app pools running, reporting accessible
- ⛔ **NO-GO** if: IIS already stopped, HTTP check failing, app pools stopped, reporting unreachable

---

## Master Test Execution Schedule

### Pre-Test (Day 0)
1. Snapshot current state of all VMs (disk, memory, connections)
2. Document baseline metrics (CPU load, network latency, DB connections)
3. Verify all monitoring dashboards are active and alerting configured
4. Ensure backup/snapshot of VMs exists (for recovery if test fails)

### Test Window (Day 1–5)
**Monday:** Scenario A (CPU Exhaustion) + B (DB Connection Pool)  
**Tuesday:** Scenario C (Disk Fill) + D (Network Routing)  
**Wednesday:** Scenario E (IIS Service Failure)  
**Thursday–Friday:** Remediation and sign-off

### Post-Test
1. Collect logs and monitoring data from all tests
2. Document actual RTO vs. target RTO
3. Create incident reports for any failures
4. Update runbooks with lessons learned

---

## Test Result Template

For each test, document:

```markdown
## Test Scenario [A/B/C/D/E]: [Name]

**Date/Time:** YYYY-MM-DD HH:MM UTC  
**Conducted By:** [Name]  
**Status:** ✓ PASS / ⚠ PARTIAL / ✗ FAIL

### Execution Summary
- **Failure Triggered:** [Time] (dd if=/dev/zero... / Stop-Service...)
- **Issue Detected:** [Time] + Alert name
- **Issue Resolved:** [Time]
- **Actual RTO:** [Minutes:Seconds]

### Metrics Captured
| Component | Baseline | During Test | After Recovery |
|-----------|----------|-------------|----------------|
| vm-app CPU | 5% | 95% | 8% |
| DB Connections | 3 | 18 | 2 |
| etc. | | | |

### Observations
- ✓ All recovery steps completed successfully
- ⚠ Alert took 2 min to trigger (target: 1 min)
- ✗ IIS restart failed; manual intervention required

### Remediation Actions
1. [Action 1] - Owner: [Name]
2. [Action 2] - Owner: [Name]

### Sign-Off
- **Test Lead:** ________________________ Date: _______
- **Infrastructure Owner:** _____________ Date: _______
```

---

## Safety & Rollback Guardrails

### Abort Conditions (Stop Test Immediately If)
- ✗ Any test exceeds RTO by >100% (e.g., RTO 5 min → no recovery after 10 min)
- ✗ Data loss detected (check database transaction logs, blob storage history)
- ✗ Service fails to restart after recovery command (indicates misconfiguration)
- ✗ Multiple VMs become unavailable (cascading failure)
- ✗ Network connectivity lost to Bastion (unable to access any VM)

### Rollback Procedures
If abort condition triggered:

```bash
# 1. Kill all test processes immediately
pkill -9 stress-ng dd psql
sudo pkill -9 stress-ng dd

# 2. Restore network connectivity (if NSG blocked)
az network nsg rule update --resource-group rg-ailab-sachinb \
  --nsg-name nsg-db --name AllowPostgres --access Allow

# 3. Check all services are running
systemctl is-active postgresql
systemctl is-active app
# (Windows)
Get-Service W3SVC, MSSQLSERVER | Select-Object Status

# 4. Remove test files
rm -f /tmp/disktest-large.bin /tmp/stress-* /tmp/disk-*

# 5. Restart Bastion if connectivity broken
az network bastion restart --resource-group rg-ailab-sachinb --name bastion-ailab

# 6. Restore from snapshot (if available)
# Manual via Azure Portal if automated recovery fails
```

---

## Monitoring & Observability Requirements

For test validity, ensure these monitoring channels are active:

### Azure Monitor Alerts (Recommended)
- CPU > 85% for 5 min → **Alert**
- Disk > 90% → **Alert**
- PostgreSQL connections > 18 → **Alert**
- HTTP 503 errors > 10/min → **Alert**
- Network NSG rule change → **Activity Log Alert**

### VM Guest Metrics
```bash
# Enable Azure Monitor Agent on each VM
az vm extension set --resource-group rg-ailab-sachinb --vm-name vm-app \
  --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor \
  --extension-type AzureMonitorLinuxAgent --no-wait
```

### Logging
- **vm-app:** Application logs in `/var/log/app/` or journalctl
- **vm-db:** PostgreSQL logs in `/var/log/postgresql/`
- **vm-win:** Event Viewer (System, Application, IIS logs)

---

## Success Criteria & Sign-Off

### Test Plan is Approved When:
- ✓ All 5 scenarios documented with exact commands
- ✓ Go/No-Go checks defined and verified before each test
- ✓ RTO targets achievable (recovery < 5 min confirmed in dry-run)
- ✓ No data loss in any scenario
- ✓ All recovery commands tested and validated
- ✓ Monitoring alerts configured and alerting correctly

### Test Execution Approved When:
- ✓ Actual RTO ≤ Target RTO for all 5 scenarios
- ✓ Zero data loss across all tests
- ✓ All recovery commands succeeded without manual intervention
- ✓ Monitoring alerts triggered within target window
- ✓ Test environment returned to baseline state post-test

### Sign-Off Signatures
```
Test Plan Approval:
Resilience Engineering Lead: _________________________ Date: ________
Infrastructure Owner:        _________________________ Date: ________

Test Execution Complete:
Test Conductor:              _________________________ Date: ________
Witness:                     _________________________ Date: ________
Infrastructure Owner:        _________________________ Date: ________
```

---

## Appendix A: Quick Reference Commands

### Access VMs (via Bastion)
```bash
# SSH to vm-app
ssh labadmin@10.0.1.10

# SSH to vm-db
ssh labadmin@10.0.2.10

# RDP to vm-win
mstsc /v:10.0.1.20
```

### Useful One-Liners
```bash
# Real-time disk monitoring
watch -n 1 'df -h /'

# Real-time CPU monitoring
watch -n 1 'top -bn1 | head -10'

# Monitor DB connections
watch -n 5 'sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"'

# Tail payment service logs
tail -f /var/log/app/error.log | grep -i 'error\|failed\|connection'

# Check network connectivity  
traceroute 10.0.2.10
netstat -tlnp | grep 5432
```

### PowerShell Quick Reference
```powershell
# List all processes
Get-Process | Select-Object Name, CPU, Memory

# Check service status
Get-Service W3SVC, MSSQLSERVER | Format-Table Name, Status

# Enable IIS features
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServer

# View Windows event logs
Get-EventLog -LogName System -Newest 10 | Format-Table
```

---

## Appendix B: Expected Baseline Metrics

| Metric | vm-app | vm-db | vm-win |
|--------|--------|-------|--------|
| **CPU Usage (Idle)** | 3–5% | 2–4% | 5–10% |
| **Memory Usage** | 1.5–2GB | 1–1.5GB | 3–4GB |
| **Disk Usage** | ~10GB (33%) | ~10GB (33%) | ~40GB (30%) |
| **Network Latency (to DB)** | 1–2ms | N/A | 1–2ms |
| **DB Connections** | 2–3 | 3–5 | 0 |
| **HTTP Response Time** | 80–120ms | N/A | 150–200ms |

---

**Document Version:** 1.0  
**Last Updated:** 2026-06-16  
**Next Review:** 2026-07-16  
**Classification:** Internal — Lab/Training
