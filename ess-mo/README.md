# Servy Full-Stack Deployment Manager

Automates installing the ESS MO app (Vue frontend, FastAPI backend, Caddy proxy, Cloudflare tunnel) as Windows services via [Servy](https://github.com/servy-community/servy).

## Quick start

```powershell
# pwd to file path first
.\deploy.ps1
```

```powershell
# Run as Administrator — replace the path with your actual deploy.ps1 location
powershell -ExecutionPolicy Bypass -File "filepath\deploy.ps1"
```

At startup you'll be asked:
1. **Install drive** — pick any available drive (e.g. `C:`, `D:`, `E:`)
2. **Caddy port** — port the reverse proxy listens on (default `8089`, change if you need a specific port)
3. **Public URL** — the URL users access the app at (default `http://localhost:8089`; change to your domain or Cloudflare tunnel for production)
4. **DB / SMTP credentials** — prompted once, saved to `deploy.secrets.json`

Then the menu lets you deploy, manage, or remove services:

| Option | Action |
|---|---|
| `1` | Full deployment (everything) |
| `2` / `3` | Install / uninstall a single component |
| `4` | Remove everything |
| `5`-`7` | Start / stop / restart services |
| `8` | Health check + status |
| `9` | Verify prerequisites |
| `10` | Change install drive/path |
| `11` | Open logs folder |

> Prerequisites (Git, Node.js 22+, Python 3.13+, winget) are checked automatically. Missing tools can be installed from the prompt.

## Headless / automated

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Force                          # Full deploy, no prompts
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Force -Components frontend,backend  # Deploy only these
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -DryRun                         # Preview only
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -DryRun -Components caddy,cloudflare
```

> If the script doesn't run, append `powershell -ExecutionPolicy Bypass -File` before `deploy.ps1` as shown above.

## Config (`deploy.config.json`)

| Field | Default | What to change |
|---|---|---|
| `FrontendRepo` | `Posuza/ESS_MO_Fronend` | Git repo for the Vue frontend |
| `BackendRepo` | `Posuza/ESS_MO_Backend` | Git repo for the FastAPI backend |
| `FrontendPort` | `3009` | Frontend service port |
| `BackendPort` | `8009` | Backend API port |
| `CaddyPort` | *(prompted at startup)* | Reverse proxy port — asked on first run (default 8089) |
| `PublicUrl` | `http://localhost:8089` | Public URL where the whole app is accessed (Cloudflare tunnel / server IP / domain) |
| `InstallRoot` | *(prompted at startup)* | Install directory — picked via drive prompt on first run |
| `ApiPrefix` | `/api/v1` | API path prefix |

Edit before first deploy if your environment needs different repos, ports, or paths.

## Secrets (`deploy.secrets.json`)

```json
{
  "db":    { "host", "port", "name", "user", "password" },
  "smtp":  { "host", "port", "user", "pass", "from" }
}
```

Auto-gitignored. Copy `deploy.secrets.example.json` → `deploy.secrets.json` to pre-fill.

> `FRONTEND_URL` in the backend `.env` is read from `PublicUrl` in `deploy.config.json`. Set it to your real domain or tunnel URL for production.

## Files

| File | Purpose | Git? |
|---|---|---|
| `deploy.ps1` | Main script | ✅ |
| `deploy.config.json` | Ports, paths, repos | ✅ |
| `deploy.secrets.example.json` | Credentials template | ✅ |
| `deploy.secrets.json` | Your real credentials | ❌ (gitignored) |

## Troubleshooting

- **Service won't uninstall** — restart Windows, then re-run uninstall.
- **Port 80 in use** — option 1 stops IIS automatically.
- **cloudflared missing** — `winget install Cloudflare.cloudflared`
- **Logs** — `<InstallRoot>\logs\deploy-YYYYMMDD-HHmmss.log`
