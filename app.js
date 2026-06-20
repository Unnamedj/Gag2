const express = require('express');
const axios = require('axios');
const fs = require('fs');
const { HttpsProxyAgent } = require('https-proxy-agent');

const app = express();
app.use(express.json());
const PORT = process.env.PORT || 8080;

const PLACE_ID = '97598239454123';

// Server pool
const cachedServers = new Set();
const dispensedServers = new Map();
const activeBots = new Map();
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
const BOT_TIMEOUT = 5 * 60 * 1000;
const CACHE_WIPE_INTERVAL = 2 * 60 * 60 * 1000;
let lastCacheWipe = Date.now();

let currentProxyFile = 'proxies.txt';
let proxies = [];
let proxyOrder = [];
let proxyOrderIndex = 0;
let lastProxyUsed = null;

function loadProxies() {
  try {
    const data = fs.readFileSync(currentProxyFile, 'utf8');
    proxies = data.split('\n').map(l => l.trim()).filter(l => l !== '');
    console.log(`Loaded ${proxies.length} proxies`);
    resetProxyOrder();
  } catch (e) { proxies = []; }
}

function resetProxyOrder() {
  proxyOrder = proxies.slice();
  if (proxyOrder.length > 0) {
    for (let i = proxyOrder.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [proxyOrder[i], proxyOrder[j]] = [proxyOrder[j], proxyOrder[i]];
    }
    proxyOrderIndex = 0;
  }
}

function getNextProxy() {
  if (proxies.length === 0) return null;
  const p = proxyOrder[proxyOrderIndex];
  proxyOrderIndex = (proxyOrderIndex + 1) % proxyOrder.length;
  lastProxyUsed = p;
  return p;
}

function parseProxy(s) {
  if (!s) return null;
  if (s.includes('@')) {
    const [auth, hp] = s.split('@');
    const [host, port] = hp.split(':');
    const [u, p] = auth.split(':');
    return { host, port: parseInt(port), username: u, password: p };
  }
  const parts = s.split(':');
  if (parts.length === 4) return { host: parts[2], port: parseInt(parts[3]), username: parts[0], password: parts[1] };
  if (parts.length === 2) return { host: parts[0], port: parseInt(parts[1]) };
  return null;
}

async function fetchServers(url, proxyStr) {
  try {
    let cfg = { timeout: 8000, headers: {'User-Agent':'Mozilla/5.0'} };
    if (proxyStr) {
      const p = parseProxy(proxyStr);
      if (p) {
        const proxyUrl = p.username ? `http://${p.username}:${p.password}@${p.host}:${p.port}` : `http://${p.host}:${p.port}`;
        cfg.httpsAgent = new HttpsProxyAgent(proxyUrl);
        cfg.proxy = false;
      }
    }
    const r = await axios.get(url, cfg);
    if (requestDelay > MIN_DELAY) requestDelay = Math.max(MIN_DELAY, requestDelay-5);
    return r.data;
  } catch(e) {
    if (e.response?.status === 429) { rateLimitCount++; requestDelay = Math.min(MAX_DELAY, requestDelay+50); }
    return null;
  }
}

function processServers(data) {
  if (!data?.data) return [];
  const news = [];
  data.data.forEach(s => { if (s.id && !cachedServers.has(s.id)) { cachedServers.add(s.id); freshServers.add(s.id); news.push(s.id); } });
  return news;
}

const endpoints = [`https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&excludeFullGames=true&sortOrder=Asc`, `https://games.roblox.com/v1/games/${PLACE_ID}/servers/Public?limit=100&sortOrder=Desc`];

function getRandomEndpoint() { return endpoints[Math.floor(Math.random()*endpoints.length)]; }

async function scrapeServers(id) {
  while(true) {
    await new Promise(r => setTimeout(r, requestDelay));
    const data = await fetchServers(getRandomEndpoint(), getNextProxy());
    if (data) {
      const added = processServers(data);
      if (added.length) console.log(`[Scraper] +${added.length} (Total ${cachedServers.size})`);
    }
    await new Promise(r => setTimeout(r, 3000));
  }
}

