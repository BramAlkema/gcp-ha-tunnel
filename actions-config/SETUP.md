# Google Home Integration Setup Guide

**Time estimate: 20-30 minutes** (Google requires company profile, branding, OAuth config)

## URLs Reference

| Purpose | URL |
|---------|-----|
| **Create project** | https://console.home.google.com/projects/create |
| **Company profile** | https://console.home.google.com/projects/`<slug>`/company-profile |
| **Integration setup** | https://console.home.google.com/projects/`<slug>`/cloud-to-cloud/setup |
| **Testing** | https://console.home.google.com/projects/`<slug>`/cloud-to-cloud/test |
| **Docs (reference)** | https://developers.home.google.com |

> Replace `<slug>` with your project slug (e.g., `ha-smarthome-1`)

---

## Prerequisites

Before starting, ensure you have:

- [ ] GCP Project with HomeGraph API enabled (`ha-smarthome-436059`)
- [ ] Cloud Run tunnel deployed and working
- [ ] Service account JSON file for Home Assistant
- [ ] SSH or File Editor access to Home Assistant

**Your tunnel URLs:**
```
Tunnel Base:    https://ha-tunnel-725587046244.us-central1.run.app
Privacy Policy: https://ha-tunnel-725587046244.us-central1.run.app/privacy
Logo 192px:     https://ha-tunnel-725587046244.us-central1.run.app/static/logo-192.png
Logo 144px:     https://ha-tunnel-725587046244.us-central1.run.app/static/logo-144.png
```

---

## Part 1: Google Home Developer Console

### Step 1: Create Project

1. Go to https://console.home.google.com/projects/create
2. Click **Create new project**
3. Enter project name (e.g., `Home Assistant`)
4. Click **Create**

### Step 2: Complete Company Profile

Before adding integrations, you must complete the Company Profile.

1. Go to **Project home** → **Project Details**
2. Click **Submit profile** on the Company Profile card
3. Fill in:

| Field | Value |
|-------|-------|
| Company name | Your name or company |
| Company website | Your domain or the tunnel URL |
| Company logo (192x192) | Download from tunnel: `curl -o logo.png https://ha-tunnel-725587046244.us-central1.run.app/static/logo-192.png` |
| Privacy policy URL | `https://ha-tunnel-725587046244.us-central1.run.app/privacy` |
| Address | Your address |
| Developer contact | Your name + email |
| Marketing contact | Same as developer |
| Business contact | Same as developer |

4. Click **Submit**

> Note: Full review only happens when publishing. For personal use, minimal info is fine.

### Step 3: Add Cloud-to-Cloud Integration

1. Go to **Project home**
2. Under **Cloud-to-cloud**, click **Add cloud-to-cloud integration**
3. You'll be redirected to the setup page

### Step 4: Configure Integration

URL: `https://console.home.google.com/projects/<your-project>/cloud-to-cloud/setup`

Fill in these fields:

**Basic Info:**
| Field | Value |
|-------|-------|
| Integration name | `Home Assistant` |
| Device type | Select all you need (Light, Switch, Thermostat, etc.) |

**App Branding:**
| Field | Value |
|-------|-------|
| App icon (144x144) | Download: `curl -o <YOUR-PROJECT-SLUG>.png https://ha-tunnel-725587046244.us-central1.run.app/static/logo-144.png` |

> Icon filename must match your project slug (e.g., `ha-smarthome-1.png`)

**Account Linking (OAuth):**
| Field | Value |
|-------|-------|
| OAuth Client ID | `https://oauth-redirect.googleusercontent.com/r/ha-smarthome-436059` |
| Client secret | `homeassistant` (any string without special chars) |
| Authorization URL | `https://ha-tunnel-725587046244.us-central1.run.app/auth/authorize` |
| Token URL | `https://ha-tunnel-725587046244.us-central1.run.app/auth/token` |

