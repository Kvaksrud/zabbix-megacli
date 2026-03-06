# MegaCLI RAID Monitoring for Zabbix

Bash-based MegaCLI RAID monitoring with Zabbix integration. Includes a standalone health check script, a Zabbix agent integration script with LLD (Low-Level Discovery), a Zabbix template, and UserParameter config.

## Components

| File | Description |
|------|-------------|
| `raid_health_check.sh` | Standalone RAID health check with colored terminal output |
| `zabbix_megacli.sh` | Zabbix integration script (cache, discovery, getters) |
| `userparameter_megacli.conf` | Zabbix agent UserParameter config |
| `megacli_raid_template.yaml` | Zabbix 7.0 template (adapters, VDs, PDs, BBU) |

## What Gets Monitored

- **Adapters** — degraded/offline VDs, critical/failed disks, ROC temperature, memory errors
- **Virtual Drives** — state (Optimal/Degraded/Offline), cache policy, RAID level
- **Physical Disks** — firmware state, media/other errors, predictive failures, SMART alerts, temperature
- **BBU** — battery state, temperature, voltage, capacitance, replacement flags

## Install on Ubuntu 24.04

### 1. Download and Install MegaCLI

MegaCLI is not in the Ubuntu repos. Broadcom ships it as an RPM, so use `alien` to convert it to a `.deb`:

```bash
# Install alien
sudo apt-get update
sudo apt-get install -y alien unzip

# Download MegaCLI
wget https://docs.broadcom.com/docs-and-downloads/raid-controllers/raid-controllers-common-files/8-07-14_MegaCLI.zip

# Extract
unzip 8-07-14_MegaCLI.zip
cd Linux/

# Convert the RPM to a .deb and install (ships MegaCli64 to /opt/MegaRAID/MegaCli/)
sudo alien -i MegaCli-8.07.14-1.noarch.rpm
```

> **Note:** If the Broadcom link is unavailable, search for `MegaCLI_8.07.14` on the
> [Broadcom support portal](https://www.broadcom.com/support/download-search) or check
> if your server vendor (Dell, Supermicro, etc.) provides it in their downloads section.

### 2. Fix Libraries and Create Symlinks

Ubuntu 24.04 ships libncurses 6 but MegaCLI needs libncurses 5. Create compatibility symlinks:

```bash
sudo ln -sf /lib/x86_64-linux-gnu/libncurses.so.6 /lib/x86_64-linux-gnu/libncurses.so.5
sudo ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6 /lib/x86_64-linux-gnu/libtinfo.so.5

# Symlink the binary into PATH:
sudo ln -sf /opt/MegaRAID/MegaCli/MegaCli64 /usr/local/bin/megacli
```

Verify it works:

```bash
sudo megacli -AdpCount -NoLog
```

### 3. Install the Scripts

```bash
sudo cp zabbix_megacli.sh /usr/local/bin/zabbix_megacli.sh
sudo chmod 755 /usr/local/bin/zabbix_megacli.sh

# Optional: install the standalone health check
sudo cp raid_health_check.sh /usr/local/bin/raid_health_check.sh
sudo chmod 755 /usr/local/bin/raid_health_check.sh
```

### 4. Configure Sudo for Zabbix Agent

The Zabbix agent needs passwordless sudo to run MegaCLI. Create a sudoers rule:

```bash
echo 'zabbix ALL=(ALL) NOPASSWD: /opt/MegaRAID/MegaCli/MegaCli64' | sudo tee /etc/sudoers.d/zabbix_megacli
sudo chmod 440 /etc/sudoers.d/zabbix_megacli
```

### 5. Set Up the Cache Cron Job

The Zabbix script reads from a cache to avoid running MegaCLI on every poll. Set up a cron job to refresh it:

```bash
echo '*/5 * * * * root /usr/local/bin/zabbix_megacli.sh cache' | sudo tee /etc/cron.d/zabbix_megacli
```

Prime the cache manually the first time:

```bash
sudo /usr/local/bin/zabbix_megacli.sh cache
```

### 6. Install the Zabbix UserParameter Config

```bash
# For Zabbix Agent 2:
sudo cp userparameter_megacli.conf /etc/zabbix/zabbix_agent2.d/userparameter_megacli.conf

# For legacy Zabbix Agent:
# sudo cp userparameter_megacli.conf /etc/zabbix/zabbix_agentd.d/userparameter_megacli.conf

sudo systemctl restart zabbix-agent2
```

### 7. Import the Zabbix Template

Import `megacli_raid_template.yaml` into your Zabbix server:

1. Go to **Data collection > Templates**
2. Click **Import**
3. Select `megacli_raid_template.yaml`
4. Apply the template to your hosts

## Standalone Health Check

Run the health check directly for a quick terminal overview:

```bash
sudo raid_health_check.sh
```

Exit codes: `0` = healthy, `1` = warnings, `2` = critical issues.

## Troubleshooting

- **"Cache not found"** — Run `sudo /usr/local/bin/zabbix_megacli.sh cache` and check cron is active
- **"Cache stale"** — Cache is older than 10 minutes; check cron job and MegaCLI access
- **"Controller Count: 0"** — MegaCLI can't access the controller; ensure you're running as root/sudo
- **libncurses errors** — Make sure the `.5` to `.6` symlinks are in place (see step 1)

## License

MIT