function startScrapers(n=6){ for(let i=0;i<n;i++) setTimeout(()=>scrapeServers(i), i*300); }

// Pets
let recentPets = [];
const MAX_PETS = 100;
const PET_AGE = 30*60*1000;

function addPetDetection(d) {
  if(!d?.jobId || !d.pet) return;
  recentPets = recentPets.filter(p => !(p.jobId===d.jobId && p.pet.name===d.pet.name));
  recentPets.unshift({jobId:d.jobId, placeId:d.placeId||PLACE_ID, pet:d.pet, players:d.players||0, maxPlayers:d.maxPlayers||0, receivedAt:Date.now()});
  if(recentPets.length>MAX_PETS) recentPets.length=MAX_PETS;
  recentPets = recentPets.filter(p=>Date.now()-p.receivedAt < PET_AGE);
}

app.post('/notify',(req,res)=>{ addPetDetection(req.body); res.json({ok:true}); });
app.get('/api/pets',(req,res)=>{
  const min=parseInt(req.query.minValue||0);
  const q=(req.query.search||'').toLowerCase();
  let list=recentPets.filter(p=>(p.pet.value||0)>=min);
  if(q) list=list.filter(p=>p.pet.name.toLowerCase().includes(q));
  list.sort((a,b)=>(b.pet.value||0)-(a.pet.value||0));
  res.json({pets:list});
});
app.get('/api/best',(req,res)=> res.json({best: recentPets.length ? recentPets.reduce((a,b)=>(b.pet.value||0)>(a.pet.value||0)?b:a) : null }));

// Hopper
app.get('/server',async(req,res)=>{
  const size=parseInt(req.query.size)||1; const user=req.headers['username'];
  if(!user) return res.status(400).send('Username required');
  activeBots.set(user,Date.now());
  while(dispensingLock) await new Promise(r=>setTimeout(r,5));
  dispensingLock=true;
  const avail=[...cachedServers].filter(id=>!dispensedServers.has(id));
  if(avail.length<size){dispensingLock=false;return res.status(503).send('Not enough');}
  const chosen=[...avail.filter(id=>freshServers.has(id)).slice(0,size), ...avail.filter(id=>!freshServers.has(id)).slice(0,Math.max(0,size-avail.filter(id=>freshServers.has(id)).length))].slice(0,size);
  const now=Date.now(); chosen.forEach(id=>{dispensedServers.set(id,now);freshServers.delete(id);});
  dispensingLock=false; res.type('text/plain').send(chosen.join('\n'));
});
app.get('/stats',(req,res)=>{
  const avail=cachedServers.size-dispensedServers.size;
  const rec = [...dispensedServers.values()].filter(t=>Date.now()-t<RECYCLE_TIME).length;
  const best=recentPets.length?recentPets.reduce((a,b)=>(b.pet.value||0)>(a.pet.value||0)?b:a):null;
  res.json({pool:{totalServers:cachedServers.size,freshServers:freshServers.size,availableServers:avail,recyclingServers:rec},pets:{totalTracked:recentPets.length,bestValue:best?.pet.value||0,bestPetName:best?.pet.name||null,bestJobId:best?.jobId||null},bots:activeBots.size});
});

// Background
setInterval(()=>{ const now=Date.now(); for(const[id,t]of dispensedServers) if(now-t>=RECYCLE_TIME) dispensedServers.delete(id); },30000);
setInterval(()=>{ const now=Date.now(); for(const[u,t]of activeBots) if(now-t>BOT_TIMEOUT) activeBots.delete(u); },60000);
setInterval(()=>{ recentPets=recentPets.filter(p=>Date.now()-p.receivedAt<PET_AGE); },30000);