**Cloud Fulfillment:**
| Field | Value |
|-------|-------|
| Fulfillment URL | `https://ha-tunnel-725587046244.us-central1.run.app/api/google_assistant` |

**Leave empty:**
- Local fulfillment
- App Flip
- Scopes

Click **Save**

### Step 5: Enable Testing

1. Go to **Test** in the left sidebar
2. Enable testing on your account
3. Your integration will appear as `[test] Home Assistant` in the Google Home app

---

## Part 2: Home Assistant Configuration

### Step 1: Install Tunnel Add-on

**Option A: Copy via SSH**
```bash
# From your computer
scp -r /path/to/addon root@homeassistant.local:/addons/gcp-tunnel
```

**Option B: Local Add-on Repository**
1. Copy the `addon` folder to `/config/addons/gcp-tunnel` on HA
2. Go to **Settings** → **Add-ons** → **Add-on Store**
3. Click ⋮ → **Check for updates**
4. The add-on should appear under "Local add-ons"

### Step 2: Configure Tunnel Add-on

In the add-on configuration:

```yaml
server_url: "https://ha-tunnel-725587046244.us-central1.run.app"
auth_user: "hauser"
auth_pass: "2WNgCxHnchsHiS8vWyFl9LvAtIpagEKV"
local_port: 8123
keepalive: "25s"
log_level: "info"
```

### Step 3: Add Service Account JSON

1. Copy `SERVICE_ACCOUNT.json` to your HA config folder (`/config/`)
2. Ensure it's readable

### Step 4: Configure google_assistant

Add to `configuration.yaml`:

```yaml
google_assistant:
  project_id: ha-smarthome-436059
  service_account: !include SERVICE_ACCOUNT.json
  report_state: true
  expose_by_default: false
  exposed_domains:
    - light
    - switch
    - climate
    - cover
    - fan
    - lock
  entity_config:
    # Optional: customize specific entities
    light.living_room:
      name: "Living Room Light"
      room: "Living Room"
```

### Step 5: Restart Home Assistant

```bash
ha core restart
```

### Step 6: Start Tunnel Add-on

1. Go to **Settings** → **Add-ons**
2. Click on **GCP Tunnel Client**
3. Click **Start**
4. Check logs to confirm connection

---

## Part 3: Link in Google Home App

1. Open **Google Home** app on your phone
2. Tap **+** → **Set up device** → **Works with Google**
3. Search for `[test] Home Assistant`
4. Tap it and sign in with your **Home Assistant** credentials
5. Your devices should appear

---

## Troubleshooting

### "Could not reach Home Assistant"
- Check tunnel add-on is running and connected
- Verify fulfillment URL is correct
- Test: `curl https://ha-tunnel-725587046244.us-central1.run.app/health`

### Account linking fails
- Ensure Authorization URL and Token URL are correct
- Check HA logs for OAuth errors
- Known issue: [GitHub #156583](https://github.com/home-assistant/core/issues/156583)

### Devices not appearing
- Check `exposed_domains` in config
- Verify entities aren't hidden
- Force sync: Developer Tools → Services → `google_assistant.request_sync`

### Tunnel disconnects
- Check add-on logs
- Verify Cloud Run service is running
- Tunnel auto-reconnects with exponential backoff

---

## Quick Reference

```
# Cloud Run Tunnel
Health:       https://ha-tunnel-725587046244.us-central1.run.app/health
Privacy:      https://ha-tunnel-725587046244.us-central1.run.app/privacy

# OAuth URLs
Fulfillment:  https://ha-tunnel-725587046244.us-central1.run.app/api/google_assistant
Auth URL:     https://ha-tunnel-725587046244.us-central1.run.app/auth/authorize
Token URL:    https://ha-tunnel-725587046244.us-central1.run.app/auth/token
Client ID:    https://oauth-redirect.googleusercontent.com/r/ha-smarthome-436059

# Tunnel Credentials
User:         hauser
Pass:         <see tunnel_config.env>
```
