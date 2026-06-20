const express = require('express');
const axios = require('axios');
const fs = require('fs');
const https = require('https');
const { HttpsProxyAgent } = require('https-proxy-agent');

const app = express();
app.use(express.json());
const PORT = process.env.PORT || 8080;

// ============================================
// GaG2 PLACE ID (Grow a Garden 2)
// ============================================
const PLACE_ID = '97598239454123';

// Single server pool (GaG2)
const cachedServers = new Set();
const dispensedServers = new Map(); // jobId -> dispensedTime
const activeBots = new Map(); // username -> lastSeenTimestamp
const removedServers = new Set();
const freshServers = new Set();

// 50k threshold wipe tracking
let overThresholdSince = null;
const SERVER_THRESHOLD = 50000;
const THRESHOLD_DURATION = 50 * 60 * 1000;

// Stats
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
const BOT_TIMEOUT = 5 * 60 * 1000;
const CACHE_WIPE_INTERVAL = 2 * 60 * 60 * 1000;
let lastCacheWipe = Date.now();

// Proxy config
let currentProxyFile = 'proxies.txt';
const PROXY_FILE_ONE = 'proxies.txt';
const PROXY_FILE_TWO = 'proxiesTWO.txt';
let proxies = [];
let proxyOrder = [];
let proxyOrderIndex = 0;
let lastProxyUsed = null;

function loadProxies() {
  try {
    const data = fs.readFileSync(currentProxyFile, 'utf8');
    proxies = data.split('\n').map(l => l.trim()).filter(l => l !== '');
    console.log(`Loaded ${proxies.length} proxies from ${currentProxyFile}`);
    resetProxyOrder();
  } catch (error) {
    console.error(`Error loading ${currentProxyFile}:`, error.message);
    proxies = [];
    proxyOrder = [];
    proxyOrderIndex = 0;
  }
}

function resetProxyOrder() {
  proxyOrder = proxies.slice();
  if (proxyOrder.length === 0) {
    proxyOrderIndex = 0;
  } else {
    shuffleArray(proxyOrder);
    if (lastProxyUsed && proxyOrder.length > 1 && proxyOrder[0] === lastProxyUsed) {
      for (let i = 1; i < proxyOrder.length; i++) {
        if (proxyOrder[i] !== lastProxyUsed) {
          [proxyOrder[0], proxyOrder[i]] = [proxyOrder[i], proxyOrder[0]];
          break;
        }
      }
    }
    proxyOrderIndex = 0;
  }
}

function shuffleArray(arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
}

function getNextProxy() {
  if (proxies.length === 0) return null;
  const proxy = proxyOrder[proxyOrderIndex];
  proxyOrderIndex = (proxyOrderIndex + 1) % proxyOrder.length;
  lastProxyUsed = proxy;
  return proxy;
}

function stripSessionParams(authString) {
  if (!authString) return authString;
  let cleaned = authString;
  cleaned = cleaned.replace(/_session-[^_]+/g, '');
  cleaned = cleaned.replace(/_lifetime-[^_]+/g, '');
  cleaned = cleaned.replace(/_+$/, '');
  return cleaned;
}

function parseProxy(proxyString) {
  if (!proxyString) return null;
  const s = proxyString.trim();
  if (/^[a-zA-Z]+:\/\//.test(s)) {
    const u = new URL(s);
    return {
      host: u.hostname,
      port: parseInt(u.port || '80', 10),
      username: u.username ? stripSessionParams(decodeURIComponent(u.username)) : null,
      password: u.password ? stripSessionParams(decodeURIComponent(u.password)) : null
    };
  }
  if (s.includes('@')) {
    const at = s.lastIndexOf('@');
    const left = s.slice(0, at);
    const right = s.slice(at + 1);
    const [host, portStr] = right.split(':');
    if (!host || !portStr) return null;
    const colon = left.indexOf(':');
    if (colon === -1) return null;
    const username = left.slice(0, colon);
    const password = left.slice(colon + 1);
    return {
      host, port: parseInt(portStr, 10),
      username: stripSessionParams(username) || null,
      password: stripSessionParams(password) || null
    };
  }
  const parts = s.split(':');
  if (parts.length === 4) {
    const secondPartIsPort = !isNaN(parseInt(parts[1], 10)) && parts[1].length < 6;
    if (secondPartIsPort) {
      const [host, port, username, password] = parts;
      return { host, port: parseInt(port, 10), username: stripSessionParams(username) || null, password: stripSessionParams(password) || null };
    } else {
      const [username, password, host, port] = parts;
      return { host, port: parseInt(port, 10), username: stripSessionParams(username) || null, password: stripSessionParams(password) || null };
    }
  }
  if (parts.length === 2) {
    const [host, port] = parts;
    return { host, port: parseInt(port, 10), username: null, password: null };
  }
  return null;
}

async function fetchServers(url, proxyString) {
  try {
    let response = null;
    if (proxyString) {
      const parsed = parseProxy(proxyString);
      if (!parsed) { console.error(`Bad proxy format: ${proxyString}`); return null; }
      const { host, port, username, password } = parsed;
      const auth = username && password ? `${username}:${password}` : '';
      const proxyUrl = auth ? `http://${auth}@${host}:${port}` : `http://${host}:${port}`;
      const agent = new HttpsProxyAgent(proxyUrl);
      response = await axios.get(url, {
        httpsAgent: agent, proxy: false, timeout: 15000,
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }
      });
    } else {
      response = await axios.get(url, {
        timeout: 5000,
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }
      });
    }
    if (requestDelay > MIN_DELAY) requestDelay = Math.max(MIN_DELAY, requestDelay - 10);
    return response.data;
  } catch (error) {
    if (error.response && error.response.status === 429) {
      rateLimitCount++;
      requestDelay = Math.min(MAX_DELAY, requestDelay + 100);
      console.log(`[RATE LIMIT] Increasing delay to ${requestDelay}ms (Total 429s: ${rateLimitCount})`);
    } else {
      console.error(`Error fetching (${proxyString || 'no-proxy'}):`, error.message);
    }
    return null;
  }
}

