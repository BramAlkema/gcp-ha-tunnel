# ADR-001: Automated GCP Tunnel & Google Assistant Setup for Home Assistant

**Status:** Proposed
**Date:** 2026-01-03
**Author:** Claude + Ynse

---

## Context

Setting up external HTTPS access and Google Assistant integration for self-hosted Home Assistant currently requires:

1. **Dynamic DNS** (DuckDNS, No-IP, etc.)
2. **SSL Certificate** (Let's Encrypt)
3. **Port Forwarding** on router (security concern, not always possible)
4. **Google Cloud Console** manual configuration (project, APIs, service account)
5. **Google Home Developer Console** manual configuration (OAuth, fulfillment URLs)
6. **Home Assistant YAML** configuration

This process takes 30-60 minutes, requires technical knowledge across multiple platforms, and exposes the home network via port forwarding.

### Problems with Current Approach

| Problem | Impact |
|---------|--------|
| Port forwarding required | Security risk, not possible on some networks (CGNAT) |
| Multiple manual console steps | Error-prone, time-consuming |
| No single automation solution | Each component configured separately |
| Nabu Casa alternative costs $6.50/mo | Not free |
| Cloudflare Tunnel requires owned domain | Additional cost/complexity |

---

## Decision

Build a HACS-compatible solution that automates the entire setup using:

1. **Google Cloud Run** as a serverless reverse proxy (free tier: 2M requests/mo)
2. **Chisel** as the WebSocket tunnel software
3. **gcloud CLI** for GCP resource provisioning
4. **gactions CLI** for Smart Home Action deployment
5. **Home Assistant Add-on** for the tunnel client

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   Internet                                       │
└───────────────────────┬─────────────────────────────────────────┘
                        │ HTTPS (443)
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│              Google Cloud Run (Free Tier)                        │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Container: chisel server                                │    │
│  │  URL: https://ha-tunnel-{id}.run.app                    │    │
│  │  - Managed HTTPS/TLS                                     │    │
│  │  - Auto-scaling (including to zero)                      │    │
│  │  - No infrastructure management                          │    │
│  └─────────────────────────────────────────────────────────┘    │
└───────────────────────┬─────────────────────────────────────────┘
                        │ WebSocket tunnel
                        │ (outbound connection from HA)
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│              Home Network (No port forward!)                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Home Assistant                                          │    │
│  │  ┌─────────────────────────────────────────────────┐    │    │
│  │  │  Add-on: gcp-tunnel-client                       │    │    │
│  │  │  - Chisel client                                 │    │    │
│  │  │  - Outbound WebSocket to Cloud Run               │    │    │
│  │  │  - Auto-reconnect on failure                     │    │    │
│  │  └─────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Component Selection

#### Tunnel Software: Chisel

| Evaluated | Pros | Cons | Decision |
|-----------|------|------|----------|
| **Chisel** | Go binary, simple, WebSocket, reverse proxy built-in | Less known than alternatives | ✅ Selected |
| frp | Feature-rich, popular | More complex config | ❌ |
| rathole | Rust, fast | Less mature | ❌ |
| bore | Simple | Limited features | ❌ |
| SSH tunnel | Universal | Requires SSH server | ❌ |

**Rationale:** Chisel is a single binary, supports WebSocket (works through Cloud Run), has built-in reverse proxy, and requires minimal configuration.

#### Cloud Platform: Google Cloud Run

| Evaluated | Pros | Cons | Decision |
|-----------|------|------|----------|
| **Cloud Run** | Free tier, serverless, managed HTTPS, *.run.app domain | Cold starts, 60min WebSocket timeout | ✅ Selected |
| GCP e2-micro VM | Always-on, no timeouts | Requires management | ❌ Alternative |
| AWS Lambda | Free tier | Complex for WebSocket | ❌ |
| Azure Container Apps | Similar to Cloud Run | Less familiar ecosystem | ❌ |

**Rationale:** Cloud Run provides free managed HTTPS with automatic domain (no DuckDNS needed), scales to zero (no cost when idle), and integrates well with other GCP services we're already using for Google Assistant.

### Automation Tools

| Task | Tool | Command |
|------|------|---------|
| GCP project creation | gcloud | `gcloud projects create` |
| API enablement | gcloud | `gcloud services enable` |
| Service account | gcloud | `gcloud iam service-accounts create` |
| Cloud Run deployment | gcloud | `gcloud run deploy` |
| Smart Home Action | gactions | `gactions push && gactions deploy` |

---

## Solution Components

### 1. Setup Script (MVP)

```bash
gcp-ha-setup.sh
├── Authenticates with GCP (gcloud auth login)
├── Authenticates with Actions (gactions login)
├── Creates GCP project
├── Enables APIs (HomeGraph, Cloud Run)
├── Creates service account
├── Deploys Cloud Run (chisel server)
├── Generates action.json
├── Pushes Smart Home Action (gactions push)
├── Deploys Action preview (gactions deploy preview)
├── Configures HA (configuration.yaml)
└── Outputs: "Link in Google Home app"
```

### 2. Home Assistant Add-on

```yaml
# config.yaml
name: GCP Tunnel Client
description: Chisel tunnel client for Google Cloud Run
arch: [aarch64, amd64, armv7]
startup: system
boot: auto
options:
  server_url: ""
  auth_user: ""
  auth_pass: ""
schema:
  server_url: url
  auth_user: str
  auth_pass: password
```

### 3. HACS Integration (Future)

```
custom_components/gcp_tunnel/
├── __init__.py
├── manifest.json
├── config_flow.py      # OAuth flow with Google
├── const.py
├── coordinator.py      # Manages Cloud Run deployment
└── sensor.py           # Tunnel status sensor
```

---

## File Structure

```
hacs-gcp-tunnel/
├── README.md
├── LICENSE
├── adr/
│   └── 001-gcp-tunnel-google-assistant-automation.md
├── scripts/
│   ├── gcp-ha-setup.sh           # Main setup script
│   ├── action.template.json       # Smart Home Action template
│   └── requirements.txt           # gcloud, gactions
├── addon/
│   ├── config.yaml
│   ├── Dockerfile
│   ├── run.sh
│   └── CHANGELOG.md
├── cloud-run/
│   ├── Dockerfile                 # Chisel server image
│   └── cloudbuild.yaml
└── custom_components/             # Future HACS integration
    └── gcp_tunnel/
```

---

## Cost Analysis

### Google Cloud Free Tier Limits

| Resource | Free Allowance | Expected HA Usage | Fits Free Tier? |
|----------|---------------|-------------------|-----------------|
| Cloud Run requests | 2M/month | ~50K/month | ✅ Yes |
| Cloud Run CPU | 180K vCPU-sec | ~10K vCPU-sec | ✅ Yes |
| Cloud Run memory | 360K GB-sec | ~20K GB-sec | ✅ Yes |
| Cloud Run egress | 1 GB | ~500 MB | ✅ Yes |
| HomeGraph API | Free | Unlimited | ✅ Yes |

**Estimated monthly cost: $0.00** (within free tier)

### Comparison with Alternatives

| Solution | Monthly Cost | Port Forward? | Complexity |
|----------|-------------|---------------|------------|
| **This solution** | $0 | No | Low (automated) |
| Nabu Casa | $6.50 | No | None |
| DuckDNS + LE | $0 | **Yes** | Medium |
| Cloudflare Tunnel | $0 | No | Medium |
| Self-hosted VPN | $0 | Yes (VPN port) | High |

---

## Security Considerations

### Strengths

1. **No port forwarding** - Home network not directly exposed
2. **Outbound-only connections** - HA initiates tunnel, no inbound rules needed
3. **TLS encryption** - Cloud Run provides managed HTTPS
4. **Chisel auth** - Username/password authentication on tunnel
5. **Google OAuth** - Standard OAuth 2.0 for Google Assistant linking

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Cloud Run compromise | Low | High | Google manages infrastructure security |
| Chisel auth bypass | Low | High | Use strong random credentials |
| GCP account compromise | Low | High | Enable 2FA, use service accounts |
| Tunnel credential leak | Medium | Medium | Store in HA secrets, rotate periodically |
| Cold start latency | High | Low | Acceptable for Google Assistant use |

---

## Trade-offs

### Accepted Trade-offs

1. **Cold starts (2-5s delay)** - Cloud Run scales to zero; first request after idle period has latency. Acceptable for Google Assistant commands.

2. **WebSocket timeout (60 min max)** - Cloud Run terminates WebSocket after 60 min. Chisel client auto-reconnects. During reconnect (~2-5s), requests fail. Practical impact: ~1.7% failure rate if unlucky timing. Accepted as "good enough" for home use.

3. **Google Cloud dependency** - Tied to GCP. Acceptable since we're already using Google for Assistant integration.

4. **CLI tools required** - User must have gcloud and gactions installed. Acceptable for MVP; future HACS integration can use APIs directly.

5. **Free tier not guaranteed forever** - GCP could change pricing. Cloud Run's usage-based model is more stable than VM free tier. Worst case: ~$1-3/month for typical HA usage.

### Rejected Alternatives

1. **Ngrok** - Paid for custom domains, not self-hosted
2. **Tailscale Funnel** - Requires Tailscale account, additional dependency
3. **Cloudflare Tunnel** - Requires owned domain or trycloudflare.com (not permanent)
4. **GCP VM** - Always-on costs, requires management

---

## Implementation Plan

### Phase 1: MVP Script (1-2 days)
- [ ] Create `gcp-ha-setup.sh` script
- [ ] Create `action.template.json`
- [ ] Build and publish chisel server Docker image
- [ ] Test end-to-end on real HA instance
- [ ] Document manual steps (Google Home app linking)

### Phase 2: HA Add-on (1-2 days)
- [ ] Create add-on repository structure
- [ ] Build chisel client Docker image
- [ ] Add-on configuration schema
- [ ] Auto-reconnect logic
- [ ] Health check endpoint

### Phase 3: HACS Integration (future)
- [ ] Python integration with config flow
- [ ] OAuth flow with Google
- [ ] Direct API calls (replace CLI)
- [ ] Status sensors
- [ ] Automatic add-on installation

---

## Success Criteria

1. **Zero port forwarding** - Setup works without any router configuration
2. **< 5 minutes setup** - Excluding OAuth login and Google Home app linking
3. **$0 monthly cost** - Stay within GCP free tier
4. **Auto-recovery** - Tunnel reconnects automatically after failure
5. **Works with Google Assistant** - Voice commands functional

---

## Open Questions

1. **Cloud Run region** - Which region minimizes latency for Google Assistant?
2. **Chisel vs frp** - Should we support both tunnel options?
3. **Custom domains** - Should we support user's own domain on Cloud Run?
4. **Multi-user** - Can multiple HA instances share one Cloud Run service?

---

## References

- [Google Cloud Run Pricing](https://cloud.google.com/run/pricing)
- [Chisel GitHub](https://github.com/jpillora/chisel)
- [gactions CLI Guide](https://developers.google.com/assistant/actionssdk/gactions/guide)
- [Home Assistant Google Assistant Docs](https://www.home-assistant.io/integrations/google_assistant/)
- [Awesome Tunneling](https://github.com/anderspitman/awesome-tunneling)

---

## Decision

**We will build an automated GCP-based tunnel solution** using Cloud Run + Chisel, with gcloud/gactions CLI automation, packaged as a setup script (MVP) and later as a HACS add-on/integration.

This provides:
- Free external HTTPS access without port forwarding
- Fully automated Google Assistant setup (except final app linking)
- Zero ongoing cost within GCP free tier
- Simple user experience compared to manual setup
