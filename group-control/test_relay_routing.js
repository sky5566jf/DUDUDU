const WebSocket = require('ws');
const RELAY = 'ws://192.69.0.24:8183';

const results = { targeted: null, all: null, slavesOnly: null, defaultAll: null };
const received = { PHONE_M: [], PHONE_A: [], PHONE_B: [] };

function phone(id, role) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${RELAY}?role=${role}&deviceId=${id}`);
    ws.on('open', () => resolve(ws));
    ws.on('message', (raw) => {
      let m; try { m = JSON.parse(Buffer.isBuffer(raw) ? raw.toString() : raw); } catch (e) { return; }
      if (m.type === 'touch') received[id].push(m);
    });
    ws.on('error', (e) => { console.log('phone', id, 'err', e.message); resolve(ws); });
  });
}

(async () => {
  const pm = await phone('PHONE_M', 'master');
  const pa = await phone('PHONE_A', 'slave');
  const pb = await phone('PHONE_B', 'slave');
  await new Promise(r => setTimeout(r, 500));

  const browser = new WebSocket(`${RELAY}?role=browser`);
  await new Promise((res) => browser.on('open', res));
  await new Promise(r => setTimeout(r, 300));

  function send(obj) {
    browser.send(JSON.stringify(obj));
  }
  async function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

  // 用增量判定（received 是累计数组，发送前记录基线，发送后算 delta）
  function baseline() {
    return { PHONE_M: received.PHONE_M.length, PHONE_A: received.PHONE_A.length, PHONE_B: received.PHONE_B.length };
  }
  function delta(b) {
    return {
      PHONE_M: received.PHONE_M.length - b.PHONE_M,
      PHONE_A: received.PHONE_A.length - b.PHONE_A,
      PHONE_B: received.PHONE_B.length - b.PHONE_B,
    };
  }

  // 1) 定向单台
  let b = baseline();
  send({ type: 'touch', action: 'tap', x: 0.5, y: 0.5, targetDeviceId: 'PHONE_A' });
  await wait(400);
  results.targeted = delta(b);

  // 2) scope=all
  b = baseline();
  send({ type: 'touch', action: 'tap', x: 0.1, y: 0.1, scope: 'all' });
  await wait(400);
  results.all = delta(b);

  // 3) scope=slaves (仅从控)
  b = baseline();
  send({ type: 'touch', action: 'tap', x: 0.2, y: 0.2, scope: 'slaves' });
  await wait(400);
  results.slavesOnly = delta(b);

  // 4) 默认无 scope/target (应全广播)
  b = baseline();
  send({ type: 'touch', action: 'tap', x: 0.3, y: 0.3 });
  await wait(400);
  results.defaultAll = delta(b);

  console.log('=== ROUTING TEST RESULTS (增量) ===');
  console.log('1) targetDeviceId=PHONE_A  ->', JSON.stringify(results.targeted), '(期望: 仅 A=1, 其余 0)');
  console.log('2) scope=all              ->', JSON.stringify(results.all), '(期望: 三台各 +1)');
  console.log('3) scope=slaves           ->', JSON.stringify(results.slavesOnly), '(期望: M=0, A/B 各 +1)');
  console.log('4) default                ->', JSON.stringify(results.defaultAll), '(期望: 三台各 +1)');

  const ok1 = results.targeted.PHONE_A === 1 && results.targeted.PHONE_M === 0 && results.targeted.PHONE_B === 0;
  const ok2 = results.all.PHONE_M === 1 && results.all.PHONE_A === 1 && results.all.PHONE_B === 1;
  const ok3 = results.slavesOnly.PHONE_M === 0 && results.slavesOnly.PHONE_A === 1 && results.slavesOnly.PHONE_B === 1;
  const ok4 = results.defaultAll.PHONE_M === 1 && results.defaultAll.PHONE_A === 1 && results.defaultAll.PHONE_B === 1;
  console.log('PASS:', ok1 && ok2 && ok3 && ok4 ? 'ALL GREEN ✅' : 'FAIL ❌');

  [pm, pa, pb, browser].forEach(w => { try { w.close(); } catch (e) {} });
  process.exit(ok1 && ok2 && ok3 && ok4 ? 0 : 1);
})();
