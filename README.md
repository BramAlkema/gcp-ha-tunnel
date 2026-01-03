# GCP Tunnel for Home Assistant

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FBramAlkema%2Fgcp-ha-tunnel)

Secure tunnel to Google Cloud Run for external Home Assistant access. No port forwarding required.

## Features

- **Free** - Uses Google Cloud Run free tier
- **Secure** - All traffic over HTTPS/WSS
- **No port forwarding** - Works behind CGNAT, firewalls
- **Google Assistant** - Enables Google Home integration
- **Auto-reconnect** - Exponential backoff on disconnect

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Google Home /  │────▶│   Cloud Run     │────▶│ Home Assistant  │
│  External User  │     │  (nginx+chisel) │     │  (this add-on)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        HTTPS              WebSocket              localhost:8123
```

## Installation

### Add Repository to Home Assistant

Click the button above, or manually:

1. Go to **Settings** → **Add-ons** → **Add-on Store**
2. Click ⋮ (menu) → **Repositories**
3. Add: `https://github.com/BramAlkema/gcp-ha-tunnel`
4. Click **Add** → **Close**
5. Refresh the page
6. Find **GCP Tunnel Client** and click **Install**

### Deploy Cloud Run Server

```bash
# Clone this repo
git clone https://github.com/BramAlkema/gcp-ha-tunnel
cd gcp-ha-tunnel

# Run setup (requires gcloud CLI)
./scripts/gcp-ha-setup.sh
```

This outputs `tunnel_config.env` with your credentials.

### Configure Add-on

```yaml
server_url: "https://ha-tunnel-xxxxx.us-central1.run.app"
auth_user: "hauser"
auth_pass: "your-generated-password"
local_port: 8123
keepalive: "25s"
log_level: "info"
```

### Start

Click **Start** and check logs for `Connected`.

## Google Assistant Setup

Full guide: [actions-config/SETUP.md](actions-config/SETUP.md)

**Google Home Developer Console URLs:**
```
Create project:     https://console.home.google.com/projects/create
Company profile:    https://console.home.google.com/projects/<slug>/company-profile
Integration setup:  https://console.home.google.com/projects/<slug>/cloud-to-cloud/setup
Testing:            https://console.home.google.com/projects/<slug>/cloud-to-cloud/test
```

**OAuth Configuration:**
```
Fulfillment URL:  https://YOUR-CLOUD-RUN-URL/api/google_assistant
Auth URL:         https://YOUR-CLOUD-RUN-URL/auth/authorize
Token URL:        https://YOUR-CLOUD-RUN-URL/auth/token
Client ID:        https://oauth-redirect.googleusercontent.com/r/YOUR-GCP-PROJECT-ID
```

## Add-ons

| Add-on | Description |
|--------|-------------|
| [GCP Tunnel Client](gcp-tunnel-client/) | Chisel client connecting to Cloud Run |

## Repository Structure

```
gcp-ha-tunnel/
├── gcp-tunnel-client/     # Home Assistant add-on
│   ├── config.yaml
│   ├── Dockerfile
│   ├── run.sh
│   └── DOCS.md
├── cloud-run/             # Cloud Run server files
│   ├── Dockerfile
│   ├── nginx.conf
│   └── static/            # Privacy policy, logos
├── scripts/
│   └── gcp-ha-setup.sh    # Automated deployment
├── actions-config/
│   └── SETUP.md           # Google Home setup guide
└── adr/
    └── 001-*.md           # Architecture decisions
```

## Costs

Typical usage stays within GCP free tier:

| Resource | Free Tier | Typical Usage |
|----------|-----------|---------------|
| Requests | 2M/month | ~50K/month |
| CPU | 180K vCPU-sec | ~10K vCPU-sec |
| Egress | 1 GB | ~500 MB |

**Expected cost: $0/month**

## Limitations

- **60-min WebSocket timeout** - Auto-reconnects (brief interruption)
- **Cold starts** - 2-5s delay after idle period
- **Single region** - Deploy closest to your location

## Troubleshooting

### Tunnel won't connect
- Check add-on logs in HA
- Verify Cloud Run is running: `curl https://YOUR-URL/health`

### Google Assistant errors
- Ensure tunnel is connected
- Check HA logs for `google_assistant` errors
- Re-link in Google Home app

## License

MIT
