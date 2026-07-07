/**
 * TrollVNC Group Control - Unified Launcher
 * Runs: Relay Server (WS:8183 + HTTP:9527) + Static File Server (HTTP:7000)
 *
 * Usage: node launcher.js
 *        or double-click start.bat
 *
 * Features:
 *   - Auto-kills old services occupying ports 7000/9527/8183
 *   - Auto-opens browser on successful start
 */

var spawn  = require('child_process').spawn;
var exec   = require('child_process').execSync;
var http   = require('http');
var fs     = require('fs');
var path   = require('path');
var os     = require('os');

// ── Config ──
var BASE_DIR     = path.resolve(__dirname, '..');
var RELAY_DIR    = path.join(__dirname, 'relay-server');
var RELAY_LOG    = path.join(__dirname, 'relay.log');
var STATIC_PORT  = 7000;
var ALL_PORTS    = [9527, 8183, 7000];       // all ports we use
var DASH_URL     = 'http://localhost:' + STATIC_PORT + '/group-control/pc_group_control.html';

// ── MIME ──
var MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
};

// ══════════════════════════════════════════════
//  Helper: check port availability
// ══════════════════════════════════════════════
function checkPort(port) {
  return new Promise(function(resolve) {
    var s = http.createServer();
    s.listen(port, '0.0.0.0', function() { var ok = true; s.close(function() { resolve(ok); }); });
    s.on('error', function() { resolve(false); });
  });
}

// ══════════════════════════════════════════════
//  Helper: find PIDs using a given port (Windows)
// ══════════════════════════════════════════════
function findPidsOnPort(port) {
  try {
    var out = exec('netstat -ano', { encoding: 'utf8' });
    var pids = {};
    var lines = out.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf(':' + port + ' ') !== -1 && lines[i].indexOf('LISTEN') !== -1) {
        var m = lines[i].match(/\s+(\d+)\s*$/);
        if (m) pids[m[1]] = true;
      }
    }
    return Object.keys(pids);
  } catch(e) {
    return [];
  }
}

// ══════════════════════════════════════════════
//  Step 0: Check & auto-kill old services
// ══════════════════════════════════════════════

console.log('');
console.log('========================================');
console.log('  TrollVNC Group Control - Launcher v2');
console.log('========================================');
console.log('');

console.log('[Step 1/4] Checking ports ...');

