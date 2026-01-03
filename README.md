# GCP Tunnel for Home Assistant

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FBramAlkema%2Fgcp-ha-tunnel)

Secure tunnel to Google Cloud Run for external Home Assistant access. No port forwarding required.

## Why Use This?

| Method | Cost | Port Forward | Complexity |
|--------|------|--------------|------------|
| Nabu Casa | $6.50/mo | No | Zero |
| DuckDNS | Free | **Yes** | Medium |
| **This** | Free* | **No** | Medium |

*Free tier covers typical home use

**Best for:** CGNAT, apartments, corporate networks - anywhere port forwarding isn't possible.

## How It Works

```
Google Assistant  →  Cloud Run (free)  →  Tunnel  →  Home Assistant
                         ↑                   ↑
                    Public HTTPS        chisel WebSocket
```

Uses [Home Assistant's built-in Google Assistant integration](https://www.home-assistant.io/integrations/google_assistant/) - we just provide the network path.

## Quick Start

### 1. Install Add-on

Click the badge above, or:
1. **Settings** → **Add-ons** → **Add-on Store** → ⋮ → **Repositories**
2. Add: `https://github.com/BramAlkema/gcp-ha-tunnel`
3. Install **GCP Tunnel Client**

### 2. Setup via Web UI

1. Open the **GCP Tunnel** panel in Home Assistant sidebar
2. Follow the 3-step wizard:
   - Create GCP project + service account
   - Upload service account key
   - Click **Deploy** → tunnel auto-deploys

### 3. Connect Google Assistant

After deploy, the UI shows exact URLs to paste into [Google Actions Console](https://console.actions.google.com):

```
Fulfillment URL:   https://YOUR-URL/api/google_assistant
Authorization URL: https://YOUR-URL/auth/authorize
Token URL:         https://YOUR-URL/auth/token
Client ID:         https://oauth-redirect.googleusercontent.com/r/YOUR-PROJECT
```

### 4. Link in Google Home

Google Home app → + → **Set up device** → **Works with Google** → Search `[test] your-project`

## Features

- **One-click deploy** - Web UI deploys Cloud Run automatically
- **Auto-config** - Configures HA's google_assistant integration
- **Report state** - Push updates to Google (via HA's built-in batching)
- **Health endpoint** - `/health` for monitoring
- **Auto-reconnect** - Exponential backoff on disconnect

## Architecture

```
gcp-ha-tunnel/
├── gcp-tunnel-client/     # HA Add-on
│   ├── webapp/            # Setup wizard UI
│   ├── run.sh             # Tunnel + HA config
│   └── nginx.conf         # HTTP→HTTPS proxy
├── cloud-run/             # Tunnel server
│   ├── nginx.conf         # Routing + OAuth fixes
│   └── static/            # Privacy policy
└── .github/workflows/     # Builds tunnel-server image
```

## Costs

| Resource | Free Tier | Your Usage |
|----------|-----------|------------|
| Requests | 2M/month | ~50K |
| CPU | 180K vCPU-sec | ~10K |
| Memory | 360K GiB-sec | ~50K |

**Expected: $0/month**

## Health Endpoint

```bash
curl http://homeassistant.local:8099/health
```

Returns:
```json
{
  "status": "healthy",
  "tunnel_connected": true,
  "proxy_running": true,
  "report_state_enabled": true
}
```

## Troubleshooting

**Tunnel won't connect:**
- Check add-on logs
- Verify Cloud Run: `curl https://YOUR-URL/health`
- Check auth credentials match

**Google Assistant errors:**
- Ensure tunnel shows "Connected" in logs
- Re-link account in Google Home app
- Check HA logs for `google_assistant` errors

**Report state not working:**
- Upload service account key via web UI
- Restart add-on after upload
- Check HA logs for HomeGraph errors

## License

MIT
