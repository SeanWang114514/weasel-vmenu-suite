--[[
smart_punct —— 网址 / 路径上下文的智能标点 processor

需求（用户 2026-09-27）：
  1. 输入具有网址特征时，句号。自动变半角 '.'。
  2. 输入是电脑路径（D:\软件）时，后续 \ 输出 ASCII '\'（顿号变反斜杠）、: 输出 ':'。
  3. 设置窗口可开关（smart-punct-settings.txt: smart_punct=true，默认开）。

机制（librime 链，本机实测结论）：
  * rime 原生识别 www./http:// 等前缀（recognizer url 模式）→ 这些已经全对，无需干预。
  * 真正的痛点是「裸域名首点」：google.com / file.txt 中第一个点会触发
    punctuator 的 {commit:'。'} 立即上屏，毁掉整个网址。
    —— 本处理器在该瞬间判断：点号前的字母是否构成**合法拼音词**。
       合法（nihao/baidu…）→ 放行（保持句号自动上屏，中文习惯零变化）；
       非法（google/file/txt/www…）→ 把 '.' 原样推进输入（不触发自动上屏），
       后续字母一到，recognizer/matcher 的 url 模式接管整段原文上屏。
  * 路径中的 '.'（C:\a.b.txt）同理原样推进，避免 {commit} 中途毁掉路径。
  * 标点「输出成 ASCII」由 smart_punct_filter 完成（重写 punct 候选文本）。

返回码约定（librime-lua）：1=kAccepted，2=kNoop。全程 pcall，异常一律 2。
]]

-- ── 拼音校验：共享模块 smart_pinyin（音节表 + 回溯切分） ──────────────
local ok_py, PY = pcall(require, "smart_pinyin")
local function pinyin_valid(s)
  if not ok_py or type(PY) ~= "table" then return false end -- 模块缺失：保守判非拼音
  local ok_r, r = pcall(PY.valid, s)
  return ok_r and r == true
end

-- ── 设置（1 秒节流，文件缺失=默认开） ────────────────────────────────
local last_sec, cached_on, cached_log = -1, true, false

local function user_dir()
  local ok, d = pcall(rime_api.get_user_data_dir)
  if ok and type(d) == "string" and d ~= "" then return d end
  return "."
end

local function read_settings()
  local now = os.time()
  if now ~= last_sec then
    last_sec = now
    local ok, f = pcall(io.open, user_dir() .. "/smart-punct-settings.txt", "r")
    if ok and f then
      local all = f:read("*a")
      f:close()
      if all then
        local on = all:match("smart_punct%s*=%s*(%a+)")
        if on then cached_on = (on == "true") end
        local lg = all:match("smart_punct_log%s*=%s*(%a+)")
        cached_log = (lg == "true")
      else
        cached_on, cached_log = true, false
      end
    end
  end
  return cached_on, cached_log
end

local function dbg_log(line, enabled)
  if not enabled then return end
  pcall(function()
    local f = io.open(user_dir() .. "/smart-punct.log", "a")
    if f then f:write(os.date("%H:%M:%S") .. " " .. line .. "\n") f:close() end
  end)
end

-- ── 上下文 ────────────────────────────────────────────────────────────
local function path_ctx(s)
  return s:match("^[A-Za-z]:") ~= nil or s:match("^\\\\") ~= nil
end

local function url_prefix(s)
  local l = s:lower()
  return l:match("^https?://") ~= nil or l:match("^ftp[.:]") ~= nil
      or l:match("^mailto:") ~= nil or l:match("^file://") ~= nil
      or l:match("^www%.") ~= nil or l:match("^localhost") ~= nil
end

