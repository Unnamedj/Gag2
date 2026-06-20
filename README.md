# GaG2 - Grow a Garden 2 Tools

**Wild Pet Discord/Web Notifier + Auto-TP + Auto Joiner + Continuous Server Hopper**

A complete toolkit for Grow a Garden 2 (and compatible with GaG1 wild pets) featuring:

- **Wild Pet Notifier**: Scans for valuable wild pets, sends rich Discord webhooks + to your personal web dashboard.
- **Beautiful Web Dashboard**: View all spotted pets in real-time, filter by value, one-click copy join commands or teleport scripts.
- **Auto Joiner Script**: Standalone Lua that polls the dashboard API and automatically joins the best servers (highest value pets).
- **GaG2 Server Hopper/Scraper**: High-performance proxy-rotating server pool manager for continuous hopping in Grow a Garden 2. Dispenses fresh Job IDs via API for multi-bot farms.

---

## 🚀 Quick Start

### 1. Clone & Setup Server
```bash
git clone https://github.com/Unnamedj/Gag2.git
cd Gag2
npm install express axios https-proxy-agent
# Add your proxies (one per line) to proxies.txt
```

### 2. Run the Web + Hopper Server
```bash
node app.js
```
Server runs on http://localhost:8080 (or set PORT env)

Open http://localhost:8080 in your browser for the live dashboard.

### 3. Configure & Load Lua Scripts (Executor)
- Edit `WildPetWebhook.lua`:
  - Set your Discord `webhookUrl` (optional but recommended for pings)
  - Set `webUrl = "http://YOUR_SERVER_IP:8080/notify"`  (IMPORTANT for dashboard & autojoiner)
  - Adjust `notifyList`, `minValue`, `autoTp` etc.
- Execute `WildPetWebhook.lua` in game (supports most executors with HTTP + getrawmetatable)

- For auto-joining best pets from anywhere: Execute `AutoJoiner.lua` (configure the `API_BASE` to your server)

### 4. Proxies (for Hopper)
Create `proxies.txt` with residential proxies (recommended for Roblox scraping to avoid 429s). Format examples supported:
- `user:pass@host:port`
- `host:port:user:pass`
- `http://user:pass@host:port`

The hopper auto-rotates them.

---

## 📡 API Endpoints

| Method | Endpoint          | Description |
|--------|-------------------|-------------|
| GET    | /                 | Beautiful live Dashboard (HTML + Tailwind) |
| POST   | /notify           | Receive pet detection from Lua (JSON) |
| GET    | /api/pets         | List recent wild pets (sorted by value desc) |
| GET    | /api/best         | Get the single best current pet/server |
| GET    | /server?size=N    | Get N fresh JobIDs for GaG2 hopping (requires Username header) |
| GET    | /stats            | Full hopper + pet stats JSON |
| GET    | /recycle          | Force recycle old dispensed servers |
| POST   | /remove           | Report bad server, get replacement (for bots) |
| GET    | /bots-online      | Count of active bot connections |

---

## 🐾 Wild Pet Features (Lua)

- Scans multiple spawn folders + descendants
- Values parsed from Sheckles/K/M/B/T labels
- Rich Discord embeds with emoji, value, time left, coords, JobID + ready-to-paste TeleportToPlaceInstance
- Anti-rollback TP with 8 methods + cascade + gravity hack + anchor pulse
- Session dedup so same pet+location notified only once
- UI in-game with toggles for Auto-TP, Anti-Rollback, Notify All, TP Method

## 🔄 Continuous Hopping (GaG2)

The included hopper is tuned for **Grow a Garden 2** (Place ID `97598239454123`).
It maintains a large pool of public servers, recycles them, handles rate limits with adaptive delays + rotating proxies.
Perfect for multi-account farming, pet hunting, or event grinding.

Bots connect with `Username` header to claim servers via `/server`.

## 🛠️ Auto Joiner

`AutoJoiner.lua` continuously polls `/api/best` (or filtered `/api/pets`).
When a high-value pet appears, it automatically executes:
```lua
game:GetService("TeleportService"):TeleportToPlaceInstance(placeId, jobId)
```
Configure thresholds, poll interval, min value, and whether to only join if better than current.

Great for AFK pet hunting across many servers.

---

## ⚙️ Configuration Tips

- `minValue` in Lua: Only notify pets worth this or more (0 = all)
- Dashboard auto-cleans old entries (>30 min)
- Hopper has 50k server threshold auto-wipe after 50min, periodic 80% cache wipe every 2h
- For production: Run behind nginx, use PM2, set real domain/IP for Lua webUrl
- Security: The /notify endpoint is open by design (for your Lua). Add auth if exposing publicly.

## 📁 Project Structure

- `WildPetWebhook.lua` — In-game notifier + auto TP (updated for dual Discord + Web)
- `AutoJoiner.lua` — Standalone auto-join / hopper client script
- `app.js` — All-in-one Node.js server (webhook receiver + dashboard + GaG2 hopper)
- `proxies.txt` (you create) — Proxy list for scraping
- `README.md` — This file

## 🤝 Credits & Notes

Adapted from community scripts (Wild Pet notifier logic + Tyler Hopper style server management).
For educational / personal use on Roblox. Use responsibly.

If you find good wild pets or have suggestions, open an issue!

**Place IDs**:
- GaG2: 97598239454123
- Original (wild pets often in): Check your game

Happy farming! 🌱🐸🦊
