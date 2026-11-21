# WiFi-Pumpkin3 Captive Portal — Development, Verification and Deployment Guide

## 1. Purpose

This document describes the standard procedure for modifying, testing and deploying the customized WiFi-Pumpkin3 (WP3) captive portal on Kali Linux.

The key principle is:

**Always develop and verify the candidate first. Never directly modify the live portal application.**

## 2. Directory Structure

Working directory: `~/wifipumpkin3`

```text
wifipumpkin3/
├── wp3-portal.py              # Live/deployed portal application
├── wp3-portal.py.new          # Candidate application for modifications
├── wp3-portal-verify.py       # Offline verification script
├── portal/
│   ├── config/
│   │   └── portal.ini        # Portal branding and configuration
│   ├── templates/
│   │   ├── login.html        # Captive portal login page
│   │   └── success.html      # Successful authorization page
│   └── static/
│       ├── style.css         # Portal styling
│       └── images/           # Optional branding images
└── backups/
    └── portal/               # Previous application backups
```

## 3. Purpose of Each File

| File | Responsibility |
|---|---|
| `wp3-portal.py.new` | Candidate application; all Python application changes start here |
| `wp3-portal.py` | Live application launched by WP3 |
| `wp3-portal-verify.py` | Offline verification of the candidate and portal components |
| `portal.ini` | Branding, page text and appearance settings |
| `login.html` | Login page structure and content |
| `success.html` | Successful authorization page structure |
| `style.css` | Layout, colors, typography and responsive styling |

## 4. Development Workflow

### Step 1 — Modify the candidate

Make Python application changes in:

```text
wp3-portal.py.new
```

Make page-content changes in:

```text
portal/templates/login.html
portal/templates/success.html
```

Make styling changes in:

```text
portal/static/style.css
```

Make branding or configuration changes in:

```text
portal/config/portal.ini
```

Do not directly modify `wp3-portal.py`.

### Step 2 — Run offline verification

From the project directory:

```bash
cd ~/wifipumpkin3
sudo python3 wp3-portal-verify.py
```

The verification script uses:

```python
APP_FILE = BASE_DIR / "wp3-portal.py.new"
```

This ensures that the candidate application is tested rather than the live application.

The script performs offline checks, including:

- Python syntax validation.
- Candidate application and configuration loading.
- Login and success template loading.
- Login page rendering.
- Login form and CSRF field presence.
- Stylesheet delivery.
- Invalid CSRF rejection.
- Captive portal probe redirect.
- External client subnet rejection.
- Gateway address rejection.
- Success page rendering.

Expected final message:

```text
All verification checks passed.
Offline test only: no client was authorized.
```

A failed check must be investigated and corrected before deployment.

**Important:** Offline verification does not replace testing with a real client device. It does not authorize a client or prove that the complete wireless connection and internet-access flow works.

## 5. Deployment Workflow

Deploy only after all verification checks pass.

### Step 1 — Back up the current live application

Create a timestamped backup of:

```text
wp3-portal.py
```

Store it under:

```text
backups/portal/
```

### Step 2 — Stop WP3

Use the existing stop procedure:

```bash
sudo ./wp3-stop.sh
```

Confirm that the old portal process has stopped before replacing the live application.

### Step 3 — Copy the verified candidate

Deploy the candidate:

```text
wp3-portal.py.new
```

to the live application filename:

```text
wp3-portal.py
```

Preserve the required ownership and executable permissions.

### Step 4 — Verify the deployed files

Compare the candidate and deployed application checksums:

```bash
sha256sum wp3-portal.py.new wp3-portal.py
```

The SHA256 values must match.

### Step 5 — Start WP3

Use the existing startup procedure:

```bash
sudo ./wp3-start.sh
```

The startup script continues to launch:

```text
/home/kali/wifipumpkin3/wp3-portal.py
```

There is no need to change the startup script when updating the candidate.

## 6. Post-Deployment Validation

After startup, verify:

1. The portal process is running.
2. A test client can connect to the authorized test AP.
3. The captive portal login page opens.
4. Branding, text and CSS display correctly.
5. The Accept and Continue action works.
6. The success page displays correctly.
7. The expected authorization and network-access behavior works.

Check portal logs if needed:

```bash
sudo tail -50 /var/log/wp3/portal.log
```

## 7. Rollback Procedure

If the new deployment fails:

1. Stop WP3 using `sudo ./wp3-stop.sh`.
2. Restore the previous known-good backup from `backups/portal/`.
3. Restore the required ownership and permissions.
4. Start WP3 using `sudo ./wp3-start.sh`.
5. Verify the portal process and client connectivity.

Never delete the previous working backup immediately after deployment.

## 8. Important Operational Rules

- `wp3-portal.py.new` is the development and verification source.
- `wp3-portal.py` is the deployed application.
- Always run verification before copying the candidate.
- Do not deploy if any verification check fails.
- Back up the live application before every deployment.
- Compare SHA256 checksums after copying.
- Keep the existing WP3 startup and stop scripts unchanged unless a separate requirement demands modification.
- Do not treat offline tests as proof of successful real-device authorization.
- Preserve the existing network isolation, client restrictions, CSRF protection and authorization logic.

## 9. Standard Update Sequence

The normal update lifecycle is:

```text
Modify candidate and portal assets
              |
              v
Run offline verification
              |
              v
All checks pass?
       /           \
     No             Yes
     |               |
Fix and retest       v
              Back up live app
                      |
                      v
                 Stop WP3
                      |
                      v
       Copy .new to wp3-portal.py
                      |
                      v
              Compare SHA256
                      |
                      v
                  Start WP3
                      |
                      v
           Test with a real client
```

**Final rule: Develop in `.new` → Verify `.new` → Back up live file → Deploy `.new` → Start and validate WP3.**
