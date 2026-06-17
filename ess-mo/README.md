# Servy Full-Stack Deployment Manager

Automates installing the **ESS MO** app (Vue frontend + FastAPI backend + Caddy reverse proxy + Cloudflare tunnel) as Windows services via [Servy](https://github.com/servy-community/servy).

---

## 📋 Before you begin — config files

Edit these **before** your first deploy if your setup differs from the defaults.

### `deploy.config.json` — settings (ports, paths, repos)

Created automatically on first run. Edit it to change:

> ⚠️ **Do not use ports** `80`, `443`, `8080`, `3000`, `8000`, `5000` — these are typically taken by other services (IIS, web servers, dev tools). Pick free ports instead. The defaults (`3009`, `8009`, `8089`,....) any of such this never conflict.

| Field | Default | What it does | Can be changed? |
|---|---|---|---|
| `FrontendRepo` | `Posuza/ESS_MO_Fronend` | Git repo for the Vue frontend | ✅ Replace with your own repo URL |
| `BackendRepo` | `Posuza/ESS_MO_Backend` | Git repo for the FastAPI backend | ✅ Replace with your own repo URL |
| `FrontendPort` | `3009` | Port the frontend serves on | ✅ Change if needed |
| `BackendPort` | `8009` | Port the backend API runs on | ✅ Change if needed |
| `CaddyPort` | `8089` | Port the reverse proxy listens on | ✅ Change if needed |
| `PublicUrl` | `http://localhost:8089` | External URL users access the app at | ✅ Set to your domain, IP, or Cloudflare tunnel URL |
| `LocalUrl` | `http://localhost:8089` | Local network URL for internal access | ✅ Set to your local server IP/hostname |
| `ApiPrefix` | `/api/v1` | API path prefix | ✅ Any prefix starting with `/` (e.g. `/api`, `/v2`) |
| `InstallRoot` | *(set at startup)* | Where files get installed (e.g. `C:\Ess_Mo`) | ✅ Set at startup or edit in config |
| `TunnelTarget` | `caddy` | What Cloudflare exposes (`caddy` / `frontend` / `backend` / `custom`) | ✅ Change via option 8 menu |

### `deploy.secrets.json` — credentials (DB, SMTP)

Auto-gitignored. Copy `deploy.secrets.example.json` → `deploy.secrets.json` to pre-fill, or enter them when the script prompts you.

```json
{
  "db":   { "host": "192.168.1.140", "port": "3306", "name": "ess", "user": "root", "password": "..." },
  "smtp": { "host": "smtp.gmail.com", "port": "587", "user": "...", "pass": "...", "from": "..." }
}
```

> If you skip pre-filling, the script will ask for these interactively.

---

## 🚀 Step-by-step installation guide

### 1. Run the script

Open **PowerShell as Administrator** and run:

```powershell
# Navigate to the folder first
cd C:\path\to\ess-mo

# Run
.\deploy.ps1
```

If execution policy blocks it:

```powershell
powershell -ExecutionPolicy Bypass -File "filepath\deploy.ps1"
```

### 2. Set install location (first run only)

You'll be asked to pick a **drive** (e.g. `C:`, `D:`). The script creates `Ess_Mo` folder there (`C:\Ess_Mo`).

### 3. Use the main menu

```
 1) Check prerequisites
 2) Install components
 3) Uninstall components
 4) Service status / health check
 5) Start services
 6) Stop services
 7) Caddy network config
 8) Public network config (Cloudflare / URL)
 9) Open logs folder
 Q) Quit
```

---

### 4. Install everything

Press **`2`** then **`A`** to install all components (or pick individually by number).

The script will:
1. Check prerequisites (Git, Node.js, Python) — installs missing ones
2. Ask for DB/SMTP credentials (if not pre-filled)
3. Install each component:
   - **Frontend** — clones repo, `npm install`, builds, registers as Windows service
   - **Backend** — clones repo, creates venv, `pip install`, generates `.env`, registers as service
   - **Caddy** — downloads Caddy, creates `Caddyfile`, registers as service
   - **Cloudflare** — installs `cloudflared`, creates tunnel, registers as service
4. Optionally start all services and verify health

---

## 🌐 Setting up your public URL (after installation)

Use **option 8** from the main menu to manage your network URLs:

```
 Current URLs:
   Public URL    : http://localhost:8089
   Local URL     : http://localhost:8089
   Cloudflare    : (not started)

 1) Public URL
 2) Local URL
 3) Cloudflare tunnel
 B) Back
```

### Option 1 — Public URL

This is the URL users type in their browser. You can set it to:

- **Keep current** — use whatever is already set
- **Use Cloudflare tunnel URL** — auto-detects the live tunnel URL (only appears if Cloudflare tunnel is running)
- **Enter custom URL / domain** — type your own (e.g. `https://yourdomain.com`)

> The backend `.env` file's `FRONTEND_URL` is updated automatically when you change the public URL.

### Option 2 — Local URL

For local network access (e.g. `http://192.168.1.100:8089`). Change it to your server's local IP or hostname.

### Option 3 — Cloudflare tunnel

Shows the auto-generated Cloudflare tunnel URL (e.g. `https://xxxx.trycloudflare.com`). Read-only — starts working once the Cloudflare service is running.

---

## 🔧 Caddy routes (option 7)

Use **option 7** to manage which services Caddy proxies to:

```
 Caddy listener : 127.0.0.1:8089

 Available targets:
   (all targets already registered)

 Caddy routes:
   1) /*         → 127.0.0.1:3009  [Frontend]
   2) /api/v1/*  → 127.0.0.1:8009  [Backend]

 1) Add route to Caddy
 2) Remove route from Caddy
 3) Change Caddy listening port
 B) Back to main menu
```

- **Add route** — pick an available service (frontend, backend, or custom), specify a path prefix, confirm. Caddyfile regenerates and Caddy restarts.
- **Remove route** — pick a route by number, confirm removal.
- **Change port** — update the port Caddy listens on.

---

## 📖 Full menu reference

| Option | What it does |
|--------|-------------|
| **1** | Check & install prerequisites (Git, Node.js, Python) |
| **2** | Install components — pick **A** (all), **1** (Frontend), **2** (Backend), **3** (Caddy), **4** (Cloudflare), or **B** (back) |
| **3** | Uninstall components — same submenu, with status indicators |
| **4** | Show service status table + run health checks |
| **5** | Start services — **A** (all), **1-4** (individual), **B** (back) |
| **6** | Stop services — same submenu |
| **7** | Caddy proxy config — add/remove routes, change port |
| **8** | Public network config — set Public URL, Local URL, view Cloudflare tunnel |
| **9** | Open logs folder in File Explorer |
| **Q** | Quit |

---

## 🤖 Headless / automated mode

```powershell
# Full deploy — no prompts
.\deploy.ps1 -Force

# Deploy only specific components
.\deploy.ps1 -Force -Components frontend,backend

# Preview only (dry run)
.\deploy.ps1 -DryRun

# Preview specific components
.\deploy.ps1 -DryRun -Components caddy,cloudflare
```

> Make sure `deploy.config.json` and `deploy.secrets.json` exist and are configured before running headless.

---

## ❓ Troubleshooting

| Problem | Fix |
|---------|-----|
| **Script won't run** | Use `powershell -ExecutionPolicy Bypass -File .\deploy.ps1` |
| **Service won't uninstall** | Restart Windows, then re-run uninstall |
| **Port conflict** | Change Caddy port in option 7 (option 3) or edit `deploy.config.json` |
| **cloudflared missing** | Run: `winget install Cloudflare.cloudflared` or let prerequisites handle it |
| **Frontend build fails** | Check `logs/frontend_build.log` in the install directory |
| **Backend won't start** | Check `logs/backend_pip.log` and verify `.env` has correct DB credentials |
| **No Cloudflare URL** | Start the Cloudflare service (option 5 → 4), then wait ~10 seconds for the tunnel to connect |
| **Logs location** | `<InstallRoot>\logs\deploy-YYYYMMDD-HHmmss.log` |

---

## 📁 Files

| File | Purpose | Tracked in Git? |
|------|---------|:---:|
| `deploy.ps1` | Main deployment script | ✅ |
| `deploy.config.json` | Ports, paths, repos, routes | ✅ |
| `deploy.secrets.example.json` | Credentials template | ✅ |
| `deploy.secrets.json` | Your real DB/SMTP credentials | ❌ (gitignored) |