Promise.all(ALL_PORTS.map(checkPort)).then(function(results) {
  var blocked = [];
  for (var i = 0; i < ALL_PORTS.length; i++) {
    if (!results[i]) blocked.push(ALL_PORTS[i]);
  }

  // ── Auto-kill old services ──
  if (blocked.length > 0) {
    console.log('  Ports occupied: ' + blocked.join(', '));
    console.log('  Auto-closing old services ...');

    for (var bi = 0; bi < blocked.length; bi++) {
      var pids = findPidsOnPort(blocked[bi]);
      if (pids.length > 0) {
        console.log('  Port ' + blocked[bi] + ': killing PID(s): ' + pids.join(', '));
        for (var pi = 0; pi < pids.length; pi++) {
          try { exec('taskkill /F /PID ' + pids[pi], { encoding: 'utf8' }); } catch(killErr) {}
        }
      }
    }

    console.log('  Waiting for ports to release ...');
    return new Promise(function(r) { setTimeout(r, 2500); })
      .then(function() { return Promise.all(ALL_PORTS.map(checkPort)); });
  }

  return results;

}).then(function(finalResults) {
  var stillBlocked = [];
  for (var j = 0; j < ALL_PORTS.length; j++) {
    if (!finalResults[j]) stillBlocked.push(ALL_PORTS[j]);
  }
  if (stillBlocked.length > 0) {
    console.log('\n  [ERROR] Could not free ports: ' + stillBlocked.join(', '));
    console.log('  Manually run: netstat -ano | findstr :' + stillBlocked[0]);
    process.exit(1);
  }

  console.log('  OK - All ports free (' + ALL_PORTS.join(', ') + ')');

  // ══════════════════════════════════════════════
  //  Step 2: Install ws if needed
  // ══════════════════════════════════════════════
  console.log('\n[Step 2/4] Checking dependencies ...');

  if (!fs.existsSync(path.join(RELAY_DIR, 'node_modules', 'ws'))) {
    console.log('  Installing ws module ...');
    try {
      exec('npm install --production', { cwd: RELAY_DIR, stdio: 'inherit' });
    } catch(e) {
      console.error('  [ERROR] npm install failed:', e.message);
      process.exit(1);
    }
  } else {
    console.log('  Dependencies OK');
  }

  // ══════════════════════════════════════════════
  //  Step 3: Start relay server
  // ══════════════════════════════════════════════
  console.log('\n[Step 3/4] Starting relay server (WS:8183 + HTTP:9527) ...');

  var relayProcess = spawn(process.argv[0], ['relay-server.js'], {
    cwd: RELAY_DIR,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  var logStream = fs.createWriteStream(RELAY_LOG, { flags: 'w' });
  relayProcess.stdout.on('data', function(d) { process.stdout.write(d); logStream.write(d); });
  relayProcess.stderr.on('data', function(d) { process.stderr.write(d); logStream.write(d); });
  relayProcess.on('exit', function(code) {
    logStream.end();
    if (code !== null && code !== 0) console.log('\n[Relay] Process exited (code=' + code + ')');
  });
  relayProcess.on('error', function(err) { console.error('[ERROR] Failed to start relay:', err.message); });

  // ══════════════════════════════════════════════
  //  Step 4: Start static file server
  // ══════════════════════════════════════════════
  console.log('[Step 4/4] Starting web server (HTTP:' + STATIC_PORT + ') ...');

  var BASE_URL = process.env.TROLLVNC_ROOT || undefined;

  var server = http.createServer(function(req, res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

    var urlPath = req.url === '/' ? '/group-control/pc_group_control.html' : req.url;
    var filePath = path.join(BASE_URL || BASE_DIR, urlPath.split('?')[0]);

    var ext = path.extname(filePath).toLowerCase();
    var contentType = MIME[ext] || 'application/octet-stream';

    fs.readFile(filePath, function(err, data) {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('404 Not Found: ' + urlPath);
        return;
      }
      res.writeHead(200, { 'Content-Type': contentType });
      res.end(data);
    });
  });

  server.listen(STATIC_PORT, '0.0.0.0', function() {
    console.log('');
    console.log('+--------------------------------------------+');
    console.log('|          All Services Running!              |');
    console.log('+--------------------------------------------+');
    console.log('');
    console.log('  Relay WS  : ws://' + getLocalIp() + ':8183');
    console.log('  Relay HTTP: http://' + getLocalIp() + ':9527');
    console.log('  Web UI    : http://localhost:' + STATIC_PORT + '/group-control/pc_group_control.html');
    console.log('');

    // ★ Auto open browser
    setTimeout(function() {
      console.log('  Opening browser ...');
      openBrowser(DASH_URL);
    }, 500);

    console.log('  Press Ctrl+C to stop all services.');
    console.log('');
  });

  server.on('error', function(err) {
    if (err.code === 'EADDRINUSE') {
      console.error('\n[ERROR] Port ' + STATIC_PORT + ' is in use!');
      console.error('  Try closing other instances first.');
    } else {
      console.error('\n[ERROR]', err.message);
    }
    process.exit(1);
  });

  // ══════════════════════════════════════════════
  //  Shutdown
  // ══════════════════════════════════════════════
  function shutdown() {
    console.log('\nShutting down ...');
    try { server.close(); } catch(e) {}
    try { relayProcess.kill('SIGTERM'); } catch(e) {}
    setTimeout(function() { try { relayProcess.kill('SIGKILL'); } catch(e) {} }, 3000);
    setTimeout(function() { process.exit(0); }, 5000);
  }

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

}).catch(function(err) {
  console.error('[FATAL]', err.message);
  process.exit(1);
});

// ══════════════════════════════════════════════
//  Helper: Get local LAN IP address
// ══════════════════════════════════════════════
function getLocalIp() {
  try {
    var nets = os.networkInterfaces();
    var names = Object.keys(nets);
    for (var n = 0; n < names.length; n++) {
      var addrs = nets[names[n]];
      for (var a = 0; a < addrs.length; a++) {
        var addr = addrs[a];
        // skip internal and non-IPv4
        if (addr.family !== 'IPv4' || addr.internal !== false) continue;
        // prefer common LAN ranges
        if (addr.address.indexOf('192.168.') === 0 ||
            addr.address.indexOf('10.') === 0 ||
            addr.address.indexOf('172.') === 0) {
          return addr.address;
        }
      }
    }
  } catch(e) {}
  return 'localhost';
}

// ══════════════════════════════════════════════
//  Helper: Open URL in default browser
// ══════════════════════════════════════════════
function openBrowser(url) {
  var cmd;
  switch (process.platform) {
    case 'win32':
      // Use `start` command — works even without full path to browser
      spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' }).unref();
      break;
    case 'darwin':
      spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
      break;
    default:
      // Linux: xdg-open or fallback
      spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
      break;
  }
}
