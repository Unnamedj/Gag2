const express = require('express');
const axios = require('axios');
const fs = require('fs');
const { HttpsProxyAgent } = require('https-proxy-agent');

const app = express();
app.use(express.json());
const PORT = process.env.PORT || 8080; // Railway provides PORT env var

const PLACE_ID = '97598239454123'; // Grow a Garden 2

// ── Server Pool ──────────────────────────────────────────────────────────────
const cachedServers = new Set();
const dispensedServers = new Map(); // jobId → dispensedTime
const activeBots = new Map();       // username → lastSeenTimestamp
const removedServers = new Set();
const freshServers = new Set();

let overThresholdSince = null;
const SERVER_THRESHOLD = 50000;
const THRESHOLD_DURATION = 50 * 60 * 1000;

let serverCountHistory = [];
let cachedPerMin = 0;
let serverRequestHistory = [];
let serverRequestsPerMin = 0;
let removeRequestHistory = [];
let removeRequestsPerMin = 0;

let rateLimitCount = 0;
let requestDelay = 100;
const MIN_DELAY = 100;
const MAX_DELAY = 10000;
let dispensingLock = false;

const RECYCLE_TIME = 1.5 * 60 * 1000;
const BOT_TIMEOUT  = 5  * 60 * 1000;
const CACHE_WIPE_INTERVAL = 2 * 60 * 60 * 1000;
let lastCacheWipe = Date.now();

// ── Proxies ───────────────────────────────────────────────────────────────────
let proxies = [];
let proxyOrder = [];
let proxyOrderIndex = 0;
let lastProxyUsed = null;

function loadProxies() {
  // 1. Check PROXIES environment variable first (Railway-friendly)
  //    Set it in Railway vars as comma or newline separated proxy strings.
  //    Example: w08aq6dkzg5i:b909hzroupq8@eu.nettify.xyz:8080
  if (process.env.PROXIES && process.env.PROXIES.trim() !== '') {
    proxies = process.env.PROXIES.split(/[\n,]+/).map(l => l.trim()).filter(l => l !== '');
    console.log(`Loaded ${proxies.length} proxies from PROXIES env var`);
    resetProxyOrder();
    return;
  }
  // 2. Fall back to proxies.txt
  try {
    const data = fs.readFileSync('proxies.txt', 'utf8');
    proxies = data.split('\n').map(l => l.trim()).filter(l => l !== '');
    console.log(`Loaded ${proxies.length} proxies from proxies.txt`);
    resetProxyOrder();
  } catch (e) { proxies = []; proxyOrder = []; proxyOrderIndex = 0; console.log('No proxies loaded — scraping direct'); }
}

function resetProxyOrder() {
  proxyOrder = proxies.slice();
  if (proxyOrder.length > 0) { shuffleArray(proxyOrder); proxyOrderIndex = 0; }
}

function shuffleArray(arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
}

function getNextProxy() {
  if (proxies.length === 0) return null;
  const p = proxyOrder[proxyOrderIndex];
  proxyOrderIndex = (proxyOrderIndex + 1) % proxyOrder.length;
  lastProxyUsed = p;
  return p;
}

function stripSessionParams(s) {
  if (!s) return s;
  return s.replace(/_session-[^_]+/g, '').replace(/_lifetime-[^_]+/g, '').replace(/_+$/, '');
}

