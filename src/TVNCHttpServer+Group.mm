//
//  TVNCHttpServer+Group.mm
//  Auto-split from TVNCHttpServer.mm (P3 maintainability refactor, 2026-07-20)
//
#import "TVNCHttpServer+Handlers.h"

@interface TVNCHttpServer (Group)
@end

@implementation TVNCHttpServer (Group)

- (TVNCHttpResponse *)handleGroupStart:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *masterStr = query[@"master"];
    self.groupMasterEnabled = (masterStr && [masterStr isEqualToString:@"1"]);
    
    NSString *portStr = query[@"port"];
    if (portStr) {
        self.groupWSPort = (NSUInteger)[portStr integerValue];
    }
    
    BOOL success = [self startGroupWebSocketServer];
    
    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @(success),
        @"master": @(self.groupMasterEnabled),
        @"port": @(self.groupWSPort),
        @"slaves": @(self.groupSlaveCount)
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupStop {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    [self stopGroupWebSocketServer];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @YES};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupStatus {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"running": @(self.wsRunning),
        @"master": @(self.groupMasterEnabled),
        @"port": @(self.groupWSPort),
        @"slaves": @(self.groupSlaveCount),
        @"slaveConnected": @(self.masterConnected),
        @"masterIP": self.masterIP ?: @"",
        // 电脑中继模式
        @"relayMode": @(self.relayModeEnabled),
        @"relayConnected": @(self.relayConnected),
        @"relayIp": self.relayIP ?: @"",
        @"relayPort": @(self.relayPort),
        @"role": self.relayRole ?: @""
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupTouch:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    if (!body) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Missing body"} options:0 error:nil];
        return response;
    }
    
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (!event) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Invalid JSON"} options:0 error:nil];
        return response;
    }
    
    NSString *type = event[@"type"];
    if ([type isEqualToString:@"touch"]) {
        [self executeGroupTouchEvent:event];
    } else if ([type isEqualToString:@"key"]) {
        [self executeGroupKeyEvent:event];
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:@{@"success": @YES} options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupConnect:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *ip = query[@"ip"];
    NSString *portStr = query[@"port"];
    NSUInteger port = portStr ? (NSUInteger)[portStr integerValue] : 8183;
    
    if (!ip) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Missing ip parameter"} options:0 error:nil];
        return response;
    }
    
    // 设备不能同时作为主控和从控
    if (self.groupMasterEnabled) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Already running as master"} options:0 error:nil];
        return response;
    }
    
    BOOL success = [self connectToMaster:ip port:port];
    
    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @(success),
        @"masterIP": ip,
        @"port": @(port)
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupDisconnect {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    [self disconnectFromMaster];

    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:@{@"success": @YES} options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleRelayStart:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSString *relayIP = query[@"relayIp"];
    NSString *portStr = query[@"relayPort"];
    NSString *role = query[@"role"] ?: @"slave";

    // 如果没有提供 relayIp 参数，尝试从配置文件读取
    if (!relayIP || relayIP.length == 0) {
        TVLog(@"Relay: relayIp not provided, reading from config file...");
        relayIP = [self readServerIPFromConfigFile];
        if (!relayIP || relayIP.length == 0) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Missing relayIp parameter and failed to read from config file (/var/mobile/Media/fuwuduan.txt)"} options:0 error:nil];
            return response;
        }
        TVLog(@"Relay: Using serverIP from config file: %@", relayIP);
    }

    NSUInteger port = portStr ? (NSUInteger)[portStr integerValue] : 8183;

    // 角色验证
    if (![role isEqualToString:@"master"] && ![role isEqualToString:@"slave"]) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Role must be 'master' or 'slave'"} options:0 error:nil];
        return response;
    }

    BOOL success = [self connectToRelay:relayIP port:port role:role];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @(success),
        @"relayMode": @(self.relayModeEnabled),
        @"relayConnected": @(self.relayConnected),
        @"relayIp": self.relayIP ?: @"",
        @"relayPort": @(self.relayPort),
        @"role": self.relayRole ?: @""
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleRelayStop {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    [self disconnectFromRelay];

    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:@{@"success": @YES} options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupSlaves {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSArray<NSString *> *ips = [self groupSlaveIPs];
    NSMutableArray *slaves = [NSMutableArray array];
    for (NSString *ip in ips) {
        [slaves addObject:@{@"ip": ip}];
    }

    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"slaves": slaves,
        @"count": @(ips.count)
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleGroupProxyScreenshot:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSString *slaveIP = query[@"ip"];
    if (!slaveIP || slaveIP.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Missing ip parameter"} options:0 error:nil];
        return response;
    }

    // 从控设备 HTTP 端口（默认 8182）
    NSString *portStr = query[@"port"] ?: @"8182";
    NSString *format = query[@"format"] ?: @"jpeg";
    NSString *quality = query[@"quality"] ?: @"0.5";
    NSString *scale = query[@"scale"] ?: @"0.3";

    // 构造请求 URL
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%@/api/screenshot?format=%@&quality=%@&scale=%@",
                        slaveIP, portStr, format, quality, scale];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Invalid URL"} options:0 error:nil];
        return response;
    }

    // 同步 HTTP 请求（用 NSURLSession + semaphore）
    __block NSData *imageData = nil;
    @try {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = 3.0;
        req.HTTPMethod = @"GET";

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            imageData = data;
            dispatch_semaphore_signal(sema);
        }] resume];
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    } @catch (NSException *e) {
        TVLog(@"Group proxy screenshot error: %@", e);
    }

    if (imageData && imageData.length > 0) {
        response.statusCode = 200;
        response.contentType = [format isEqualToString:@"png"] ? @"image/png" : @"image/jpeg";
        response.body = imageData;
    } else {
        response.statusCode = 502;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Failed to fetch screenshot from slave"} options:0 error:nil];
    }
    return response;
}