-- ── 盘符路径标记 ─────────────────────────────────────────────────────
-- `D:` 会因 punctuator 的自动上屏把输入清空，filter 看不到后续路径语境。
-- 处理器在盘符冒号/大写盘符处置 smart_punct_path 选项，filter 读同一选项。
-- ★ 标记必须**整条路径期间保持**（长路径 D:\软件\项目\文档 的每一段 `\` 都要改写），
--   只在「路径结束」的键上复位：空格 / 回车 / ESC / 退格清空；输入自带盘符时自愈。
local last_upper = false

local function set_path_mark(ctx, on)
  pcall(function() ctx:set_option("smart_punct_path", on) end)
end

local function get_path_mark(ctx)
  local ok, v = pcall(function() return ctx:get_option("smart_punct_path") end)
  return ok and v or false
end

-- ── 主流程 ────────────────────────────────────────────────────────────
local function handle(key, env)
  local ok_on, on, want_log = pcall(read_settings)
  if not ok_on then on, want_log = true, false end

  local ctx = env.engine.context
  local okc, kc = pcall(function() return key.keycode end)
  local okr, repr = pcall(function() return key:repr() end)
  if not okr or type(repr) ~= "string" then repr = "" end

  -- 路径模式终止键：空格 / 回车 / ESC / 退格清空 → 复位标记（避免残留误伤中文标点）
  if not key:release() then
    local is_end = (okc and kc == 0x20)
      or repr == "Return" or repr == "KP_Enter" or repr == "Escape"
    if not is_end and repr == "BackSpace" then
      local ok_i, ci = pcall(function() return ctx.input end)
      is_end = (ok_i and ci == "")
    end
    if is_end and get_path_mark(ctx) then
      set_path_mark(ctx, false)
      dbg_log("path-mode off <" .. repr .. ">", want_log)
    end
  end

  if key:release() then
    -- TEMP-DEBUG: release tracing
    if want_log then
      local ci = "?"
      pcall(function() ci = ctx.input or "" end)
      dbg_log(string.format("REL %s input=<%s>", repr ~= "" and repr or "?", ci), true)
    end
    return 2
  end

  -- 用 keycode 取字符（repr 对标点是 "backslash"/"Shift+colon" 等名字）
  if not okc or type(kc) ~= "number" or kc < 0x21 or kc > 0x7E then return 2 end
  local ch = string.char(kc)
  if not on then return 2 end

  local ok_opt, ascii = pcall(function() return ctx:get_option("ascii_punct") end)
  if ok_opt and ascii then return 2 end

  local ok_in, input = pcall(function() return ctx.input end)
  if not ok_in or type(input) ~= "string" then input = "" end
  local s = input .. ch

  local action = "pass"

  -- 3) 盘符路径标记（`D:` 自动上屏清空输入后，后续 `\` 靠 option 传语境给 filter）
  --    注意：标记类动作绝不吞键，按键必须继续走 punctuator 原有流程。
  local pth = get_path_mark(ctx)
  local note = nil
  if ch == ":" then
    if input:match("^[A-Za-z]$") or (input == "" and last_upper) then
      set_path_mark(ctx, true)
      pth = true
      note = "set-path-marker"
    end
  elseif ch == "\\" then
    if pth then note = "slash-path" end
  end
  -- 自愈：只要输入里已经能看到盘符路径（D: / C:\），就把标记续上（长路径跨段靠它）
  if path_ctx(s) and not pth then
    set_path_mark(ctx, true)
    pth = true
    note = note or "path-ctx-marker"
  end
  -- 大写盘符（不进组合、原样上屏）记忆：紧跟其后的 `:` 视为盘符冒号
  if kc >= 0x41 and kc <= 0x5A and input == "" then
    last_upper = true
  else
    last_upper = false
  end
  -- 1) 路径语境中的 '.'（C:\a.b.txt）：绕过 punctuator 的 {commit}，原样入栈；
  --    输出阶段由 smart_punct_filter 把 。 重写成 。
  if ch == "." and path_ctx(s) and not url_prefix(s) then
    local ok_push = pcall(function() ctx:push_input(ch) end)
    if ok_push then action = "raw-dot-path" end

  -- 2) 裸域名首点：点号前是纯字母数字且**不构成合法拼音词** → 判为网址，原样入栈
  elseif ch == "." and input ~= "" and input:match("^[a-z0-9%.%-]+$")
      and not url_prefix(s) and not pinyin_valid(input:lower()) then
    local ok_push = pcall(function() ctx:push_input(ch) end)
    if ok_push then action = "raw-dot-url" end
  end

  dbg_log(string.format("key=%s input=<%s> action=%s%s", ch, input, action,
    note and (" " .. note) or ""), want_log)

  if action ~= "pass" then return 1 end
  return 2
end

local function processor(key, env)
  local ok, res = pcall(handle, key, env)
  if ok and type(res) == "number" then return res end
  return 2
end

return processor
