--[[
smart_punct_filter —— 路径 / 网址语境下把中文标点候选拼成 ASCII（dsh: smart_punct 配套滤镜）

原理：
  rime 的 punctuator 把 \ → 顿号、: → 全角冒号、. → 句号（候选已确认、
  只是尚未上屏）。本滤镜在候选流经过时：
    * 判定当前输入是否处于「路径」（^[A-Za-z]: 或 UNC）或「网址」语境
      （www./http:// 等前缀，或输入中已含点的纯 ASCII 形态）；
    * 命中则把 punct 类型候选的文本 ASCII 化（。→. ：→: 、→\ 等），
      候选类型保持 "punct"（不破坏 punctuator 的 translated 检查）；
    * 未命中零开销原样放行，普通中文输入完全不受影响。

开关：与 smart_punct 共用 <用户目录>\smart-punct-settings.txt，
      smart_punct=false 时整条滤镜放行（1 秒节流读取）。
]]

local M = {}

local last_sec, cached_on = -1, true

-- 共享拼音校验（裸域名判定与 processor 一致）
local ok_py, PY = pcall(require, "smart_pinyin")
local function pinyin_valid(s)
  if not ok_py or type(PY) ~= "table" then return false end
  local ok_r, r = pcall(PY.valid, s)
  return ok_r and r == true
end

local function user_dir()
  local ok, d = pcall(rime_api.get_user_data_dir)
  if ok and type(d) == "string" and d ~= "" then return d end
  return "."
end

local function read_switch()
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
      else
        cached_on = true
      end
    end
  end
  return cached_on
end

-- 中文标点 → ASCII 映射
local MAP = {
  ["。"] = ".", ["、"] = "\\", ["："] = ":", ["，"] = ",",
  ["；"] = ";", ["？"] = "?", ["！"] = "!", ["·"] = "-",
}

-- 仅靠「路径标记」命中时只改写路径里真正会出现的标点（：。、·），
-- 不碰 ，；？！ —— 长路径标记会一直保留到空格/回车，收窄范围可避免残留误伤正文标点。
local MAP_PATH = {
  ["。"] = ".", ["、"] = "\\", ["："] = ":", ["·"] = "-",
}

local function path_ctx(inp)
  return inp:match("^[A-Za-z]:") ~= nil or inp:match("^\\\\") ~= nil
end

local function url_ctx(inp)
  local l = inp:lower()
  if l:match("^https?://") or l:match("^ftp[.:]") or l:match("^mailto:")
     or l:match("^file://") or l:match("^www%.") or l:match("^localhost") then
    return true
  end
  -- 裸域名中间态：纯 ASCII 且已含点，且**去掉标点后不是合法拼音词**
  -- （与 smart_punct processor 同一判定：nihao. 是中文句号，不改写；google. 才改）
  if l:match("^[a-z0-9%.%-]+$") and l:find(".", 1, true) then
    local letters = l:gsub("[^a-z]", "")
    return not pinyin_valid(letters)
  end
  return false
end

function M.func(input, env)
  local ok_on, on = pcall(read_switch)
  if not ok_on then on = true end
  if not on then
    for cand in input:iter() do yield(cand) end
    return
  end

  local inp = ""
  local ok_i, v = pcall(function() return env.engine.context.input end)
  if ok_i and type(v) == "string" then inp = v end

  local pth = false
  pcall(function() pth = env.engine.context:get_option("smart_punct_path") == true end)
  local strong = path_ctx(inp) or url_ctx(inp)   -- 输入自身就能判定是路径/网址
  local hit = strong or pth
  if not hit then
    for cand in input:iter() do yield(cand) end
    return
  end
  local map = strong and MAP or MAP_PATH

  -- 收集模式改写（与 fuzzy_filter/en_gate 同构，避免迭代中 yield）
  local okIt, it, istate = pcall(function() return input:iter() end)
  if not okIt or type(it) ~= "function" then
    for cand in input:iter() do yield(cand) end
    return
  end
  local out = {}
  local ctrl = nil
  while true do
    local okn, cand = pcall(it, istate, ctrl)
    if not okn or cand == nil then break end
    ctrl = cand
    local okw, new = pcall(function()
      if cand.type == "punct" then
        local m = map[cand.text]
        if m then
          -- librime-lua 候选字段：start=数字、_end=数字（"end" 为 nil！）
          local st = tonumber(cand.start) or 0
          local en = tonumber(cand._end) or tonumber(cand["end"]) or st + #tostring(cand.text)
          return Candidate("punct", st, en, m, cand.comment)
        end
      end
      return nil
    end)
    if okw and new ~= nil then
      out[#out + 1] = new
    else
      out[#out + 1] = cand      -- 判定出错时保守保留原候选
    end
  end
  for i = 1, #out do yield(out[i]) end
end

return M