// CLEAN DASHBOARD
app.get('/',(req,res)=>{
  res.send(`<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GaG2 Dashboard</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css"><style>body{font-family:Inter,system-ui,sans-serif}.pet-card{transition:all .2s}.pet-card:hover{transform:translateY(-3px);box-shadow:0 10px 15px -3px rgb(0 0 0/.1)}.value-badge{font-variant-numeric:tabular-nums}</style></head><body class="bg-zinc-950 text-zinc-200"><div class="max-w-[1200px] mx-auto p-6"><div class="flex justify-between mb-8"><div class="flex items-center gap-x-3"><div class="w-10 h-10 rounded-2xl bg-gradient-to-br from-violet-500 to-fuchsia-500 flex items-center justify-center"><i class="fa-solid fa-seedling text-white text-2xl"></i></div><div><span class="font-bold text-3xl">GaG2</span><span class="text-xs px-2 py-0.5 rounded bg-zinc-800 text-violet-400">Dashboard</span></div></div><div class="flex gap-x-3 text-sm"><div class="px-3 py-1 bg-zinc-900 rounded-xl flex items-center gap-x-2"><i class="fa-solid fa-robot text-emerald-400"></i><span id="bots-count" class="font-mono">0</span></div><div class="px-3 py-1 bg-zinc-900 rounded-xl flex items-center gap-x-2"><i class="fa-solid fa-server text-violet-400"></i><span id="servers-count" class="font-mono">0</span></div></div></div><div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8"><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5"><div class="text-xs text-zinc-500">SERVERS</div><div id="stat-total-servers" class="text-4xl font-semibold">0</div></div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5"><div class="text-xs text-zinc-500">PETS</div><div id="stat-pets-tracked" class="text-4xl font-semibold text-violet-400">0</div></div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5"><div class="text-xs text-zinc-500">BEST PET</div><div id="stat-best-pet" class="text-2xl font-semibold">—</div></div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-5"><div class="text-xs text-zinc-500">BOTS</div><div id="stat-active-bots" class="text-4xl font-semibold">0</div></div></div><div class="flex justify-between mb-4"><h2 class="font-semibold text-xl flex items-center gap-x-2"><i class="fa-solid fa-paw text-violet-400"></i> Recent Pets</h2><div class="flex gap-x-2"><input id="search-input" placeholder="Search..." class="bg-zinc-900 border border-zinc-800 rounded-2xl px-4 py-2 text-sm w-64"><input id="min-value" type="number" value="0" class="bg-zinc-900 border border-zinc-800 rounded-2xl px-3 py-2 text-sm w-24"></div></div><div id="pets-grid" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4"></div><div id="no-pets" class="hidden text-center py-12 text-zinc-500">No pets yet</div><div class="mt-10"><h2 class="font-semibold text-xl mb-4 flex items-center gap-x-2"><i class="fa-solid fa-server text-emerald-400"></i> Hopper</h2><div id="hopper-stats" class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4"></div></div></div><script>function initTailwind(){document.documentElement.style.setProperty('--accent','#a855f7')}function formatValue(v){if(!v||v<=0)return'0';if(v>=1e12)return(v/1e12).toFixed(2)+'T';if(v>=1e9)return(v/1e9).toFixed(2)+'B';if(v>=1e6)return(v/1e6).toFixed(1)+'M';if(v>=1e3)return(v/1e3).toFixed(0)+'K';return v}function getPetEmoji(n){n=n.toLowerCase();if(n.includes('frog'))return'🐸';if(n.includes('bunny')||n.includes('rabbit'))return'🐰';if(n.includes('owl'))return'🦉';if(n.includes('raccoon'))return'🦝';if(n.includes('gnome'))return'🧙';if(n.includes('fox'))return'🦊';if(n.includes('deer'))return'🦌';if(n.includes('squirrel'))return'🐿️';if(n.includes('golden'))return'✨';return'🐾'}function valueColor(v){if(v>=1e8)return'bg-red-500/90 text-white';if(v>=1e7)return'bg-orange-500/90 text-white';if(v>=1e6)return'bg-amber-400 text-zinc-950';if(v>=1e5)return'bg-yellow-400 text-zinc-950';return'bg-zinc-700 text-zinc-300'}async function fetchStats(){try{const r=await fetch('/stats');const d=await r.json();document.getElementById('stat-total-servers').innerText=d.pool.totalServers;document.getElementById('stat-pets-tracked').innerText=d.pets.totalTracked;document.getElementById('stat-active-bots').innerText=d.bots;document.getElementById('bots-count').innerText=d.bots;document.getElementById('servers-count').innerText=d.pool.totalServers;if(d.pets.bestPetName)document.getElementById('stat-best-pet').innerHTML=getPetEmoji(d.pets.bestPetName)+' '+d.pets.bestPetName;document.getElementById('hopper-stats').innerHTML=`<div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4"><div class="text-xs text-zinc-500">TOTAL</div><div class="text-3xl font-semibold">${d.pool.totalServers}</div></div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4"><div class="text-xs text-zinc-500">FRESH</div><div class="text-3xl font-semibold">${d.pool.freshServers}</div></div><div class="bg-zinc-900 border border-zinc-800 rounded-3xl p-4"><div class="text-xs text-zinc-500">RECYCLING</div><div class="text-3xl font-semibold text-amber-400">${d.pool.recyclingServers||0}</div></div>`}catch(e){}}async function fetchPets(){try{const min=document.getElementById('min-value').value||0;const q=document.getElementById('search-input').value||'';const r=await fetch(`/api/pets?minValue=${min}&search=${encodeURIComponent(q)}`);const d=await r.json();const grid=document.getElementById('pets-grid');const empty=document.getElementById('no-pets');grid.innerHTML='';if(!d.pets||d.pets.length===0){empty.classList.remove('hidden');return}empty.classList.add('hidden');d.pets.forEach(p=>{const c=document.createElement('div');c.className='pet-card bg-zinc-900 border border-zinc-800 rounded-3xl p-5';const e=getPetEmoji(p.pet.name);c.innerHTML=`<div class="flex justify-between"><div class="flex items-center gap-x-3"><div class="text-4xl">${e}</div><div class="font-semibold">${p.pet.name}</div></div><div class="px-3 py-1 text-xs font-bold rounded-2xl ${valueColor(p.pet.value)}">$${formatValue(p.pet.value)}</div></div><div class="mt-4 flex justify-between text-xs"><div class="font-mono text-violet-300 text-xs">${p.jobId}</div><div class="text-emerald-400">${p.players}/${p.maxPlayers||'?'}</div></div><div class="mt-4 grid grid-cols-2 gap-2"><button onclick="copyJoin('${p.jobId}',${p.placeId||PLACE_ID})" class="py-2 text-xs bg-violet-600 hover:bg-violet-500 rounded-2xl">COPY</button><button onclick="joinNow('${p.jobId}',${p.placeId||PLACE_ID})" class="py-2 text-xs border border-zinc-700 hover:bg-zinc-800 rounded-2xl">JOIN</button></div>`;grid.appendChild(c)})}catch(e){}}function copyJoin(j,p){const cmd=`game:GetService("TeleportService"):TeleportToPlaceInstance(${p},"${j}")`;navigator.clipboard.writeText(cmd);const t=document.createElement('div');t.className='fixed bottom-6 left-1/2 -translate-x-1/2 bg-zinc-800 px-4 py-2 rounded text-xs';t.innerText='Copied!';document.body.appendChild(t);setTimeout(()=>t.remove(),1400)}function joinNow(j,p){prompt('Run this:',`game:GetService("TeleportService"):TeleportToPlaceInstance(${p},"${j}")`)}function setup(){const s=document.getElementById('search-input');const m=document.getElementById('min-value');let t;const trig=()=>{clearTimeout(t);t=setTimeout(fetchPets,250)};s.oninput=trig;m.oninput=trig}async function init(){initTailwind();setup();await fetchStats();await fetchPets();setInterval(()=>{fetchStats();fetchPets()},8000)}window.onload=init;</script></body></html>`);
});

app.listen(PORT, () => {
  console.log('GaG2 Dashboard running on port', PORT);
  loadProxies();
  setTimeout(()=>startScrapers(6),600);
});