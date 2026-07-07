# 懒人精灵 Plist API 使用指南

## 接口地址

```
http://<设备IP>:8182/api/plist?path=<plist绝对路径>
```

## 读取 Plist

```lua
gameid = "com.jao.yhdl"
dataPath = appDataPath(gameid)
plistPath = dataPath .. "/Library/Preferences/com.jao.yhdl.plist"

local fullUrl = "http://192.69.0.45:8182/api/plist?path=" .. plistPath
local res, code = httpGet(fullUrl)

print("响应码：" .. tostring(code))
print("返回内容：" .. tostring(res))

-- 解析 jieao_GameSid
local gameSid = string.match(res, '<key>jieao_GameSid</key>%s*<string>([^<]+)</string>')
print("jieao_GameSid = " .. tostring(gameSid))

-- 匹配所有 userOftenServer 开头的 key
for key, val in string.gmatch(res, '<key>(userOftenServer[^<]+)</key>%s*<string>([^<]+)</string>') do
    print(key .. " = " .. val)
end
```

## 修改 Plist（新格式）

**注意：body 必须包含 `path` 字段，否则走旧格式会直接覆盖整个文件！**

```lua
gameid = "com.jao.yhdl"
dataPath = appDataPath(gameid)
plistPath = dataPath .. "/Library/Preferences/com.jao.yhdl.plist"

local fullUrl = "http://192.69.0.45:8182/api/plist?path=" .. plistPath
local headers = {
    ["Content-Type"] = "application/json"
}
local body = {
    ["path"] = plistPath,           -- 必须有
    ["set"] = {
        jieao_GameSid = "15"        -- 精确设置某个 key 的值
    },
    ["match"] = "userOftenServer",  -- 可选：模糊匹配 key（key 包含此字符串即匹配）
    ["matchValue"] = "15"           -- 匹配到的 key 统一改成此值
}
local res, code = httpPost(fullUrl, jsonLib.encode(body), headers)

print("响应码：" .. tostring(code))
print("返回内容：" .. tostring(res))

-- 简单解析返回的 success
local ok = string.match(res, '"success"[:%s]+([%l%p]+)')
print("是否成功：" .. tostring(ok))

-- 解析 modified 列表（被修改的 key）
for key in string.gmatch(res, '"([^"]+)"') do
    if string.find(key, "jieao") or string.find(key, "userOftenServer") then
        print("修改了：" .. key)
    end
end
```

## body 参数说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | **必填** | plist 文件的完整绝对路径 |
| `set` | object | 可选 | key-value 对，精确设置值 |
| `match` | string | 可选 | 模糊匹配 key（key 包含此字符串才匹配） |
| `matchValue` | string | 可选 | 匹配到的 key 统一改成此值 |

## 返回值示例

```json
{
  "success": true,
  "path": "/var/mobile/Containers/Data/Application/.../com.jao.yhdl.plist",
  "data": {
    "jieao_GameSid": "15",
    "userOftenServer12419641": "15"
  },
  "modified": [
    "jieao_GameSid",
    "userOftenServer12419641"
  ]
}
```

## 注意事项

1. **懒人精灵函数名**：不同版本 HTTP 函数名可能不同，常见的有 `httpPost`/`httpGet`、`http.post`/`http.get`、`fetch` 等，请根据实际版本确认
2. **JSON 编码**：懒人精灵内置 `json` 或 `cjson` 库，`jsonLib.encode(body)` 或 `cjson.encode(body)`
3. **修改时机**：游戏 App 运行时会主动重写 plist，建议在游戏关闭或进入服务器选择界面时调用 API
4. **iOS 设备需安装 TrollVNC**：API 服务运行在设备的 8182 端口，设备需安装 v3.2-332+ 版本