function processServers(data) {
  if (!data || !data.data) return [];
  const newJobIds = [];
  data.data.forEach(server => {
    if (server.id && !cachedServers.has(server.id)) {
      cachedServers.add(server.id);
      freshServers.add(server.id);
      newJobIds.push(server.id);
    }
  });
  return newJobIds;
}

const endpoints = [
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Asc`,
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&sortOrder=Asc`,
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Desc`,
  `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&sortOrder=Desc`
];

function getRandomEndpoint() {
  return endpoints[Math.floor(Math.random() * endpoints.length)];
}

async function scrapeServers(workerId) {
  const MAX_PAGES = 10;
  const BASE_COOLDOWN = 2000;
  const IDLE_COOLDOWN = 10000;
  while (true) {
    const endpoint = getRandomEndpoint();
    let cursor = null;
    let totalNew = 0;
    let pages = 0;
    while (pages < MAX_PAGES) {
      const currentUrl = cursor ? `${endpoint}&cursor=${cursor}` : endpoint;
      await new Promise(resolve => setTimeout(resolve, requestDelay));
      const proxy = getNextProxy();
      const data = await fetchServers(currentUrl, proxy);
      if (!data) {
        if (rateLimitCount > 0) await new Promise(resolve => setTimeout(resolve, requestDelay * 2));
        break;
      }
      const newJobIds = processServers(data);
      totalNew += newJobIds.length;
      pages++;
      if (newJobIds.length === 0 && pages > 1) break;
      if (data.nextPageCursor) {
        cursor = data.nextPageCursor;
      } else {
        break;
      }
    }
    if (totalNew > 0) {
      console.log(`[SCRAPE W${workerId}] +${totalNew} new GaG2 servers across ${pages} pages (Total: ${cachedServers.size})`);
      await new Promise(resolve => setTimeout(resolve, BASE_COOLDOWN));
    } else {
      await new Promise(resolve => setTimeout(resolve, IDLE_COOLDOWN));
    }
  }
}

function startScrapers(count = 8) {
  console.log(`Starting ${count} GaG2 scrapers...`);
  for (let i = 0; i < count; i++) {
    setTimeout(() => scrapeServers(i), i * 500);
  }
}

// ============================================
// PET NOTIFICATIONS (from WildPetWebhook.lua)
// ============================================
let recentPets = [];
const MAX_PETS = 150;
const PET_MAX_AGE_MS = 30 * 60 * 1000; // 30 minutes

function formatValue(v) {
  if (!v || v <= 0) return '0';
  if (v >= 1e12) return (v / 1e12).toFixed(2) + 'T';
  if (v >= 1e9) return (v / 1e9).toFixed(2) + 'B';
  if (v >= 1e6) return (v / 1e6).toFixed(2) + 'M';
  if (v >= 1e3) return (v / 1e3).toFixed(1) + 'K';
  return Math.floor(v).toString();
}

function addPetDetection(data) {
  if (!data || !data.jobId || !data.pet || !data.pet.name) return;
  const now = Date.now();
  // Dedup same job + pet name
  recentPets = recentPets.filter(p => !(p.jobId === data.jobId && p.pet.name.toLowerCase() === data.pet.name.toLowerCase()));
  const entry = {
    jobId: data.jobId,
    placeId: data.placeId || PLACE_ID,
    pet: {
      name: data.pet.name,
      value: data.pet.value || 0,
      time: data.pet.time || 'Active',
      pos: data.pet.pos || { X: 0, Y: 0, Z: 0 }
    },
    players: data.players || 0,
    maxPlayers: data.maxPlayers || 0,
    receivedAt: now,
    timestamp: data.timestamp || now
  };
  recentPets.unshift(entry);
  if (recentPets.length > MAX_PETS) recentPets = recentPets.slice(0, MAX_PETS);
  // Age cleanup
  recentPets = recentPets.filter(p => now - p.receivedAt < PET_MAX_AGE_MS);
  console.log(`[PET] ${entry.pet.name} ($${formatValue(entry.pet.value)}) | Job: ${entry.jobId} | Players: ${entry.players}`);
}

app.post('/notify', (req, res) => {
  try {
    addPetDetection(req.body);
    res.json({ ok: true, message: 'Pet notification received' });
  } catch (e) {
    console.error('Notify error:', e.message);
    res.status(500).json({ error: 'Failed to process notification' });
  }
});

app.get('/api/pets', (req, res) => {
  const minValue = parseInt(req.query.minValue || '0', 10);
  const search = (req.query.search || '').toLowerCase().trim();
  let filtered = recentPets.filter(p => (p.pet.value || 0) >= minValue);
  if (search) {
    filtered = filtered.filter(p => p.pet.name.toLowerCase().includes(search));
  }
  // Always sort by value desc
  filtered.sort((a, b) => (b.pet.value || 0) - (a.pet.value || 0));
  res.json({
    pets: filtered,
    count: filtered.length,
    totalTracked: recentPets.length
  });
});

app.get('/api/best', (req, res) => {
  if (recentPets.length === 0) return res.json({ best: null });
  const best = recentPets.reduce((prev, curr) => ((curr.pet.value || 0) > (prev.pet.value || 0) ? curr : prev));
  res.json({ best });
});

// ============================================
// API Routes (Hopper + extended)
// ============================================

app.get('/server', async (req, res) => {
  serverRequestHistory.push(Date.now());
  const size = parseInt(req.query.size) || 1;
  const username = req.headers['username'];
  if (!username) return res.status(400).send('Username header is required');
  activeBots.set(username, Date.now());
  if (size < 1 || size > 1000) return res.status(400).send('Size must be between 1 and 1000');

  while (dispensingLock) await new Promise(resolve => setTimeout(resolve, 10));
  dispensingLock = true;

  try {
    const availableServers = [...cachedServers].filter(id => !dispensedServers.has(id));
    if (availableServers.length < size) {
      dispensingLock = false;
      return res.status(503).send(`Not enough GaG2 servers: have ${availableServers.length}, requested ${size}`);
    }
    const freshAvailable = availableServers.filter(id => freshServers.has(id));
    const readyAvailable = availableServers.filter(id => !freshServers.has(id));
    const serversToDispense = [
      ...freshAvailable.slice(0, size),
      ...readyAvailable.slice(0, Math.max(0, size - freshAvailable.length))
    ].slice(0, size);

    const freshCount = serversToDispense.filter(id => freshServers.has(id)).length;
    const readyCount = serversToDispense.length - freshCount;
    const now = Date.now();
    serversToDispense.forEach(id => { dispensedServers.set(id, now); freshServers.delete(id); });
    dispensingLock = false;
    res.type('text/plain').send(serversToDispense.join('\n'));
    console.log(`[DISPENSED] ${size} GaG2 servers to ${username} (${freshCount} fresh, ${readyCount} ready) (Bots: ${activeBots.size})`);
  } catch (error) {
    dispensingLock = false;
    console.error('Error dispensing servers:', error);
    res.status(500).send('Error dispensing servers');
  }
});

app.get('/servers', (req, res) => {
  res.json({ totalCached: cachedServers.size, servers: Array.from(cachedServers) });
});

app.get('/stats', (req, res) => {
  const available = cachedServers.size - dispensedServers.size;
  const now = Date.now();
  let recyclingCount = 0;
  for (const [, timestamp] of dispensedServers.entries()) {
    if (now - timestamp < RECYCLE_TIME) recyclingCount++;
  }
  const readyCount = Math.max(0, available - freshServers.size);
  const timeSinceLastWipe = Math.floor((now - lastCacheWipe) / 1000);
  const timeUntilNextWipe = Math.floor((CACHE_WIPE_INTERVAL - (now - lastCacheWipe)) / 1000);
  const estDate = new Date(now - 5 * 60 * 60 * 1000);
  const estTime = estDate.toISOString().replace('T', ' ').substring(0, 19) + ' EST';

  const bestPet = recentPets.length > 0 ? recentPets.reduce((a, b) => (a.pet.value > b.pet.value ? a : b)) : null;

  res.set('Content-Type', 'application/json');
  res.send(JSON.stringify({
    pool: {
      totalServers: cachedServers.size,
      freshServers: freshServers.size,
      readyServers: readyCount,
      recyclingServers: recyclingCount,
      removedServers: removedServers.size,
      availableServers: available,
      dispensedServers: dispensedServers.size,
      cachedPerMin: cachedPerMin
    },
    pets: {
      totalTracked: recentPets.length,
      bestValue: bestPet ? bestPet.pet.value : 0,
      bestPetName: bestPet ? bestPet.pet.name : null,
      bestJobId: bestPet ? bestPet.jobId : null,
      uniqueServersWithPets: new Set(recentPets.map(p => p.jobId)).size
    },
    bots: activeBots.size,
    serverRequestsPerMin: serverRequestsPerMin,
    removeRequestsPerMin: removeRequestsPerMin,
    totalProxies: proxies.length,
    currentProxyFile: currentProxyFile,
    currentTimeEST: estTime,
    currentDelay: requestDelay,
    rateLimits: rateLimitCount,
    recycleTime: `${RECYCLE_TIME / 1000}s`,
    botTimeout: `${BOT_TIMEOUT / 1000}s`,
    cacheWipeInterval: '2 hours',
    timeSinceLastWipe: `${Math.floor(timeSinceLastWipe / 3600)}h ${Math.floor((timeSinceLastWipe % 3600) / 60)}m`,
    timeUntilNextWipe: `${Math.floor(timeUntilNextWipe / 3600)}h ${Math.floor((timeUntilNextWipe % 3600) / 60)}m`,
    uptime: Math.floor(process.uptime())
  }, null, 2));
});

app.get('/recycle', (req, res) => {
  const now = Date.now();
  let recycled = 0;
  for (const [jobId, timestamp] of dispensedServers.entries()) {
    if (now - timestamp >= RECYCLE_TIME) { dispensedServers.delete(jobId); recycled++; }
  }
  res.json({ message: 'Manual recycle completed', recycled, stillDispensed: dispensedServers.size, available: cachedServers.size - dispensedServers.size });
});

app.post('/remove', async (req, res) => {
  removeRequestHistory.push(Date.now());
  const username = req.headers['username'];
  const { jobid } = req.body;
  if (!username) return res.status(400).json({ error: 'Username header is required' });
  activeBots.set(username, Date.now());
  if (!jobid) return res.status(400).json({ error: 'jobid is required in request body' });

  while (dispensingLock) await new Promise(resolve => setTimeout(resolve, 10));
  dispensingLock = true;

  try {
    if (!cachedServers.has(jobid)) { dispensingLock = false; return res.status(404).json({ error: 'Server not found' }); }
    cachedServers.delete(jobid);
    dispensedServers.delete(jobid);
    freshServers.delete(jobid);
    removedServers.add(jobid);

    const availableServers = [...cachedServers].filter(id => !dispensedServers.has(id));
    if (availableServers.length === 0) { dispensingLock = false; return res.status(503).json({ error: 'No servers available' }); }

    const freshAvailable = availableServers.filter(id => freshServers.has(id));
    const newJobId = freshAvailable.length > 0 ? freshAvailable[0] : availableServers[0];
    dispensedServers.set(newJobId, Date.now());
    freshServers.delete(newJobId);
    dispensingLock = false;
    console.log(`[REMOVE] ${username} removed ${jobid}, got new: ${newJobId}`);
    res.json({ new_jobid: newJobId });
  } catch (error) {
    dispensingLock = false;
    console.error('Error in /remove:', error);
    res.status(500).json({ error: 'Error removing server' });
  }
});

app.get('/clear', (req, res) => {
  cachedServers.clear();
  dispensedServers.clear();
  freshServers.clear();
  removedServers.clear();
  recentPets = [];
  res.json({ message: 'All caches + pets cleared', totalServers: 0, pets: 0 });
});

app.get('/bots-online', (req, res) => {
  res.type('text/plain').send(activeBots.size.toString());
});

// ============================================
// BACKGROUND JOBS
// ============================================
setInterval(() => {
  const now = Date.now();
  let recycled = 0;
  for (const [jobId, timestamp] of dispensedServers.entries()) {
    if (now - timestamp >= RECYCLE_TIME) { dispensedServers.delete(jobid); recycled++; }
  }
  if (recycled > 0) console.log(`[AUTO-RECYCLE] ${recycled} GaG2 servers`);
}, 30000);

setInterval(() => {
  const now = Date.now();
  let removedBots = 0;
  for (const [username, lastSeen] of activeBots.entries()) {
    if (now - lastSeen > BOT_TIMEOUT) { activeBots.delete(username); removedBots++; }
  }
  if (removedBots > 0) console.log(`[BOT CLEANUP] Removed ${removedBots} inactive bots (Active: ${activeBots.size})`);
}, 60000);

setInterval(() => {
  const now = Date.now();
  const oneMinuteAgo = now - 60000;
  serverRequestHistory = serverRequestHistory.filter(ts => ts > oneMinuteAgo);
  serverRequestsPerMin = serverRequestHistory.length;
  removeRequestHistory = removeRequestHistory.filter(ts => ts > oneMinuteAgo);
  removeRequestsPerMin = removeRequestHistory.length;
  serverCountHistory = serverCountHistory.filter(entry => entry.timestamp > oneMinuteAgo);
  if (serverCountHistory.length > 0) {
    cachedPerMin = Math.max(0, cachedServers.size - serverCountHistory[0].count);
  }
  // Pet age cleanup
  recentPets = recentPets.filter(p => now - p.receivedAt < PET_MAX_AGE_MS);
}, 10000);

setInterval(() => {
  serverCountHistory.push({ timestamp: Date.now(), count: cachedServers.size });
}, 5000);

setInterval(() => {
  const wipePercentage = 0.80;
  const sizeBefore = cachedServers.size;
  const servers = Array.from(cachedServers);
  shuffleArray(servers);
  const keepCount = Math.floor(servers.length * (1 - wipePercentage));
  const toKeep = new Set(servers.slice(0, keepCount));
  cachedServers.clear();
  dispensedServers.clear();
  freshServers.clear();
  toKeep.forEach(id => { cachedServers.add(id); freshServers.add(id); });
  lastCacheWipe = Date.now();
  console.log(`[CACHE WIPE] GaG2 pool ${sizeBefore} -> ${cachedServers.size}`);
}, CACHE_WIPE_INTERVAL);

setInterval(() => {
  const total = cachedServers.size;
  if (total > SERVER_THRESHOLD) {
    if (!overThresholdSince) {
      overThresholdSince = Date.now();
      console.log(`[THRESHOLD] GaG2 servers (${total}) exceeded ${SERVER_THRESHOLD}, starting timer`);
    } else if (Date.now() - overThresholdSince >= THRESHOLD_DURATION) {
      console.log(`[THRESHOLD WIPE] Wiping all GaG2 caches`);
      cachedServers.clear();
      dispensedServers.clear();
      freshServers.clear();
      removedServers.clear();
      overThresholdSince = null;
      lastCacheWipe = Date.now();
    }
  } else {
    overThresholdSince = null;
  }
}, 60000);

// ============================================
// BEAUTIFUL DASHBOARD (self-contained HTML)
// ============================================
app.get('/', (req, res) => {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>GaG2 • Wild Pet Notifier + Hopper</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&family=Space+Grotesk:wght@500;600&display=swap');
    :root { --accent: #a855f7; }
    body { font-family: 'Inter', system_ui, sans-serif; }
    .font-display { font-family: 'Space Grotesk', 'Inter', sans-serif; }
    .pet-card { transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); }
    .pet-card:hover { transform: translateY(-4px); box-shadow: 0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1); }
    .value-badge { font-variant-numeric: tabular-nums; }
    .section-header { font-size: 13px; letter-spacing: -.5px; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
    .stat-value { font-variant-numeric: tabular-nums; }
    .dashboard-grid { scrollbar-width: thin; }
  </style>
</head>
<body class="bg-zinc-950 text-zinc-200">
  <div class="max-w-[1280px] mx-auto">
    <!-- NAV -->
    <nav class="border-b border-zinc-800 bg-zinc-950/80 backdrop-blur-lg sticky top-0 z-50">
      <div class="px-8 py-4 flex items-center justify-between">
        <div class="flex items-center gap-x-3">
          <div class="w-9 h-9 rounded-2xl bg-gradient-to-br from-violet-500 to-fuchsia-500 flex items-center justify-center">
            <i class="fa-solid fa-seedling text-white text-2xl"></i>
          </div>
          <div>
            <span class="font-display text-3xl font-semibold tracking-tighter">GaG2</span>
            <span class="text-xs px-2 py-0.5 rounded bg-zinc-800 text-violet-400 align-super">v2</span>
          </div>
          <div class="text-xs px-3 py-1 rounded-full bg-emerald-500/10 text-emerald-400 flex items-center gap-x-1.5">
            <div class="w-1.5 h-1.5 bg-emerald-400 rounded-full animate-pulse"></div>
            LIVE
          </div>
        </div>
        <div class="flex items-center gap-x-8 text-sm">
          <a href="#pets" class="hover:text-white transition-colors flex items-center gap-x-2 text-zinc-400"><i class="fa-solid fa-paw mr-1.5"></i> Wild Pets</a>
          <a href="#hopper" class="hover:text-white transition-colors flex items-center gap-x-2 text-zinc-400"><i class="fa-solid fa-server mr-1.5"></i> Hopper</a>
          <a href="#joiner" class="hover:text-white transition-colors flex items-center gap-x-2 text-zinc-400"><i class="fa-solid fa-rocket mr-1.5"></i> Auto Joiner</a>
          <div class="h-3 w-px bg-zinc-800"></div>
          <div class="flex items-center gap-x-2 text-xs">
            <div class="px-2.5 py-1 bg-zinc-900 rounded-xl flex items-center gap-x-2">
              <i class="fa-solid fa-robot text-emerald-400"></i>
              <span id="bots-count" class="font-mono font-medium">0</span>
            </div>
            <div class="px-2.5 py-1 bg-zinc-900 rounded-xl flex items-center gap-x-2">
              <i class="fa-solid fa-globe text-violet-400"></i>
              <span id="servers-count" class="font-mono font-medium">0</span>
            </div>
          </div>
        </div>
      </div>
    </nav>

    <!-- HERO STATS -->
    <div class="px-8 pt-8 pb-4">
      <div class="flex items-end justify-between mb-6">
        <div>
          <h1 class="font-display text-5xl font-semibold tracking-tighter">Wild Pet Radar</h1>
          <p class="text-zinc-400 mt-1">Real-time detections • One-click joins • GaG2 Hopper</p>
        </div>
        <div class="text-right">
          <div class="text-xs text-zinc-500">PLACE ID</div>
          <div class="font-mono text-sm text-violet-400">${PLACE_ID}</div>
        </div>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-5 gap-4">
        <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5">
          <div class="flex justify-between items-start">
            <div>
              <div class="text-xs text-zinc-500">SERVERS IN POOL</div>
              <div id="stat-total-servers" class="text-4xl font-semibold tabular-nums mt-1">0</div>
            </div>
            <i class="fa-solid fa-server text-3xl text-zinc-700"></i>
          </div>
          <div class="mt-3 text-xs"><span id="stat-fresh" class="text-emerald-400">0 fresh</span> • <span id="stat-available">0 available</span></div>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5">
          <div class="flex justify-between items-start">
            <div>
              <div class="text-xs text-zinc-500">WILD PETS TRACKED</div>
              <div id="stat-pets-tracked" class="text-4xl font-semibold tabular-nums mt-1 text-violet-400">0</div>
            </div>
            <i class="fa-solid fa-paw text-3xl text-violet-500/70"></i>
          </div>
          <div class="mt-3 text-xs text-zinc-400">Last 30 min • <span id="stat-best-value" class="font-medium text-white">$0</span> best</div>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5">
          <div class="flex justify-between items-start">
            <div>
              <div class="text-xs text-zinc-500">BEST CURRENT PET</div>
              <div id="stat-best-pet" class="text-2xl font-semibold mt-1 truncate">—</div>
            </div>
            <i class="fa-solid fa-tachometer-alt text-3xl text-amber-400"></i>
          </div>
          <div class="mt-1 text-xs"><span id="stat-best-job" class="font-mono text-amber-300/80">—</span></div>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5">
          <div class="flex justify-between items-start">
            <div>
              <div class="text-xs text-zinc-500">ACTIVE BOTS</div>
              <div id="stat-active-bots" class="text-4xl font-semibold tabular-nums mt-1">0</div>
            </div>
            <i class="fa-solid fa-users text-3xl text-emerald-400"></i>
          </div>
          <div class="mt-3 text-xs text-emerald-400">Connected to hopper</div>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 hidden lg:block">
          <div class="text-xs text-zinc-500 mb-2">HOPPER STATUS</div>
          <div class="flex items-center gap-x-2">
            <div class="px-3 py-1 rounded-2xl bg-emerald-500/10 text-emerald-400 text-xs flex items-center gap-x-1.5">
              <i class="fa-solid fa-sync fa-spin"></i>
              <span>SCRAPING</span>
            </div>
          </div>
          <div class="text-[10px] text-zinc-500 mt-2">Adaptive proxy rotation active</div>
        </div>
      </div>
    </div>

    <!-- WILD PETS SECTION -->
    <div id="pets" class="px-8 pt-4">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-x-3">
          <i class="fa-solid fa-paw text-violet-400 text-xl"></i>
          <h2 class="font-display text-2xl font-semibold tracking-tight">Wild Pets Detected</h2>
          <div id="pets-count-badge" class="px-3 py-px text-xs rounded-full bg-violet-500/10 text-violet-400 font-medium">0</div>
        </div>
        <div class="flex items-center gap-x-3">
          <div class="relative">
            <input id="search-input" type="text" placeholder="Search pet name..." 
                   class="bg-zinc-900 border border-zinc-800 focus:border-violet-500/50 transition-colors text-sm rounded-2xl pl-9 pr-4 py-2 w-64 outline-none">
            <i class="fa-solid fa-search absolute left-3.5 top-2.5 text-zinc-500 text-sm"></i>
          </div>
          <div class="flex items-center bg-zinc-900 border border-zinc-800 rounded-2xl px-1">
            <div class="px-3 text-xs text-zinc-400">Min $</div>
            <input id="min-value" type="number" value="0" class="bg-transparent w-20 text-sm font-mono outline-none px-2">
          </div>
          <button onclick="refreshPets()" 
                  class="px-4 py-2 text-sm flex items-center gap-x-2 bg-zinc-800 hover:bg-zinc-700 active:bg-zinc-600 transition-colors rounded-2xl">
            <i class="fa-solid fa-sync"></i>
            <span class="text-xs">Refresh</span>
          </button>
        </div>
      </div>

      <div id="pets-grid" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4 dashboard-grid max-h-[520px] overflow-auto pr-2">
        <!-- Populated by JS -->
      </div>
      <div id="no-pets" class="hidden text-center py-12 text-zinc-500">
        <i class="fa-solid fa-search text-4xl mb-3 opacity-40"></i>
        <p>No wild pets match your filters yet.<br>Run the notifier Lua in-game.</p>
      </div>
    </div>

    <!-- HOPPER SECTION -->
    <div id="hopper" class="px-8 pt-10">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-x-3">
          <i class="fa-solid fa-server text-emerald-400 text-xl"></i>
          <h2 class="font-display text-2xl font-semibold tracking-tight">GaG2 Server Hopper</h2>
        </div>
        <div class="flex gap-x-2">
          <button onclick="doRecycle()" class="px-4 py-2 text-xs bg-zinc-800 hover:bg-zinc-700 rounded-2xl flex items-center gap-x-2">
            <i class="fa-solid fa-redo"></i> <span>Recycle Now</span>
          </button>
          <button onclick="doClear()" class="px-4 py-2 text-xs bg-red-900/70 hover:bg-red-900 text-red-300 rounded-2xl flex items-center gap-x-2">
            <i class="fa-solid fa-trash"></i> <span>Clear All</span>
          </button>
        </div>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4" id="hopper-stats">
        <!-- JS populated stats cards -->
      </div>
    </div>

    <!-- AUTO JOINER INFO -->
    <div id="joiner" class="px-8 pt-10 pb-12">
      <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-8">
        <div class="flex gap-x-4">
          <div class="flex-1">
            <div class="flex items-center gap-x-3 mb-3">
              <i class="fa-solid fa-rocket text-amber-400"></i>
              <h3 class="font-display text-xl font-semibold">Auto Joiner Script</h3>
            </div>
            <p class="text-zinc-400 text-sm leading-relaxed">The <span class="font-mono text-amber-300">AutoJoiner.lua</span> polls this dashboard every few seconds. When a high-value wild pet is detected it automatically teleports you (or your alt) to that server using <span class="font-mono">TeleportToPlaceInstance</span>.</p>
            <div class="mt-4 flex gap-x-3">
              <a href="https://raw.githubusercontent.com/Unnamedj/Gag2/main/AutoJoiner.lua" target="_blank" 
                 class="inline-flex items-center px-5 py-2.5 text-sm bg-amber-400 hover:bg-amber-300 active:bg-amber-500 transition-colors text-zinc-950 font-semibold rounded-2xl">
                <i class="fa-solid fa-download mr-2"></i> Download AutoJoiner.lua
              </a>
              <button onclick="copyJoinerExample()" class="px-5 py-2.5 text-sm border border-zinc-700 hover:bg-zinc-800 rounded-2xl flex items-center">
                Copy example config
              </button>
            </div>
          </div>
          <div class="w-px bg-zinc-800 self-stretch"></div>
          <div class="flex-1 text-xs text-zinc-400 space-y-2 pt-1">
            <div><span class="font-medium text-white">How it works:</span> Set your server URL in the Lua, run it in executor. It joins the current #1 best pet server automatically.</div>
            <div class="pt-1">Pro tip: Combine with the in-game <span class="font-mono">WildPetWebhook.lua</span> (set both webhookUrl + webUrl) for full automation — detect → notify → auto join best ones.</div>
          </div>
        </div>
      </div>
    </div>

  </div>

  <script>
    // Tailwind script
    function initTailwind() {
      document.documentElement.style.setProperty('--accent', '#a855f7');
    }

    let currentPets = [];
    let pollInterval = null;

    function timeAgo(ts) {
      const diff = Date.now() - ts;
      if (diff < 60000) return Math.floor(diff/1000) + 's ago';
      if (diff < 3600000) return Math.floor(diff/60000) + 'm ago';
      return Math.floor(diff/3600000) + 'h ago';
    }

    function getPetEmoji(name) {
      const n = name.toLowerCase();
      if (n.includes('frog')) return '🐸';
      if (n.includes('bunny') || n.includes('rabbit')) return '🐰';
      if (n.includes('owl')) return '🦉';
      if (n.includes('raccoon') || n.includes('racoon')) return '🦝';
      if (n.includes('gnome')) return '🧙';
      if (n.includes('bird')) return '🐦';
      if (n.includes('snail')) return '🐌';
      if (n.includes('fox')) return '🦊';
      if (n.includes('deer')) return '🦌';
      if (n.includes('squirrel')) return '🐿️';
      if (n.includes('golden')) return '✨';
      if (n.includes('rainbow')) return '🌈';
      return '🐾';
    }

    function valueColor(val) {
      if (val >= 100000000) return 'bg-red-500/90 text-white'; // 100M+
      if (val >= 10000000) return 'bg-orange-500/90 text-white'; // 10M+
      if (val >= 1000000) return 'bg-amber-400 text-zinc-950'; // 1M+
      if (val >= 100000) return 'bg-yellow-400 text-zinc-950';
      return 'bg-zinc-700 text-zinc-300';
    }

    async function fetchStats() {
      try {
        const res = await fetch('/stats');
        const data = await res.json();

        // Update hero stats
        document.getElementById('stat-total-servers').innerText = data.pool.totalServers.toLocaleString();
        document.getElementById('stat-fresh').innerHTML = data.pool.freshServers + ' fresh';
        document.getElementById('stat-available').innerHTML = data.pool.availableServers + ' available';
        document.getElementById('stat-pets-tracked').innerText = data.pets.totalTracked;
        document.getElementById('stat-best-value').innerText = '$' + (data.pets.bestValue ? (data.pets.bestValue / 1000000).toFixed(1) + 'M' : '0');
        document.getElementById('stat-active-bots').innerText = data.bots;
        document.getElementById('bots-count').innerText = data.bots;
        document.getElementById('servers-count').innerText = data.pool.totalServers.toLocaleString();

        if (data.pets.bestPetName) {
          document.getElementById('stat-best-pet').innerHTML = getPetEmoji(data.pets.bestPetName) + ' ' + data.pets.bestPetName;
          document.getElementById('stat-best-job').innerText = data.pets.bestJobId ? data.pets.bestJobId.substring(0, 12) + '...' : '';
        }

        // Hopper stats grid
        const hopperEl = document.getElementById('hopper-stats');
        hopperEl.innerHTML = `
          <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4">
            <div class="text-xs text-zinc-500">TOTAL CACHED</div>
            <div class="text-3xl font-semibold tabular-nums mt-1">${data.pool.totalServers.toLocaleString()}</div>
          </div>
          <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4">
            <div class="text-xs text-zinc-500">FRESH / READY</div>
            <div class="text-3xl font-semibold tabular-nums mt-1">${data.pool.freshServers} <span class="text-xs text-emerald-400">/ ${data.pool.readyServers}</span></div>
          </div>
          <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4">
            <div class="text-xs text-zinc-500">RECYCLING</div>
            <div class="text-3xl font-semibold tabular-nums mt-1 text-amber-400">${data.pool.recyclingServers}</div>
          </div>
          <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4">
            <div class="text-xs text-zinc-500">BOTS ONLINE</div>
            <div class="text-3xl font-semibold tabular-nums mt-1">${data.bots}</div>
          </div>
          <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4">
            <div class="text-xs text-zinc-500">PROXIES</div>
            <div class="text-3xl font-semibold tabular-nums mt-1">${data.totalProxies}</div>
            <div class="text-[10px] text-zinc-500">${data.currentProxyFile}</div>
          </div>
          <div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4">
            <div class="text-xs text-zinc-500">DELAY / RATE LIMITS</div>
            <div class="text-xl font-semibold tabular-nums mt-1">${data.currentDelay}ms <span class="text-xs text-red-400">(${data.rateLimits} 429s)</span></div>
          </div>
        `;
      } catch(e) { console.error('Stats fetch failed', e); }
    }

    async function fetchPets() {
      try {
        const minVal = document.getElementById('min-value').value || 0;
        const search = document.getElementById('search-input').value || '';
        const res = await fetch("/api/pets?minValue=" + minVal + "&search=" + encodeURIComponent(search));
        const data = await res.json();
        currentPets = data.pets || [];

        const grid = document.getElementById('pets-grid');
        const noPets = document.getElementById('no-pets');
        grid.innerHTML = '';

        document.getElementById('pets-count-badge').innerText = data.count;

        if (currentPets.length === 0) {
          noPets.classList.remove('hidden');
          return;
        } else {
          noPets.classList.add('hidden');
        }

        currentPets.forEach(pet => {
          const val = pet.pet.value || 0;
          const card = document.createElement('div');
          card.className = `pet-card bg-zinc-900 border border-zinc-800 rounded-3xl p-5 flex flex-col`;

          const emoji = getPetEmoji(pet.pet.name);
          const timeLeft = pet.pet.time || 'Active';
          const ago = timeAgo(pet.receivedAt);

          card.innerHTML = `
            <div class="flex justify-between items-start">
              <div class="flex items-center gap-x-3">
                <div class="text-4xl">${emoji}</div>
                <div>
                  <div class="font-semibold text-lg tracking-tight">${pet.pet.name}</div>
                  <div class="text-xs text-zinc-500">${timeLeft}</div>
                </div>
              </div>
              <div class="px-3 py-1 text-xs font-bold rounded-2xl value-badge ${valueColor(val)}">
                $${formatValueForJS(val)}
              </div>
            </div>

            <div class="mt-auto pt-4 flex items-end justify-between text-xs">
              <div>
                <div class="text-zinc-400">Job ID</div>
                <div class="font-mono text-violet-300 text-[10px] tracking-tighter">${pet.jobId}</div>
              </div>
              <div class="text-right">
                <div class="text-emerald-400">${pet.players}/${pet.maxPlayers || '?'}</div>
                <div class="text-[10px] text-zinc-500">${ago}</div>
              </div>
            </div>

            <div class="mt-4 grid grid-cols-2 gap-2">
              <button onclick="copyJoinCommand('${pet.jobId}', ${pet.placeId || ${PLACE_ID}})" 
                      class="col-span-1 py-2 text-xs bg-violet-600 hover:bg-violet-500 active:bg-violet-700 transition-colors rounded-2xl font-medium flex items-center justify-center gap-x-1.5">
                <i class="fa-solid fa-copy"></i> <span>COPY JOIN</span>
              </button>
              <button onclick="showJoinModal('${pet.jobId}', '${pet.pet.name}', ${val}, '${pet.placeId || ${PLACE_ID}}')" 
                      class="col-span-1 py-2 text-xs border border-zinc-700 hover:bg-zinc-800 rounded-2xl font-medium flex items-center justify-center gap-x-1.5">
                <i class="fa-solid fa-rocket"></i> <span>JOIN NOW</span>
              </button>
            </div>
          `;
          grid.appendChild(card);
        });
      } catch(e) {
        console.error('Pets fetch error', e);
      }
    }

    function formatValueForJS(v) {
      if (!v || v <= 0) return '0';
      if (v >= 1e12) return (v/1e12).toFixed(2)+'T';
      if (v >= 1e9) return (v/1e9).toFixed(2)+'B';
      if (v >= 1e6) return (v/1e6).toFixed(1)+'M';
      if (v >= 1e3) return (v/1e3).toFixed(0)+'K';
      return v.toString();
    }

    function copyJoinCommand(jobId, placeId) {
      const cmd = `game:GetService("TeleportService"):TeleportToPlaceInstance(${placeId}, "${jobId}")`;
      navigator.clipboard.writeText(cmd).then(() => {
        const origText = event.currentTarget ? event.currentTarget.innerHTML : '';
        const btns = document.querySelectorAll('button');
        // Simple toast
        const toast = document.createElement('div');
        toast.className = 'fixed bottom-6 left-1/2 -translate-x-1/2 bg-zinc-800 text-xs px-5 py-2 rounded-3xl shadow-xl border border-zinc-700 flex items-center gap-x-2 z-[999]';
        toast.innerHTML = `<i class="fa-solid fa-check text-emerald-400"></i> <span>Copied teleport command</span>`;
        document.body.appendChild(toast);
        setTimeout(() => toast.remove(), 2200);
      }).catch(() => {
        prompt('Copy this Lua command:', cmd);
      });
    }

    function showJoinModal(jobId, petName, value, placeId) {
      const modal = document.createElement('div');
      modal.className = 'fixed inset-0 bg-black/70 flex items-center justify-center z-[999]';
      modal.innerHTML = `
        <div onclick="event.target.remove()" class="absolute inset-0"></div>
        <div onclick="event.target.closest('.modal-content').classList.contains('modal-content') && event.target.remove()" class="modal-content relative bg-zinc-900 border border-zinc-700 rounded-3xl w-full max-w-md mx-4 p-7">
          <div class="flex justify-between items-start">
            <div>
              <div class="text-xs text-zinc-400">READY TO JOIN</div>
              <div class="text-2xl font-semibold tracking-tight mt-1">${getPetEmoji(petName)} ${petName}</div>
              <div class="text-amber-400 font-mono text-sm mt-px">$${formatValueForJS(value)}</div>
            </div>
            <button onclick="this.closest('.fixed').remove()" class="text-zinc-400 hover:text-white">✕</button>
          </div>

          <div class="my-6 p-4 bg-zinc-950 border border-zinc-800 rounded-2xl text-xs font-mono break-all">
            game:GetService("TeleportService"):TeleportToPlaceInstance(${placeId}, "${jobId}")
          </div>

          <div class="flex gap-x-3">
            <button onclick="copyJoinCommand('${jobId}', ${placeId}); this.closest('.fixed').remove();" 
                    class="flex-1 py-3 bg-violet-600 hover:bg-violet-500 rounded-2xl text-sm font-semibold">COPY LUA COMMAND</button>
            <button onclick="window.open('https://www.roblox.com/games/${placeId}/Grow-a-Garden-2?jobId=${jobId}', '_blank'); this.closest('.fixed').remove();" 
                    class="flex-1 py-3 border border-zinc-700 hover:bg-zinc-800 rounded-2xl text-sm font-semibold">OPEN IN BROWSER</button>
          </div>
          <div class="text-center text-[10px] text-zinc-500 mt-4">Run the command in your executor while in a different server or lobby</div>
        </div>
      `;
      document.body.appendChild(modal);
    }

    function copyJoinerExample() {
      const example = `-- AutoJoiner.lua config example
local API_BASE = "http://YOUR_SERVER_IP:8080"
local MIN_VALUE = 500000  -- only join pets worth $500k+
local POLL_INTERVAL = 8   -- seconds
-- ... (full script in repo)`;
      navigator.clipboard.writeText(example).then(() => alert('Example config copied!'));
    }

    async function refreshPets() {
      await fetchPets();
    }

    async function doRecycle() {
      if (!confirm('Recycle old dispensed servers?')) return;
      const res = await fetch('/recycle');
      const data = await res.json();
      alert('Recycled ' + data.recycled + ' servers');
      fetchStats();
    }

    async function doClear() {
      if (!confirm('This will clear ALL server caches and pet detections. Continue?')) return;
      await fetch('/clear');
      fetchStats();
      fetchPets();
    }

    function setupFilters() {
      const search = document.getElementById('search-input');
      const minVal = document.getElementById('min-value');

      let debounce;
      function trigger() {
        clearTimeout(debounce);
        debounce = setTimeout(() => fetchPets(), 280);
      }

      search.addEventListener('input', trigger);
      minVal.addEventListener('input', trigger);
      minVal.addEventListener('change', trigger);
    }

    async function initDashboard() {
      initTailwind();
      setupFilters();

      // Initial loads
      await fetchStats();
      await fetchPets();

      // Live polling
      if (pollInterval) clearInterval(pollInterval);
      pollInterval = setInterval(() => {
        fetchStats();
        fetchPets();
      }, 8500);

      // Keyboard shortcut
      document.addEventListener('keydown', function(e) {
        if (e.key === '/' && document.activeElement.tagName === 'BODY') {
          e.preventDefault();
          document.getElementById('search-input').focus();
        }
      });

      console.log('%c[GaG2] Dashboard initialized', 'color:#a855f7');
    }

    // Boot
    window.onload = initDashboard;
  </script>
</body>
</html>`;
  res.send(html);
});

// ============================================
// START SERVER + SCRAPERS
// ============================================
app.listen(PORT, () => {
  console.log(`GaG2 Wild Pet Notifier + Hopper running on http://localhost:${PORT}`);
  loadProxies();
  setTimeout(() => {
    console.log('Starting adaptive GaG2 server scrapers...');
    startScrapers(8);
  }, 1200);
});