function parseProxy(proxyString) {
  if (!proxyString) return null;
  const s = proxyString.trim();
  if (/^[a-zA-Z]+:\/\//.test(s)) {
    const u = new URL(s);
    return {
      host: u.hostname, port: parseInt(u.port || '80', 10),
      username: u.username ? stripSessionParams(decodeURIComponent(u.username)) : null,
      password: u.password ? stripSessionParams(decodeURIComponent(u.password)) : null,
    };
  }
  if (s.includes('@')) {
    const at = s.lastIndexOf('@');
    const left = s.slice(0, at), right = s.slice(at + 1);
    const [host, portStr] = right.split(':');
    if (!host || !portStr) return null;
    const colon = left.indexOf(':');
    if (colon === -1) return null;
    return {
      host, port: parseInt(portStr, 10),
      username: stripSessionParams(left.slice(0, colon)) || null,
      password: stripSessionParams(left.slice(colon + 1)) || null,
    };
  }
  const parts = s.split(':');
  if (parts.length === 4) {
    const secondIsPort = !isNaN(parseInt(parts[1], 10)) && parts[1].length < 6;
    if (secondIsPort) {
      const [host, port, username, password] = parts;
      return { host, port: parseInt(port, 10), username: stripSessionParams(username) || null, password: stripSessionParams(password) || null };
    } else {
      const [username, password, host, port] = parts;
      return { host, port: parseInt(port, 10), username: stripSessionParams(username) || null, password: stripSessionParams(password) || null };
    }
  }
  if (parts.length === 2) return { host: parts[0], port: parseInt(parts[1], 10), username: null, password: null };
  return null;
}

// ── Scraper ───────────────────────────────────────────────────────────────────
async function fetchServers(url, proxyString) {
  try {
    const cfg = {
      timeout: 15000,
      headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
    };
    if (proxyString) {
      const p = parseProxy(proxyString);
      if (p) {
        const auth = p.username && p.password ? `${p.username}:${p.password}` : '';
        const proxyUrl = auth ? `http://${auth}@${p.host}:${p.port}` : `http://${p.host}:${p.port}`;
        cfg.httpsAgent = new HttpsProxyAgent(proxyUrl);
        cfg.proxy = false;
      }
    }
    const r = await axios.get(url, cfg);
    if (requestDelay > MIN_DELAY) requestDelay = Math.max(MIN_DELAY, requestDelay - 10);
    return r.data;
  } catch (e) {
    if (e.response?.status === 429) {
      rateLimitCount++;
      requestDelay = Math.min(MAX_DELAY, requestDelay + 100);
      console.log(`[RATE LIMIT] delay=${requestDelay}ms total=${rateLimitCount}`);
    }
    return null;
  }
}

function processServers(data) {
  if (!data?.data) return [];
  const news = [];
  data.data.forEach(s => {
    if (s.id && !cachedServers.has(s.id) && !removedServers.has(s.id)) {
      cachedServers.add(s.id); freshServers.add(s.id); news.push(s.id);
    }
  });
  return news;
}

const endpoints = [
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Asc`,
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&sortOrder=Asc`,
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Desc`,
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&sortOrder=Desc`,
];
function getRandomEndpoint() { return endpoints[Math.floor(Math.random() * endpoints.length)]; }

