# GaG2 - Grow a Garden 2 Tools

**Wild Pet Discord/Web Notifier + Auto-TP + Auto Joiner + Continuous Server Hopper**

One-click deployable on Railway with a beautiful live dashboard showing recent pet detections, stats, and one-click joins.

---

## 🚀 Deploy on Railway (Recommended - 1 Click)

1. Go to [Railway.app](https://railway.app) → New Project → **Deploy from GitHub**
2. Connect/connect this repo (`Unnamedj/Gag2` or your fork)
3. Railway auto-detects Node.js and runs `npm start`
4. Your dashboard is instantly live at the provided URL
5. (Optional) Add a Volume or upload `proxies.txt` later for the hopper

**That's it.** No config needed. The dashboard includes:
- Live updating cards of recent wild pets (with emoji, value, JobID, Join buttons)
- Real-time hopper stats
- Recent activity / detections
- Ready for your Lua scripts to report pets

---

## Local Run

```bash
git clone https://github.com/Unnamedj/Gag2.git
cd Gag2
npm install
node app.js
```

Open http://localhost:8080

## Dashboard Highlights

- Modern dark glass UI with Tailwind
- Recent pets shown as beautiful cards (click to copy Teleport command or open join modal)
- Live polling every ~8 seconds
- Hopper pool stats + recycling info
- Auto Joiner section with instructions
- Mobile-friendly layout

## How the pieces work together

1. `WildPetWebhook.lua` (in-game) → detects pets → sends to your Railway URL `/notify` + optional Discord
2. Dashboard shows them instantly in the recent pets section
3. `AutoJoiner.lua` polls `/api/best` and auto-teleports to the highest value one
4. Hopper (`/server`) gives fresh GaG2 JobIDs for multi-bot farming

## API Endpoints

- `GET /` — Beautiful Dashboard (recent pets + logs style + stats)
- `POST /notify` — Lua reports new pet here
- `GET /api/pets` — JSON list of recent detections (perfect for logs/AJ)
- `GET /api/best` — Best current pet for auto-joiners
- `GET /server` — Fresh GaG2 servers from the hopper

## Included Files

- `app.js` — Full backend + embedded modern dashboard (Railway ready)
- `WildPetWebhook.lua` — In-game detector + reporter
- `AutoJoiner.lua` — UI-ready auto joiner script
- `package.json` + `.gitignore` — Ready for Railway

Happy farming on GaG2! 🌱