- (TVNCHttpResponse *)handleGroupTestPage {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *html = @"<!DOCTYPE html>"
    "<html lang='zh-CN'><head>"
    "<meta charset='UTF-8'>"
    "<meta name='viewport' content='width=device-width, initial-scale=1.0'>"
    "<title>TrollVNC 群控测试</title>"
    "<style>"
    "* { margin: 0; padding: 0; box-sizing: border-box; }"
    "body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #1a1a2e; color: #eee; padding: 20px; }"
    ".header { background: linear-gradient(135deg, #667eea, #764ba2); padding: 15px 20px; border-radius: 12px; margin-bottom: 20px; }"
    ".header h1 { font-size: 20px; font-weight: 600; }"
    ".header .status { font-size: 13px; opacity: 0.9; margin-top: 5px; }"
    ".panel { background: #16213e; border-radius: 12px; padding: 20px; margin-bottom: 15px; }"
    ".panel h2 { font-size: 16px; margin-bottom: 12px; color: #667eea; }"
    ".btn-row { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 10px; }"
    ".btn { padding: 8px 16px; border: none; border-radius: 8px; cursor: pointer; font-size: 14px; transition: all 0.2s; }"
    ".btn-primary { background: #667eea; color: white; }"
    ".btn-primary:hover { background: #5568d3; }"
    ".btn-success { background: #52c41a; color: white; }"
    ".btn-danger { background: #ff4d4f; color: white; }"
    ".btn-danger:hover { background: #e04345; }"
    ".btn-warn { background: #faad14; color: #333; }"
    ".input-group { display: flex; gap: 8px; align-items: center; margin-bottom: 10px; }"
    ".input-group input, .input-group select { padding: 8px 12px; border-radius: 8px; border: 1px solid #444; background: #0f3460; color: #eee; font-size: 14px; }"
    ".input-group input { width: 160px; }"
    ".touch-area { width: 100%; height: 400px; background: #0f3460; border-radius: 12px; border: 2px dashed #444; position: relative; overflow: hidden; touch-action: none; }"
    ".touch-area .dot { width: 20px; height: 20px; background: #667eea; border-radius: 50%; position: absolute; transform: translate(-50%, -50%); pointer-events: none; }"
    ".log-area { background: #0a0a1a; border-radius: 12px; padding: 15px; max-height: 300px; overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; }"
    ".log-area .log-entry { padding: 2px 0; border-bottom: 1px solid #1a1a2e; }"
    ".log-entry .time { color: #888; }"
    ".log-entry .data { color: #667eea; }"
    ".log-entry.error { color: #ff4d4f; }"
    ".stats { display: flex; gap: 15px; flex-wrap: wrap; margin-bottom: 15px; }"
    ".stat-card { background: #0f3460; padding: 12px 16px; border-radius: 8px; flex: 1; min-width: 100px; text-align: center; }"
    ".stat-card .label { font-size: 12px; color: #888; }"
    ".stat-card .value { font-size: 20px; font-weight: 600; color: #667eea; }"
    "</style></head><body>"
    
    "<div class='header'>"
    "<h1>TrollVNC 群控测试</h1>"
    "<div class='status' id='connStatus'>未连接</div>"
    "</div>"
    
    "<div class='panel'>"
    "<h2>连接设置</h2>"
    "<div class='input-group'>"
    "<label>设备 IP:</label>"
    "<input type='text' id='deviceIp' placeholder='192.168.x.x' value=''>"
    "<label>WS 端口:</label>"
    "<input type='text' id='wsPort' value='8183'>"
    "<button class='btn btn-primary' onclick='connectWS()'>WS连接</button>"
    "<button class='btn btn-danger' onclick='disconnectWS()'>WS断开</button>"
    "</div>"
    "<div class='input-group'>"
    "<label>模式:</label>"
    "<select id='mode' onchange='onModeChange()'>"
    "<option value='master'>主控模式</option>"
    "<option value='slave'>从控模式</option>"
    "</select>"
    "<button class='btn btn-success' onclick='startGroup()'>启动群控</button>"
    "<button class='btn btn-danger' onclick='stopGroup()'>停止群控</button>"
    "</div>"
    "<div class='input-group' id='slaveConnectRow' style='display:none'>"
    "<label>主控 IP:</label>"
    "<input type='text' id='masterIp' placeholder='主控设备 IP'>"
    "<button class='btn btn-primary' onclick='connectToMaster()'>连接主控</button>"
    "<button class='btn btn-danger' onclick='disconnectFromMaster()'>断开主控</button>"
    "</div>"
    "</div>"
    
    "<div class='stats'>"
    "<div class='stat-card'><div class='label'>从控数量</div><div class='value' id='slaveCount'>0</div></div>"
    "<div class='stat-card'><div class='label'>发送事件</div><div class='value' id='sendCount'>0</div></div>"
    "<div class='stat-card'><div class='label'>接收事件</div><div class='value' id='recvCount'>0</div></div>"
    "</div>"
    
    "<div class='panel'>"
    "<h2>触摸操作区（主控模式下，在此区域触摸/滑动发送事件）</h2>"
    "<div class='touch-area' id='touchArea'></div>"
    "<div class='btn-row' style='margin-top:10px'>"
    "<button class='btn btn-primary' onclick='sendClick(0.5,0.5)'>点击中心</button>"
    "<button class='btn btn-primary' onclick='sendClick(0.25,0.25)'>左上</button>"
    "<button class='btn btn-primary' onclick='sendClick(0.75,0.75)'>右下</button>"
    "<button class='btn btn-warn' onclick='sendHome()'>Home键</button>"
    "<button class='btn btn-warn' onclick='sendPower()'>电源键</button>"
    "<button class='btn btn-danger' onclick='clearLog()'>清空日志</button>"
    "</div>"
    "</div>"
    
    "<div class='panel'>"
    "<h2>事件日志</h2>"
    "<div class='log-area' id='logArea'></div>"
    "</div>"
    
    "<script>"
    "var ws = null;"
    "var sendCounter = 0, recvCounter = 0;"
    "var touchActive = false, lastTouchX = 0, lastTouchY = 0;"
    ""
    "function log(msg, isError) {"
    "  var area = document.getElementById('logArea');"
    "  var now = new Date().toLocaleTimeString();"
    "  var div = document.createElement('div');"
    "  div.className = 'log-entry' + (isError ? ' error' : '');"
    "  div.innerHTML = '<span class=\\'time\\'>' + now + '</span> ' + msg;"
    "  area.appendChild(div);"
    "  area.scrollTop = area.scrollHeight;"
    "}"
    ""
    "function updateStatus(text, color) {"
    "  var el = document.getElementById('connStatus');"
    "  el.textContent = text;"
    "  el.style.color = color || '#eee';"
    "}"
    ""
    "function connectWS() {"
    "  if (ws && ws.readyState <= 1) { log('已连接，先断开', true); return; }"
    "  var ip = document.getElementById('deviceIp').value;"
    "  var port = document.getElementById('wsPort').value;"
    "  if (!ip) { log('请输入设备 IP', true); return; }"
    "  var url = 'ws://' + ip + ':' + port;"
    "  log('连接 ' + url + ' ...');"
    "  ws = new WebSocket(url);"
    "  ws.onopen = function() {"
    "    updateStatus('已连接 (WebSocket)', '#52c41a');"
    "    log('WebSocket 连接成功');"
    "  };"
    "  ws.onmessage = function(e) {"
    "    recvCounter++;"
    "    document.getElementById('recvCount').textContent = recvCounter;"
    "    log('收到: <span class=\\'data\\'>' + e.data + '</span>');"
    "    try {"
    "      var ev = JSON.parse(e.data);"
    "      if (ev.type === 'touch') {"
    "        showDot(ev.x, ev.y);"
    "      }"
    "    } catch(ex) {}"
    "  };"
    "  ws.onclose = function() {"
    "    updateStatus('已断开', '#ff4d4f');"
    "    log('WebSocket 连接关闭');"
    "  };"
    "  ws.onerror = function() {"
    "    updateStatus('连接失败', '#ff4d4f');"
    "    log('WebSocket 连接失败', true);"
    "  };"
    "}"
    ""
    "function disconnectWS() {"
    "  if (ws) { ws.close(); ws = null; }"
    "  updateStatus('已断开', '#ff4d4f');"
    "}"
    ""
    "function onModeChange() {"
    "  var mode = document.getElementById('mode').value;"
    "  document.getElementById('slaveConnectRow').style.display = mode === 'slave' ? 'flex' : 'none';"
    "}"
    ""
    "function startGroup() {"
    "  var ip = document.getElementById('deviceIp').value;"
    "  var port = document.getElementById('wsPort').value;"
    "  var mode = document.getElementById('mode').value;"
    "  var master = mode === 'master' ? '1' : '0';"
    "  var url = 'http://' + ip + ':8182/api/group/start?master=' + master + '&port=' + port;"
    "  fetch(url, {method:'POST'}).then(r=>r.json()).then(d => {"
    "    log('群控启动: ' + JSON.stringify(d));"
    "    if (d.success) updateStatus('群控运行中 (' + (d.master ? '主控' : '从控') + ')', '#52c41a');"
    "  }).catch(e => log('启动失败: ' + e, true));"
    "}"
    ""
    "function stopGroup() {"
    "  var ip = document.getElementById('deviceIp').value;"
    "  fetch('http://' + ip + ':8182/api/group/stop', {method:'POST'}).then(r=>r.json()).then(d => {"
    "    log('群控停止: ' + JSON.stringify(d));"
    "    updateStatus('群控已停止', '#faad14');"
    "  }).catch(e => log('停止失败: ' + e, true));"
    "}"
    ""
    "function connectToMaster() {"
    "  var ip = document.getElementById('deviceIp').value;"
    "  var masterIp = document.getElementById('masterIp').value;"
    "  var port = document.getElementById('wsPort').value;"
    "  if (!masterIp) { log('请输入主控 IP', true); return; }"
    "  fetch('http://' + ip + ':8182/api/group/connect?ip=' + masterIp + '&port=' + port, {method:'POST'}).then(r=>r.json()).then(d => {"
    "    log('连接主控: ' + JSON.stringify(d));"
    "    if (d.success) updateStatus('从控已连接到主控 ' + masterIp, '#52c41a');"
    "  }).catch(e => log('连接失败: ' + e, true));"
    "}"
    ""
    "function disconnectFromMaster() {"
    "  var ip = document.getElementById('deviceIp').value;"
    "  fetch('http://' + ip + ':8182/api/group/disconnect', {method:'POST'}).then(r=>r.json()).then(d => {"
    "    log('断开主控: ' + JSON.stringify(d));"
    "    updateStatus('已断开主控', '#faad14');"
    "  }).catch(e => log('断开失败: ' + e, true));"
    "}"
    ""
    "function sendEvent(obj) {"
    "  var json = JSON.stringify(obj);"
    "  if (ws && ws.readyState === 1) {"
    "    ws.send(json);"
    "    sendCounter++;"
    "    document.getElementById('sendCount').textContent = sendCounter;"
    "    log('发送: <span class=\\'data\\'>' + json + '</span>');"
    "  } else {"
    "    log('WebSocket 未连接', true);"
    "  }"
    "}"
    ""
    "function sendClick(nx, ny) {"
    "  sendEvent({type:'touch', x:nx, y:ny, action:'down'});"
    "  setTimeout(function() { sendEvent({type:'touch', x:nx, y:ny, action:'up'}); }, 50);"
    "}"
    ""
    "function sendHome() {"
    "  sendEvent({type:'key', action:'home_down'});"
    "  setTimeout(function() { sendEvent({type:'key', action:'home_up'}); }, 50);"
    "}"
    ""
    "function sendPower() {"
    "  sendEvent({type:'key', action:'power_down'});"
    "  setTimeout(function() { sendEvent({type:'key', action:'power_up'}); }, 50);"
    "}"
    ""
    "function showDot(nx, ny) {"
    "  var area = document.getElementById('touchArea');"
    "  var dot = document.createElement('div');"
    "  dot.className = 'dot';"
    "  dot.style.left = (nx * 100) + '%';"
    "  dot.style.top = (ny * 100) + '%';"
    "  dot.style.opacity = '1';"
    "  area.appendChild(dot);"
    "  setTimeout(function() { dot.style.opacity = '0'; dot.style.transition = 'opacity 0.5s'; }, 300);"
    "  setTimeout(function() { area.removeChild(dot); }, 800);"
    "}"
    ""
    "// 触摸区域事件"
    "var touchArea = document.getElementById('touchArea');"
    ""
    "function getNormPos(e) {"
    "  var rect = touchArea.getBoundingClientRect();"
    "  var clientX, clientY;"
    "  if (e.touches && e.touches.length > 0) {"
    "    clientX = e.touches[0].clientX; clientY = e.touches[0].clientY;"
    "  } else {"
    "    clientX = e.clientX; clientY = e.clientY;"
    "  }"
    "  return {"
    "    x: (clientX - rect.left) / rect.width,"
    "    y: (clientY - rect.top) / rect.height"
    "  };"
    "}"
    ""
    "touchArea.addEventListener('mousedown', function(e) {"
    "  touchActive = true;"
    "  var p = getNormPos(e);"
    "  lastTouchX = p.x; lastTouchY = p.y;"
    "  sendEvent({type:'touch', x:p.x, y:p.y, action:'down'});"
    "  showDot(p.x, p.y);"
    "});"
    ""
    "touchArea.addEventListener('mousemove', function(e) {"
    "  if (!touchActive) return;"
    "  var p = getNormPos(e);"
    "  if (Math.abs(p.x - lastTouchX) < 0.01 && Math.abs(p.y - lastTouchY) < 0.01) return;"
    "  lastTouchX = p.x; lastTouchY = p.y;"
    "  sendEvent({type:'touch', x:p.x, y:p.y, action:'move'});"
    "  showDot(p.x, p.y);"
    "});"
    ""
    "touchArea.addEventListener('mouseup', function(e) {"
    "  if (!touchActive) return;"
    "  touchActive = false;"
    "  var p = getNormPos(e);"
    "  sendEvent({type:'touch', x:p.x, y:p.y, action:'up'});"
    "});"
    ""
    "touchArea.addEventListener('touchstart', function(e) {"
    "  e.preventDefault();"
    "  var p = getNormPos(e);"
    "  lastTouchX = p.x; lastTouchY = p.y;"
    "  sendEvent({type:'touch', x:p.x, y:p.y, action:'down'});"
    "  showDot(p.x, p.y);"
    "});"
    ""
    "touchArea.addEventListener('touchmove', function(e) {"
    "  e.preventDefault();"
    "  var p = getNormPos(e);"
    "  if (Math.abs(p.x - lastTouchX) < 0.01 && Math.abs(p.y - lastTouchY) < 0.01) return;"
    "  lastTouchX = p.x; lastTouchY = p.y;"
    "  sendEvent({type:'touch', x:p.x, y:p.y, action:'move'});"
    "  showDot(p.x, p.y);"
    "});"
    ""
    "touchArea.addEventListener('touchend', function(e) {"
    "  e.preventDefault();"
    "  sendEvent({type:'touch', x:lastTouchX, y:lastTouchY, action:'up'});"
    "});"
    ""
    "function clearLog() {"
    "  document.getElementById('logArea').innerHTML = '';"
    "}"
    ""
    "// 定期刷新状态"
    "setInterval(function() {"
    "  var ip = document.getElementById('deviceIp').value;"
    "  if (!ip) return;"
    "  fetch('http://' + ip + ':8182/api/group/status').then(r=>r.json()).then(d => {"
    "    document.getElementById('slaveCount').textContent = d.slaves || 0;"
    "  }).catch(function(){});"
    "}, 3000);"
    "</script>"
    "</body></html>";
    
    response.statusCode = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];
    return response;
}

