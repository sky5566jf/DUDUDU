#!/usr/bin/env node
/**
 * test-welcome.js v2 — 修复状态检查时机问题
 * 用法：node test-welcome.js
 */

const WebSocket = require('ws');
const http       = require('http');
const { spawn }  = require('child_process');
const path       = require('path');

const WS_PORT   = 8183;
const HTTP_PORT = 9527;
const SERVER_JS = path.join(__dirname, 'relay-server.js');

let serverProc = null;
let passed = 0;
let failed = 0;
const activeWs = [];

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function expect(name, condition) {
  if (condition) {
    console.log(`  ✅ PASS: ${name}`);
    passed++;
  } else {
    console.log(`  ❌ FAIL: ${name}`);
    failed++;
  }
}

function startServer() {
  return new Promise((resolve, reject) => {
    serverProc = spawn('node', [SERVER_JS], {
      cwd: __dirname,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    serverProc.stdout.on('data', (d) => process.stdout.write(`[server] ${d}`));
    serverProc.stderr.on('data', (d) => process.stderr.write(`[server stderr] ${d}`));

    const deadline = Date.now() + 5000;
    const check = () => {
      const req = http.get(`http://localhost:${HTTP_PORT}/api/status`, (res) => {
        let body = '';
        res.on('data', d => body += d);
        res.on('end', () => {
          console.log('[test] Server is up');
          resolve();
        });
      });
      req.on('error', () => {
        if (Date.now() < deadline) return setTimeout(check, 200);
        reject(new Error('Server failed to start within 5s'));
      });
    };
    setTimeout(check, 500);
  });
}

function stopServer() {
  return new Promise((resolve) => {
    if (!serverProc) return resolve();
    serverProc.on('exit', () => { serverProc = null; resolve(); });
    serverProc.kill('SIGTERM');
    setTimeout(() => { if (serverProc) { serverProc.kill('SIGKILL'); serverProc = null; } resolve(); }, 3000);
  });
}

function connectWs(role, deviceId) {
  return new Promise((resolve) => {
    const url = `ws://localhost:${WS_PORT}/ws/${role}/${deviceId}?ts=${Date.now()}`;
    console.log(`[test] Connecting ${role}/${deviceId}...`);
    const ws = new WebSocket(url);
    let welcome = null;

    const timer = setTimeout(() => {
      console.log(`  ⚠️  Timeout waiting for welcome (${role}/${deviceId})`);
      ws.terminate();
      resolve({ role, deviceId, ws, welcome });
    }, 3000);

    ws.on('open', () => { /* open */ });

    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data);
        if (msg.type === 'welcome') {
          welcome = msg;
          clearTimeout(timer);
          console.log(`  ✅ ${role}/${deviceId} ← welcome: ${JSON.stringify(msg)}`);
          // 不关闭，保持连接
          setTimeout(() => resolve({ role, deviceId, ws, welcome }), 100);
        }
      } catch (e) { /* ignore */ }
    });

    ws.on('close', () => {
      clearTimeout(timer);
      resolve({ role, deviceId, ws, welcome });
    });

    ws.on('error', (err) => {
      clearTimeout(timer);
      console.log(`  ❌ ${role}/${deviceId} error: ${err.message}`);
      resolve({ role, deviceId, ws, welcome });
    });
  });
}

function checkStatus() {
  return new Promise((resolve) => {
    http.get(`http://localhost:${HTTP_PORT}/api/status`, (res) => {
      let body = '';
      res.on('data', d => body += d);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { resolve(null); }
      });
    }).on('error', () => resolve(null));
  });
}

async function run() {
  console.log('═══ TrollVNC Relay Server — Welcome Message Test v2 ═══\n');

  console.log('[1] Starting relay server...');
  try { await startServer(); } catch (e) { console.error(`❌ ${e.message}`); process.exit(1); }
  await sleep(500);

  // 2. 连接 master（保持连接）
  console.log('\n[2] Connecting master (keep alive)...');
  let r = await connectWs('master', 'test_master_001');
  expect('master receives welcome', r.welcome !== null);
  expect('master welcome.role = master', r.welcome && r.welcome.role === 'master');
  activeWs.push(r);

  // 3. 检查 status（master 还连着）
  console.log('\n[3] Checking status (master connected)...');
  let status = await checkStatus();
  console.log(`  status: masters=${status.masters.length}, slaves=${status.slaves.length}, browsers=${status.browsers}`);
  expect('status.masters.length = 1', status.masters.length === 1);

  // 4. 连接 slave（保持连接）
  console.log('\n[4] Connecting slave (keep alive)...');
  r = await connectWs('slave', 'test_slave_001');
  expect('slave receives welcome', r.welcome !== null);
  expect('slave welcome.role = slave', r.welcome && r.welcome.role === 'slave');
  activeWs.push(r);

  // 5. 检查 status（master + slave 都连着）
  console.log('\n[5] Checking status (master+slave connected)...');
  status = await checkStatus();
  console.log(`  status: masters=${status.masters.length}, slaves=${status.slaves.length}, browsers=${status.browsers}`);
  expect('status.masters.length = 1', status.masters.length === 1);
  expect('status.slaves.length = 1', status.slaves.length === 1);

  // 6. 连接 browser（保持连接）
  console.log('\n[6] Connecting browser (keep alive)...');
  r = await connectWs('browser', 'dummy');
  expect('browser receives welcome', r.welcome !== null);
  expect('browser welcome.role = browser', r.welcome && r.welcome.role === 'browser');
  activeWs.push(r);

  // 7. 检查 status（全部连着）
  console.log('\n[7] Checking status (all connected)...');
  status = await checkStatus();
  console.log(`  status: masters=${status.masters.length}, slaves=${status.slaves.length}, browsers=${status.browsers}`);
  expect('status.browsers = 1', status.browsers === 1);

  // 8. 测试 unknown role（应该被拒绝，不保持连接）
  console.log('\n[8] Testing unknown role...');
  r = await connectWs('hacker', 'test_hacker');
  expect('unknown role gets no welcome', r.welcome === null);
  // hacker 连接会被服务器关闭，不需要 activeWs.push

  // 9. 关闭所有保持的连接
  console.log('\n[9] Closing all connections...');
  for (const c of activeWs) { try { c.ws.close(); } catch (e) {} }
  await sleep(500);

  // 10. 最终 status 检查（应该都清零）
  console.log('\n[10] Final status check (all disconnected)...');
  status = await checkStatus();
  console.log(`  status: masters=${status.masters.length}, slaves=${status.slaves.length}, browsers=${status.browsers}`);
  expect('final: masters = 0', status.masters.length === 0);
  expect('final: slaves = 0', status.slaves.length === 0);
  expect('final: browsers = 0', status.browsers === 0);

  // 停止服务器
  console.log('\n[11] Stopping server...');
  await stopServer();

  console.log('\n═══ Test Summary ═══');
  console.log(`  Passed: ${passed}`);
  console.log(`  Failed: ${failed}`);
  if (failed > 0) { console.log('  ❌ SOME TESTS FAILED'); process.exit(1); }
  else { console.log('  ✅ ALL TESTS PASSED'); process.exit(0); }
}

run().catch((e) => { console.error('Unhandled:', e); stopServer().then(() => process.exit(1)); });
