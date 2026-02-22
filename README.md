# TrueNAS ACME DNS Authenticator – IONOS

Authenticates ACME DNS-01 challenges for TrueNAS Scale using the IONOS DNS API.  
Enables TrueNAS Scale to use IONOS as an ACME DNS authenticator for automated SSL certificate renewal via Let's Encrypt.

---

## Requirements

| Dependency | Purpose |
|------------|---------|
| `bash` | Script runtime |
| `curl` | IONOS API communication |
| `jq` | JSON parsing |
| `dig` | DNS propagation verification |

---

## Configuration

Before using the script, set your IONOS API key inside the script:

```bash
readonly IONOS_API_AUTHORIZATION_KEY="your-public-key.your-secret-key"
```

You can find your API key in the [IONOS Developer Portal](https://developer.hosting.ionos.com).

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `IONOS_API_TXT_RECORD_TTL` | `60` | TTL for the TXT record in seconds |
| `SCRIPT_DNS_PROPAGATION_TIMEOUT` | `120` | Maximum wait time for DNS propagation in seconds |
| `SCRIPT_DNS_POLL_INTERVAL` | `10` | Interval between DNS propagation checks in seconds |

---

## Installation

1. Copy the script to a **persistent dataset** on your TrueNAS system:
```bash
/mnt/yourpool/scripts/acme-ionos-authenticator.sh
```

2. Make the script executable:
```bash
chmod +x /mnt/yourpool/scripts/acme-ionos-authenticator.sh
```

3. Set your IONOS API key in the script.

---

## TrueNAS Setup

1. Navigate to **Credentials → Certificates → ACME DNS Authenticators**
2. Click **Add**
3. Select **Shell Script** as the authenticator type
4. Enter the full path to the script:
```
/mnt/yourpool/scripts/acme-ionos-authenticator.sh
```
5. Save and use the authenticator when creating an ACME certificate

---

## How It Works

The script implements the ACME DNS-01 challenge protocol:

```
TrueNAS → script set   → creates _acme-challenge TXT record via IONOS API
                       → waits for DNS propagation
                       → Let's Encrypt validates the TXT record
                       → certificate is issued

TrueNAS → script unset → removes _acme-challenge TXT record via IONOS API
```

### Parameters passed by TrueNAS

| Parameter | Description |
|-----------|-------------|
| `$1` | Action: `set` or `unset` |
| `$2` | Domain name (e.g. `nas.example.com`) |
| `$3` | Full ACME record name (e.g. `_acme-challenge.nas.example.com`) |
| `$4` | ACME validation token (TXT record value) |

---

## Logging

The script writes logs to:
```
/tmp/TrueNAS-ACME-DNS-Authentication-IONOS.log
```

Log format:
```
[2026-02-22 14:00:00] [INFO]  ACME IONOS Authenticator started
[2026-02-22 14:00:01] [INFO]  DNS-Zone found that matches domain provided by certbot
[2026-02-22 14:00:02] [INFO]  ACME-DNS-Record successfully created
[2026-02-22 14:00:12] [INFO]  Certbot DNS-Validation successful
[2026-02-22 14:00:12] [INFO]  Deployment: Successful
```

---

## API Reference

This script uses the [IONOS DNS API v1](https://developer.hosting.ionos.com/docs/dns).

---

## License

```
Copyright 2026 TheGreatMisconception

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