- (TVNCHttpResponse *)handleGroupControlPage {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSString *html = @"<!DOCTYPE html>"
    "<html lang='zh-CN'><head>"
    "<meta charset='UTF-8'>"
    "<meta name='viewport' content='width=device-width, initial-scale=1.0, user-scalable=no'>"
    "<title>TrollVNC 投屏群控</title>"
    "<style>"
    "* { margin: 0; padding: 0; box-sizing: border-box; }"
    "body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0a0a1a; color: #eee; overflow: hidden; height: 100vh; }"
    ".toolbar { background: #16213e; padding: 8px 16px; display: flex; align-items: center; gap: 10px; border-bottom: 1px solid #333; flex-shrink: 0; }"
    ".toolbar h1 { font-size: 16px; font-weight: 600; color: #667eea; margin-right: auto; }"
    ".toolbar input { padding: 5px 10px; border-radius: 6px; border: 1px solid #444; background: #0f3460; color: #eee; font-size: 13px; width: 140px; }"
    ".toolbar select { padding: 5px 10px; border-radius: 6px; border: 1px solid #444; background: #0f3460; color: #eee; font-size: 13px; }"
    ".btn { padding: 5px 14px; border: none; border-radius: 6px; cursor: pointer; font-size: 13px; transition: all 0.2s; }"
    ".btn-primary { background: #667eea; color: white; }"
    ".btn-primary:hover { background: #5568d3; }"
    ".btn-success { background: #52c41a; color: white; }"
    ".btn-danger { background: #ff4d4f; color: white; }"
    ".btn-sm { padding: 3px 10px; font-size: 12px; }"
    ".status-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 4px; }"
    ".status-dot.on { background: #52c41a; }"
    ".status-dot.off { background: #666; }"
    ".main { display: flex; flex: 1; overflow: hidden; height: calc(100vh - 46px); }"
    ".master-panel { flex: 1; display: flex; flex-direction: column; min-width: 0; position: relative; }"
    ".master-label { background: #1a1a2e; padding: 4px 12px; font-size: 12px; color: #667eea; display: flex; align-items: center; gap: 6px; }"
    ".master-screen { flex: 1; display: flex; align-items: center; justify-content: center; background: #0a0a1a; position: relative; overflow: hidden; }"
    ".master-screen img { max-width: 100%; max-height: 100%; object-fit: contain; cursor: crosshair; touch-action: none; user-select: none; -webkit-user-select: none; }"
    ".slave-panel { width: 220px; background: #0f0f1a; border-left: 1px solid #333; overflow-y: auto; flex-shrink: 0; }"
    ".slave-item { padding: 8px; border-bottom: 1px solid #1a1a2e; }"
    ".slave-item .label { font-size: 11px; color: #888; margin-bottom: 4px; display: flex; align-items: center; gap: 4px; }"
    ".slave-item img { width: 100%; border-radius: 4px; background: #111; display: block; }"
    ".slave-item img.error { min-height: 80px; opacity: 0.3; }"
    ".no-slave { padding: 20px 10px; text-align: center; color: #555; font-size: 12px; }"
    ".log-panel { position: absolute; bottom: 0; left: 0; right: 0; background: rgba(0,0,0,0.85); max-height: 120px; overflow-y: auto; font-size: 11px; font-family: monospace; padding: 6px 10px; display: none; border-top: 1px solid #333; }"
    ".log-panel.show { display: block; }"
    ".log-panel .log-line { color: #667eea; padding: 1px 0; }"
    ".log-panel .log-line.err { color: #ff4d4f; }"
    ".fps-badge { position: absolute; top: 4px; right: 4px; background: rgba(0,0,0,0.7); color: #52c41a; font-size: 11px; padding: 2px 6px; border-radius: 4px; font-family: monospace; }"
    "</style></head><body>"

    "<div class='toolbar'>"
    "<h1>TrollVNC 投屏群控</h1>"
    "<span id='statusDot' class='status-dot off'></span>"
    "<span id='statusText' style='font-size:12px;color:#888'>未连接</span>"
    "<label style='font-size:12px;color:#888'>主控IP:</label>"
    "<input type='text' id='masterIp' placeholder='192.168.x.x'>"
    "<button class='btn btn-success btn-sm' onclick='startControl()'>启动群控</button>"
    "<button class='btn btn-danger btn-sm' onclick='stopControl()'>停止</button>"
    "<button class='btn btn-primary btn-sm' onclick='toggleLog()'>日志</button>"
    "</div>"

    "<div class='main'>"
    "<div class='master-panel'>"
    "<div class='master-label'>"
    "<span class='status-dot on'></span> 主控画面（在此操作，从控同步跟随）"
    "<span id='slaveInfo' style='margin-left:auto;color:#888'>从控: 0</span>"
    "</div>"
    "<div class='master-screen' id='masterScreen'>"
    "<img id='masterImg' src='' alt='主控画面' style='display:none'>"
    "<div id='masterPlaceholder' style='color:#444;font-size:14px'>请输入主控IP并点击启动群控</div>"
    "<div class='fps-badge' id='fpsBadge' style='display:none'>0 fps</div>"
    "</div>"
    "<div class='log-panel' id='logPanel'></div>"
    "</div>"
    "<div class='slave-panel' id='slavePanel'>"
    "<div class='no-slave' id='noSlave'>等待从控设备连接...</div>"
    "</div>"
    "</div>"

    "<script>"
    "var ws = null;"
    "var masterIp = '';"
    "var masterInterval = null;"
    "var slaveInterval = null;"
    "var slaveList = [];"
    "var frameCount = 0;"
    "var lastFpsTime = Date.now();"
    "var logVisible = false;"

    "function log(msg, isErr) {"
    "  var p = document.getElementById('logPanel');"
    "  var d = document.createElement('div');"
    "  d.className = 'log-line' + (isErr ? ' err' : '');"
    "  d.textContent = new Date().toLocaleTimeString() + ' ' + msg;"
    "  p.appendChild(d);"
    "  if (p.children.length > 100) p.removeChild(p.firstChild);"
    "  p.scrollTop = p.scrollHeight;"
    "}"

    "function toggleLog() {"
    "  logVisible = !logVisible;"
    "  document.getElementById('logPanel').className = 'log-panel' + (logVisible ? ' show' : '');"
    "}"

    "function setStatus(on, text) {"
    "  document.getElementById('statusDot').className = 'status-dot ' + (on ? 'on' : 'off');"
    "  document.getElementById('statusText').textContent = text;"
    "}"

    "function startControl() {"
    "  masterIp = document.getElementById('masterIp').value.trim();"
    "  if (!masterIp) { alert('请输入主控设备IP'); return; }"

    "  // 1. 启动群控 WS Server"
    "  fetch('http://' + masterIp + ':8182/api/group/start?master=1&port=8183', {method:'POST'})"
    "    .then(r=>r.json()).then(d => {"
    "      log('群控已启动: master=' + d.master + ', port=' + d.port);"
    "      setStatus(true, '群控已启动');"
    "    }).catch(e => log('启动群控失败: ' + e.message, true));"

    "  // 2. 连接 WS"
    "  if (ws) ws.close();"
    "  ws = new WebSocket('ws://' + masterIp + ':8183');"
    "  ws.onopen = function() { log('WS 已连接'); };"
    "  ws.onmessage = function(e) { log('WS 收到: ' + e.data); };"
    "  ws.onerror = function() { log('WS 错误', true); };"
    "  ws.onclose = function() { log('WS 断开'); setStatus(false, 'WS 断开'); };"

    "  // 3. 开始截图轮询 - 主控"
    "  if (masterInterval) clearInterval(masterInterval);"
    "  document.getElementById('masterImg').style.display = 'block';"
    "  document.getElementById('masterPlaceholder').style.display = 'none';"
    "  document.getElementById('fpsBadge').style.display = 'block';"
    "  masterInterval = setInterval(refreshMaster, 400);"

    "  // 4. 开始轮询从控列表"
    "  if (slaveInterval) clearInterval(slaveInterval);"
    "  slaveInterval = setInterval(refreshSlaves, 3000);"
    "  refreshSlaves();"
    "}"

    "function stopControl() {"
    "  if (ws) { ws.close(); ws = null; }"
    "  if (masterInterval) { clearInterval(masterInterval); masterInterval = null; }"
    "  if (slaveInterval) { clearInterval(slaveInterval); slaveInterval = null; }"
    "  document.getElementById('masterImg').style.display = 'none';"
    "  document.getElementById('masterPlaceholder').style.display = 'block';"
    "  document.getElementById('fpsBadge').style.display = 'none';"
    "  setStatus(false, '已停止');"
    "  fetch('http://' + masterIp + ':8182/api/group/stop', {method:'POST'}).catch(function(){});"
    "}"

    "function refreshMaster() {"
    "  var img = document.getElementById('masterImg');"
    "  var url = 'http://' + masterIp + ':8182/api/screenshot?format=jpeg&quality=0.7&scale=0.5&_t=' + Date.now();"
    "  img.src = url;"
    "  frameCount++;"
    "  var now = Date.now();"
    "  if (now - lastFpsTime >= 1000) {"
    "    document.getElementById('fpsBadge').textContent = frameCount + ' fps';"
    "    frameCount = 0;"
    "    lastFpsTime = now;"
    "  }"
    "}"

    "var knownSlaves = {};"

    "function refreshSlaves() {"
    "  fetch('http://' + masterIp + ':8182/api/group/slaves').then(r=>r.json()).then(d => {"
    "    document.getElementById('slaveInfo').textContent = '从控: ' + d.count;"
    "    var panel = document.getElementById('slavePanel');"
    "    var noSlave = document.getElementById('noSlave');"
    "    if (d.count === 0) {"
    "      noSlave.style.display = 'block';"
    "      return;"
    "    }"
    "    noSlave.style.display = 'none';"
    "    // 添加新的从控"
    "    for (var i = 0; i < d.slaves.length; i++) {"
    "      var ip = d.slaves[i].ip;"
    "      if (!knownSlaves[ip]) {"
    "        knownSlaves[ip] = true;"
    "        var div = document.createElement('div');"
    "        div.className = 'slave-item';"
    "        div.id = 'slave-' + ip.replace(/\\./g, '-');"
    "        div.innerHTML = '<div class=\\'label\\'><span class=\\'status-dot on\\'></span>' + ip + '</div><img id=\\'simg-' + ip.replace(/\\./g, '-') + '\\' src=\\'\\' class=\\'error\\'>';"
    "        panel.appendChild(div);"
    "      }"
    "    }"
    "    // 刷新从控截图"
    "    for (var i = 0; i < d.slaves.length; i++) {"
    "      var ip = d.slaves[i].ip;"
    "      var imgId = 'simg-' + ip.replace(/\\./g, '-');"
    "      var sImg = document.getElementById(imgId);"
    "      if (sImg) {"
    "        sImg.src = 'http://' + masterIp + ':8182/api/group/proxy-screenshot?ip=' + ip + '&format=jpeg&quality=0.5&scale=0.3&_t=' + Date.now();"
    "        sImg.className = '';"
    "        sImg.onerror = function() { this.className = 'error'; };"
    "      }"
    "    }"
    "  }).catch(function(){});"
    "}"

    // 触摸事件处理 - 发送到主控 WS
    "var masterImg = document.getElementById('masterImg');"
    "var touching = false;"

    "function getNormPos(e) {"
    "  var rect = masterImg.getBoundingClientRect();"
    "  var x, y;"
    "  if (e.touches) {"
    "    x = e.touches[0].clientX - rect.left;"
    "    y = e.touches[0].clientY - rect.top;"
    "  } else {"
    "    x = e.clientX - rect.left;"
    "    y = e.clientY - rect.top;"
    "  }"
    "  return { x: x / rect.width, y: y / rect.height };"
    "}"

    "function sendTouch(action, nx, ny) {"
    "  if (!ws || ws.readyState !== 1) return;"
    "  var evt = JSON.stringify({type:'touch', x: nx, y: ny, action: action});"
    "  ws.send(evt);"
    "  log('Touch: ' + action + ' (' + nx.toFixed(3) + ', ' + ny.toFixed(3) + ')');"
    "}"

    "masterImg.addEventListener('mousedown', function(e) {"
    "  e.preventDefault(); touching = true;"
    "  var p = getNormPos(e);"
    "  sendTouch('down', p.x, p.y);"
    "});"
    "document.addEventListener('mousemove', function(e) {"
    "  if (!touching) return;"
    "  var p = getNormPos(e);"
    "  sendTouch('move', p.x, p.y);"
    "});"
    "document.addEventListener('mouseup', function(e) {"
    "  if (!touching) return; touching = false;"
    "  var p = getNormPos(e);"
    "  sendTouch('up', p.x, p.y);"
    "});"
    "masterImg.addEventListener('touchstart', function(e) {"
    "  e.preventDefault(); touching = true;"
    "  var p = getNormPos(e);"
    "  sendTouch('down', p.x, p.y);"
    "}, {passive: false});"
    "masterImg.addEventListener('touchmove', function(e) {"
    "  e.preventDefault();"
    "  var p = getNormPos(e);"
    "  sendTouch('move', p.x, p.y);"
    "}, {passive: false});"
    "masterImg.addEventListener('touchend', function(e) {"
    "  e.preventDefault(); touching = false;"
    "  sendTouch('up', 0, 0);"
    "}, {passive: false});"
    "</script>"
    "</body></html>";

    response.statusCode = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];
    return response;
}

@end