async function scrapeServers(workerId) {
  const MAX_PAGES = 10;
  const BASE_COOLDOWN = 2000;
  const IDLE_COOLDOWN = 10000;
  while (true) {
    try {
      const endpoint = getRandomEndpoint();
      let cursor = null, totalNew = 0, pages = 0;
      while (pages < MAX_PAGES) {
        const url = cursor ? `${endpoint}&cursor=${cursor}` : endpoint;
        await new Promise(r => setTimeout(r, requestDelay));
        const data = await fetchServers(url, getNextProxy());
        if (!data) { if (rateLimitCount > 0) await new Promise(r => setTimeout(r, requestDelay * 2)); break; }
        const added = processServers(data);
        totalNew += added.length; pages++;
        if (added.length === 0 && pages > 1) break;
        if (data.nextPageCursor) cursor = data.nextPageCursor; else break;
      }
      if (totalNew > 0) {
        console.log(`[W${workerId}] +${totalNew} (Total: ${cachedServers.size})`);
        await new Promise(r => setTimeout(r, BASE_COOLDOWN));
      } else {
        await new Promise(r => setTimeout(r, IDLE_COOLDOWN));
      }
    } catch (e) {
      console.error(`[W${workerId}] error:`, e.message);
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

function startScrapers(count = 10) {
  console.log(`Starting ${count} scrapers for PLACE_ID ${PLACE_ID}...`);
  for (let i = 0; i < count; i++) setTimeout(() => scrapeServers(i), i * 500);
}

// ── Pet Reports ───────────────────────────────────────────────────────────────
let recentPets = [];
const MAX_PETS = 100;
const PET_AGE  = 30 * 60 * 1000;

function addPetDetection(d) {
  if (!d?.jobId || !d.pet) return;
  recentPets = recentPets.filter(p => !(p.jobId === d.jobId && p.pet.name === d.pet.name));
  recentPets.unshift({
    jobId: d.jobId, placeId: d.placeId || PLACE_ID,
    pet: d.pet, players: d.players || 0, maxPlayers: d.maxPlayers || 0,
    receivedAt: Date.now(),
  });
  if (recentPets.length > MAX_PETS) recentPets.length = MAX_PETS;
  recentPets = recentPets.filter(p => Date.now() - p.receivedAt < PET_AGE);
}

// ── API Routes ────────────────────────────────────────────────────────────────
app.post('/notify', (req, res) => { addPetDetection(req.body); res.json({ ok: true }); });

app.get('/api/pets', (req, res) => {
  const min = parseInt(req.query.minValue || 0);
  const q   = (req.query.search || '').toLowerCase();
  let list = recentPets.filter(p => (p.pet.value || 0) >= min);
  if (q) list = list.filter(p => p.pet.name.toLowerCase().includes(q));
  list.sort((a, b) => (b.pet.value || 0) - (a.pet.value || 0));
  res.json({ pets: list });
});

app.get('/api/best', (req, res) => {
  res.json({ best: recentPets.length ? recentPets.reduce((a, b) => (b.pet.value || 0) > (a.pet.value || 0) ? b : a) : null });
});

app.get('/server', async (req, res) => {
  serverRequestHistory.push(Date.now());
  const size = parseInt(req.query.size) || 1;
  const username = req.headers['username'];
  if (!username) return res.status(400).send('Username header required');
  activeBots.set(username, Date.now());
  if (size < 1 || size > 1000) return res.status(400).send('Size must be 1-1000');
  while (dispensingLock) await new Promise(r => setTimeout(r, 10));
  dispensingLock = true;
  try {
    const avail = [...cachedServers].filter(id => !dispensedServers.has(id));
    if (avail.length < size) { dispensingLock = false; return res.status(503).send(`Not enough servers: have ${avail.length}, need ${size}`); }
    const fresh = avail.filter(id => freshServers.has(id));
    const ready = avail.filter(id => !freshServers.has(id));
    const chosen = [...fresh.slice(0, size), ...ready.slice(0, Math.max(0, size - fresh.length))].slice(0, size);
    const now = Date.now();
    chosen.forEach(id => { dispensedServers.set(id, now); freshServers.delete(id); });
    dispensingLock = false;
    res.type('text/plain').send(chosen.join('\n'));
    console.log(`[DISPENSED] ${size} → ${username} (pool: ${avail.length - size} left)`);
  } catch (e) { dispensingLock = false; res.status(500).send('Error'); }
});

app.post('/remove', async (req, res) => {
  removeRequestHistory.push(Date.now());
  const username = req.headers['username'];
  const { jobid } = req.body;
  if (!username) return res.status(400).json({ error: 'Username header required' });
  activeBots.set(username, Date.now());
  if (!jobid) return res.status(400).json({ error: 'jobid required in body' });
  while (dispensingLock) await new Promise(r => setTimeout(r, 10));
  dispensingLock = true;
  try {
    if (cachedServers.has(jobid)) {
      cachedServers.delete(jobid); dispensedServers.delete(jobid);
      freshServers.delete(jobid); removedServers.add(jobid);
    }
    const avail = [...cachedServers].filter(id => !dispensedServers.has(id));
    if (avail.length === 0) { dispensingLock = false; return res.status(503).json({ error: 'No servers available' }); }
    const freshAvail = avail.filter(id => freshServers.has(id));
    const newJobId = freshAvail.length > 0 ? freshAvail[0] : avail[0];
    dispensedServers.set(newJobId, Date.now()); freshServers.delete(newJobId);
    dispensingLock = false;
    console.log(`[REMOVE] ${username}: ${jobid} → ${newJobId}`);
    res.json({ new_jobid: newJobId });
  } catch (e) { dispensingLock = false; res.status(500).json({ error: 'Error' }); }
});

app.get('/recycle', (req, res) => {
  const now = Date.now(); let recycled = 0;
  for (const [id, t] of dispensedServers) if (now - t >= RECYCLE_TIME) { dispensedServers.delete(id); recycled++; }
  res.json({ recycled, available: cachedServers.size - dispensedServers.size });
});

app.get('/clear', (req, res) => {
  cachedServers.clear(); dispensedServers.clear(); freshServers.clear(); removedServers.clear(); recentPets = [];
  res.json({ message: 'All caches cleared', servers: 0, pets: 0 });
});

app.get('/servers', (req, res) => res.json({ totalCached: cachedServers.size, servers: Array.from(cachedServers) }));
app.get('/bots-online', (req, res) => res.type('text/plain').send(activeBots.size.toString()));

app.get('/stats', (req, res) => {
  const now = Date.now();
  const available = cachedServers.size - dispensedServers.size;
  let recyclingCount = 0;
  for (const [, t] of dispensedServers) if (now - t < RECYCLE_TIME) recyclingCount++;
  const timeSinceWipe = Math.floor((now - lastCacheWipe) / 1000);
  const timeUntilWipe = Math.floor((CACHE_WIPE_INTERVAL - (now - lastCacheWipe)) / 1000);
  const best = recentPets.length ? recentPets.reduce((a, b) => (b.pet.value || 0) > (a.pet.value || 0) ? b : a) : null;
  res.json({
    pool: {
      totalServers: cachedServers.size, freshServers: freshServers.size,
      readyServers: Math.max(0, available - freshServers.size),
      recyclingServers: recyclingCount, availableServers: available,
      dispensedServers: dispensedServers.size, removedServers: removedServers.size,
      cachedPerMin,
    },
    pets: {
      totalTracked: recentPets.length,
      bestValue: best?.pet.value || 0, bestPetName: best?.pet.name || null, bestJobId: best?.jobId || null,
    },
    bots: activeBots.size, serverRequestsPerMin, removeRequestsPerMin,
    totalProxies: proxies.length, currentDelay: requestDelay, rateLimits: rateLimitCount,
    timeSinceLastWipe: `${Math.floor(timeSinceWipe / 3600)}h ${Math.floor((timeSinceWipe % 3600) / 60)}m`,
    timeUntilNextWipe: `${Math.floor(timeUntilWipe / 3600)}h ${Math.floor((timeUntilWipe % 3600) / 60)}m`,
    uptime: Math.floor(process.uptime()),
  });
});

// ── Background Jobs ───────────────────────────────────────────────────────────
setInterval(() => {
  const now = Date.now(); let recycled = 0;
  for (const [id, t] of dispensedServers) if (now - t >= RECYCLE_TIME) { dispensedServers.delete(id); recycled++; }
  if (recycled > 0) console.log(`[AUTO-RECYCLE] ${recycled} (available: ${cachedServers.size - dispensedServers.size})`);
}, 30000);

setInterval(() => {
  const now = Date.now(); let removed = 0;
  for (const [u, t] of activeBots) if (now - t > BOT_TIMEOUT) { activeBots.delete(u); removed++; }
  if (removed > 0) console.log(`[BOTS] Cleaned ${removed} (active: ${activeBots.size})`);
}, 60000);

setInterval(() => {
  const now = Date.now(), ago = now - 60000;
  serverRequestHistory = serverRequestHistory.filter(t => t > ago);
  serverRequestsPerMin = serverRequestHistory.length;
  removeRequestHistory = removeRequestHistory.filter(t => t > ago);
  removeRequestsPerMin = removeRequestHistory.length;
  serverCountHistory = serverCountHistory.filter(e => e.timestamp > ago);
  if (serverCountHistory.length > 0) cachedPerMin = Math.max(0, cachedServers.size - serverCountHistory[0].count);
}, 10000);

setInterval(() => serverCountHistory.push({ timestamp: Date.now(), count: cachedServers.size }), 5000);
setInterval(() => { recentPets = recentPets.filter(p => Date.now() - p.receivedAt < PET_AGE); }, 60000);

setInterval(() => {
  const sizeBefore = cachedServers.size;
  const servers = Array.from(cachedServers); shuffleArray(servers);
  const keepCount = Math.floor(servers.length * 0.20);
  const toKeep = new Set(servers.slice(0, keepCount));
  cachedServers.clear(); dispensedServers.clear(); freshServers.clear();
  toKeep.forEach(id => { cachedServers.add(id); freshServers.add(id); });
  lastCacheWipe = Date.now();
  console.log(`[CACHE WIPE] ${sizeBefore} → ${cachedServers.size}`);
}, CACHE_WIPE_INTERVAL);

function checkThresholdWipe() {
  const total = cachedServers.size;
  if (total > SERVER_THRESHOLD) {
    if (!overThresholdSince) { overThresholdSince = Date.now(); console.log(`[THRESHOLD] ${total} > ${SERVER_THRESHOLD}, 50min timer started`); }
    else if (Date.now() - overThresholdSince >= THRESHOLD_DURATION) {
      console.log(`[THRESHOLD WIPE] ${total} over limit for 50min — clearing`);
      cachedServers.clear(); dispensedServers.clear(); freshServers.clear(); removedServers.clear();
      overThresholdSince = null; lastCacheWipe = Date.now();
    }
  } else { if (overThresholdSince) console.log(`[THRESHOLD] Dropped below ${SERVER_THRESHOLD}, timer reset`); overThresholdSince = null; }
}
setInterval(checkThresholdWipe, 60000);

// ── Dashboard ─────────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
  const pid = PLACE_ID;
  res.send('<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GaG2 Dashboard</title><script src="https://cdn.tailwindcss.com"><\/script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css"><style>body{font-family:Inter,system-ui,sans-serif}.pet-card{transition:all .2s}.pet-card:hover{transform:translateY(-2px);box-shadow:0 8px 24px -4px rgba(168,85,247,.18)}.font-mono{font-variant-numeric:tabular-nums}<\/style><\/head><body class="bg-zinc-950 text-zinc-200 min-h-screen"><div class="max-w-[1280px] mx-auto p-6"><div class="flex justify-between items-center mb-8"><div class="flex items-center gap-3"><div class="w-11 h-11 rounded-2xl bg-gradient-to-br from-violet-500 to-fuchsia-500 flex items-center justify-center text-2xl">\u{1F331}<\/div><div><div class="font-bold text-2xl tracking-tight">GaG2 Hopper<\/div><div class="text-xs text-zinc-500">Grow a Garden 2 · ' + pid + '<\/div><\/div><\/div><div class="flex gap-2 text-sm"><div class="px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl flex items-center gap-2"><span class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"><\/span><span id="bots-count" class="font-mono font-semibold">0<\/span><span class="text-zinc-500">bots<\/span><\/div><div class="px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl flex items-center gap-2"><i class="fa-solid fa-server text-violet-400 text-xs"><\/i><span id="servers-count" class="font-mono font-semibold">0<\/span><span class="text-zinc-500">servers<\/span><\/div><\/div><\/div><div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8"><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 flex flex-col gap-1"><div class="text-xs text-zinc-500 uppercase tracking-wider">Pool<\/div><div id="stat-total" class="text-4xl font-bold">0<\/div><div class="text-xs text-zinc-600">total servers<\/div><\/div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 flex flex-col gap-1"><div class="text-xs text-zinc-500 uppercase tracking-wider">Available<\/div><div id="stat-avail" class="text-4xl font-bold text-emerald-400">0<\/div><div class="text-xs text-zinc-600">ready to dispense<\/div><\/div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 flex flex-col gap-1"><div class="text-xs text-zinc-500 uppercase tracking-wider">Pets Found<\/div><div id="stat-pets" class="text-4xl font-bold text-violet-400">0<\/div><div id="stat-best" class="text-xs text-zinc-600 truncate">—<\/div><\/div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 flex flex-col gap-1"><div class="text-xs text-zinc-500 uppercase tracking-wider">Bots<\/div><div id="stat-bots" class="text-4xl font-bold">0<\/div><div class="text-xs text-zinc-600">active scrapers<\/div><\/div><\/div><div class="flex justify-between items-center mb-4 gap-4"><h2 class="font-semibold text-xl flex items-center gap-2"><span>\u{1F43E}<\/span> Recent Pets<\/h2><div class="flex gap-2 flex-wrap"><input id="search-input" placeholder="Search pet name…" class="bg-zinc-900 border border-zinc-800 rounded-2xl px-4 py-2 text-sm w-52 focus:outline-none focus:border-violet-500 transition-colors"><div class="flex items-center gap-2 bg-zinc-900 border border-zinc-800 rounded-2xl px-3 py-2"><span class="text-xs text-zinc-500">Min $<\/span><input id="min-value" type="number" value="0" class="bg-transparent text-sm w-20 focus:outline-none font-mono"><\/div><\/div><\/div><div id="pets-grid" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4 mb-8"><\/div><div id="no-pets" class="text-center py-16 text-zinc-600 hidden"><div class="text-4xl mb-3">\u{1F33F}<\/div><div class="text-sm">No pets detected yet — bots are scanning<\/div><\/div><div class="mt-4"><h2 class="font-semibold text-xl mb-4 flex items-center gap-2"><i class="fa-solid fa-server text-violet-400 text-sm"><\/i> Server Pool<\/h2><div id="pool-stats" class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3"><\/div><\/div><\/div><script>var PLACE_ID=' + pid + ';function fv(v){if(!v||v<=0)return"0";if(v>=1e12)return(v/1e12).toFixed(2)+"T";if(v>=1e9)return(v/1e9).toFixed(2)+"B";if(v>=1e6)return(v/1e6).toFixed(1)+"M";if(v>=1e3)return(v/1e3).toFixed(0)+"K";return Math.floor(v)}function pe(n){n=n.toLowerCase();if(n.includes("frog"))return"\u{1F438}";if(n.includes("bunny")||n.includes("rabbit"))return"\u{1F430}";if(n.includes("owl"))return"\u{1F989}";if(n.includes("raccoon"))return"\u{1F99D}";if(n.includes("gnome"))return"\u{1F9D9}";if(n.includes("fox"))return"\u{1F98A}";if(n.includes("deer"))return"\u{1F98C}";if(n.includes("squirrel"))return"\u{1F43F}️";if(n.includes("snail"))return"\u{1F40C}";if(n.includes("bird"))return"\u{1F426}";if(n.includes("golden"))return"✨";if(n.includes("rainbow"))return"\u{1F308}";return"\u{1F43E}"}function vc(v){if(v>=1e9)return"bg-red-500/90 text-white";if(v>=1e8)return"bg-orange-500/90 text-white";if(v>=1e7)return"bg-amber-400 text-zinc-950";if(v>=1e6)return"bg-yellow-300 text-zinc-950";if(v>=1e5)return"bg-zinc-600 text-zinc-100";return"bg-zinc-800 text-zinc-400"}function ago(ms){var s=Math.floor(ms/1000);if(s<60)return s+"s ago";if(s<3600)return Math.floor(s/60)+"m ago";return Math.floor(s/3600)+"h ago"}async function loadStats(){try{var r=await fetch("/stats");var d=await r.json();document.getElementById("stat-total").innerText=d.pool.totalServers;document.getElementById("stat-avail").innerText=d.pool.availableServers;document.getElementById("stat-pets").innerText=d.pets.totalTracked;document.getElementById("stat-bots").innerText=d.bots;document.getElementById("bots-count").innerText=d.bots;document.getElementById("servers-count").innerText=d.pool.totalServers;if(d.pets.bestPetName)document.getElementById("stat-best").innerText=pe(d.pets.bestPetName)+" "+d.pets.bestPetName+" $"+fv(d.pets.bestValue);document.getElementById("pool-stats").innerHTML=["Total "+d.pool.totalServers,"Fresh "+d.pool.freshServers,"Available "+d.pool.availableServers,"Recycling "+d.pool.recyclingServers,"Dispensed "+d.pool.dispensedServers,"Removed "+d.pool.removedServers].map(function(l,i){var cols=["text-zinc-300","text-emerald-400","text-sky-400","text-amber-400","text-violet-400","text-red-400"];return "<div class=\\"bg-zinc-900 border border-zinc-800 rounded-2xl p-3 text-center\\"><div class=\\""+cols[i]+" font-bold text-2xl\\">"+l.split(" ")[1]+"<\/div><div class=\\"text-xs text-zinc-600 mt-1\\">"+l.split(" ")[0]+"<\/div><\/div>";}).join("")}catch(e){}}async function loadPets(){try{var min=document.getElementById("min-value").value||0;var q=encodeURIComponent(document.getElementById("search-input").value||"");var r=await fetch("/api/pets?minValue="+min+"&search="+q);var d=await r.json();var g=document.getElementById("pets-grid");var empty=document.getElementById("no-pets");if(!d.pets||d.pets.length===0){g.innerHTML="";empty.classList.remove("hidden");return}empty.classList.add("hidden");g.innerHTML=d.pets.map(function(p){return "<div class=\\"pet-card bg-zinc-900 border border-zinc-800 rounded-3xl p-5\\"><div class=\\"flex items-start justify-between gap-2 mb-3\\"><div class=\\"flex items-center gap-3\\"><span class=\\"text-4xl leading-none\\">"+pe(p.pet.name)+"<\/span><div><div class=\\"font-semibold leading-tight\\">"+p.pet.name+"<\/div><div class=\\"text-xs text-zinc-500 mt-0.5\\">"+ago(Date.now()-p.receivedAt)+"<\/div><\/div><\/div><span class=\\"px-2.5 py-1 rounded-xl text-xs font-bold "+vc(p.pet.value||0)+" whitespace-nowrap\\">$"+fv(p.pet.value||0)+"<\/span><\/div><div class=\\"font-mono text-xs text-violet-400 truncate mb-1\\">"+p.jobId+"<\/div><div class=\\"flex justify-between text-xs text-zinc-500 mb-3\\"><span>\u{1F465} "+p.players+"/"+(p.maxPlayers||"?")+"<\/span><span>⏱ "+(p.pet.time||"?")+"<\/span><\/div><div class=\\"grid grid-cols-2 gap-2\\"><button onclick=\\"copyJoin(\'"+p.jobId+"\')\\" class=\\"py-2 text-xs bg-violet-600 hover:bg-violet-500 rounded-xl transition-colors font-semibold\\">\u{1F4CB} Copy<\/button><button onclick=\\"joinNow(\'"+p.jobId+"\')\\" class=\\"py-2 text-xs border border-zinc-700 hover:bg-zinc-800 rounded-xl transition-colors\\">Join<\/button><\/div><\/div>";}).join("")}catch(e){}}function copyJoin(j){var cmd="game:GetService(\\"TeleportService\\"):TeleportToPlaceInstance("+PLACE_ID+",\\""+j+"\\")";navigator.clipboard.writeText(cmd);var t=document.createElement("div");t.className="fixed bottom-6 left-1/2 -translate-x-1/2 bg-violet-700 px-5 py-2.5 rounded-xl text-sm font-semibold shadow-lg";t.innerText="✓ Copied!";document.body.appendChild(t);setTimeout(function(){t.remove()},1500)}function joinNow(j){prompt("Run in executor:","game:GetService(\\"TeleportService\\"):TeleportToPlaceInstance("+PLACE_ID+",\\""+j+"\\"")}var debT;function setup(){var s=document.getElementById("search-input");var m=document.getElementById("min-value");var trig=function(){clearTimeout(debT);debT=setTimeout(loadPets,280)};s.oninput=trig;m.oninput=trig}async function init(){setup();await Promise.all([loadStats(),loadPets()]);setInterval(function(){return Promise.all([loadStats(),loadPets()])},8000)}window.onload=init<\/script><\/body><\/html>');
});

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`GaG2 Hopper running on port ${PORT}`);
  loadProxies();
  setTimeout(() => { console.log('Starting 10 scrapers...'); startScrapers(10); }, 1000);
});
