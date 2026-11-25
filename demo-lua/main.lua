-- Lua 扩展示例（宿主内置 Lua 5.4）
-- 必须 return 一个模块表；build(ctx) 返回界面元素数组。
-- 可用 API 只有 mt.*，没有 io/os.execute/dofile，不会碰沙盒外的实现细节。

local function fmt_size(n)
  if n < 1024 then return n .. " B" end
  if n < 1048576 then return string.format("%.1f KB", n / 1024) end
  return string.format("%.1f MB", n / 1048576)
end

local function ui(ctx)
  local path = mt.values("path")
  if not path or path == "" then path = ctx.path or "/var/mobile" end
  return {
    { type = "header", title = "Lua 扩展示例" },
    { type = "label", text = "当前扩展：" .. (ctx.extensionDir or "-") },
    { type = "dim", text = "沙盒版也能跑：宿主自带解释器，不加载 dylib。" },
    { type = "textfield", id = "path", placeholder = "要列出的目录", value = path },
    { type = "button", title = "列出目录", onTap = function()
        local p = mt.values("path")
        if not p or p == "" then mt.alert("先填一个目录"); return end
        local names = mt.list(p)
        if type(names) ~= "table" then mt.alert("读不到：" .. p); return end
        local lines = { "共 " .. #names .. " 项" }
        for i = 1, math.min(#names, 40) do lines[#lines + 1] = "· " .. names[i] end
        mt.alert(table.concat(lines, "\n"))
    end },
    { type = "button", title = "读取这个目录里第一个文件（前 200 字节）", onTap = function()
        local p = mt.values("path")
        local names = mt.list(p)
        if type(names) ~= "table" or #names == 0 then mt.alert("空目录"); return end
        local f = p .. "/" .. names[1]
        local ok, data = pcall(mt.read, f)
        if not ok or not data then mt.alert("读不了：" .. f); return end
        mt.alert(f .. "\n\n" .. string.sub(data, 1, 200))
    end },
    { type = "button", title = "写一个测试文件（会按信任设置询问）", onTap = function()
        local p = mt.values("path")
        local f = p .. "/lua-demo.txt"
        local ok, err = mt.write(f, "written by lua extension\n" .. os.date("%Y-%m-%d %H:%M:%S"))
        if ok then mt.alert("已写入 " .. f) else mt.alert("失败：" .. tostring(err)) end
    end },
    { type = "button", title = "调用终端：uname -a", onTap = function()
        local r = mt.shell("uname -a")
        if not r then mt.alert("沙盒版不支持调用终端"); return end
        mt.alert((r.output or "") .. "\n退出码 " .. tostring(r.code))
    end },
    { type = "button", title = "网络请求（首次会弹窗征求同意）", onTap = function()
        mt.http("https://lgyz6767.github.io/repo/ext/index.json", function(code, body, err)
            if err then mt.alert("失败：" .. err); return end
            mt.alert("HTTP " .. code .. "，" .. fmt_size(#body) .. " 字节")
        end)
    end },
    { type = "divider" },
    { type = "dim", text = "这个页面全部是原生控件，没有 WebView，脚本出错只弹窗，不会崩宿主。" }
  }
end

return { build = ui }
