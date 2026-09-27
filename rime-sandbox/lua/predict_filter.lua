-- predict_filter —— 下一个候选词预测（字级 bigram 上下文预测）
--
-- 场景（用户原话）：上屏「太」后输入 yang，把「阳」提到候选第 1 位；
--   输入长段文字时同样有效：上屏「眼睛」后输入 jing，把第 6 位的「睛」提到第 1 位。
--   语料实测：P(阳|太)=0.132、P(睛|眼)=0.110、P(京|北)=0.099。
--
-- 机制（全部在内存里完成：不碰磁盘、不 set_option、不起子进程、pcall 兜底）：
--   1) 上下文优先取「当前组合里已锁定的汉字」（长句逐段选词时也能跟上），
--      没有锁定部分时取 commit_history 里上一次上屏的候选文本（thru / raw 除外），
--      取其最后一个 CJK 字。
--   2) 用 <用户目录>\predict-bigram.txt 查 P(候选首字 | 上文字)：
--      ≥ STRONG_P 的候选按概率降序提到最前（最多 MAX_PROMOTE 个），
--      其余候选保持原相对顺序；没有候选过线则整个原样放行（不改 quality）。
--   3) 改了顺序就把缓冲区的 quality 改成严格递减 1000000-k（约束 4）。
--
-- 数据文件：UTF-8 无 BOM、**LF 换行**的按行文本（用 rb 读，字节偏移才对得上）：
--     RIMEBI1 <n>
--     <字>\t<bucket 偏移 010 位>\t<bucket 长度 06 位>     （n 行索引）
--     ... bucket 区：<总次数>\t<字>=<次数> <字>=<次数> ...
--   重建：python corpus\build_bigram.py <语料> predict-bigram.txt
--   （本机当前数据来自中文维基语料 9370 万字符，成品 2.3MB；init 时一次读入约 5ms）。
--
-- 挂载位置：engine/filters 里 v_filter 之后、pin_cand_filter 之前
--   （pin 置顶、长词提升、收藏固定第 2 位都在它后面，行为不受影响）。
--
-- 约束对照（AGENT-HANDOFF §2）：1 不起子进程；2 全链 pcall 兜底、出错原样放行；
--   3 打字路径零磁盘 IO（init 一次性读入）；4 yield 顺序 + quality 严格递减；
--   33 不调 set_option。
local M = {}

local STRONG_P = 0.02   -- P(首字|上文字) 达到这个概率才提到前面
local MAX_PROMOTE = 3   -- 最多往前提几个
local BUFFER_CAP = 100  -- 重排时最多缓冲多少条候选（pin_cand 同量级）
local CACHE_CAP = 48    -- bucket 解析缓存上限（防止长会话内存增长）

local data = nil        -- 文件全文（init 读一次）
local boff, blen = {}, {} -- 字 -> bucket 字节偏移 / 长度
local buckets = {}      -- 字 -> { total=, map= } 解析缓存
local bucket_n = 0

local function user_dir()
  local ok, d = pcall(rime_api.get_user_data_dir)
  if ok and type(d) == "string" and d ~= "" then return d end
  return "."
end

-- 一次性读入 + 建行索引（init 阶段执行，不在打字路径上）
local function load_data()
  local f = io.open(user_dir() .. "/predict-bigram.txt", "rb")
  if not f then return false end
  local all = f:read("*a")
  f:close()
  if type(all) ~= "string" or #all < 16 then return false end
  local nl1 = all:find("\n", 1, true)
  if not nl1 then return false end
  local magic, n = all:sub(1, nl1 - 1):match("^(%S+)%s+(%d+)$")
  if magic ~= "RIMEBI1" or not n then return false end
  n = tonumber(n) or 0
  local o, l = {}, {}
  local pos = nl1 + 1
  for _ = 1, n do
    local nl = all:find("\n", pos, true)
    if not nl then break end
    local ch, off, len = all:sub(pos, nl - 1):match("^(.-)\t(%d+)\t(%d+)$")
    if ch then
      o[ch] = tonumber(off)
      l[ch] = tonumber(len)
    end
    pos = nl + 1
  end
  if next(o) == nil then return false end
  data = all
  boff, blen = o, l
  return true
end

function M.init(env)
  if data ~= nil then return end
  pcall(load_data)
end

-- 取某个上文字的二元表（解析一次后进小缓存）
local function bucket_of(ch)
  local b = buckets[ch]
  if b then return b end
  local off = boff[ch]
  if not off or data == nil then return nil end
  -- 文件里是 0 基字节偏移，Lua string.sub 是 1 基 → +1；长度给出边界
  local blob = data:sub(off + 1, off + blen[ch])
  local total_s, rest = blob:match("^(%d+)\t(.*)$")
  if not total_s then return nil end
  local total = tonumber(total_s)
  if not total or total <= 0 then return nil end
  local map = {}
  for s, c in rest:gmatch("([^ =]+)=(%d+)") do
    map[s] = tonumber(c) or 0
  end
  b = { total = total, map = map }
  if bucket_n >= CACHE_CAP then
    buckets = {}
    bucket_n = 0
  end
  buckets[ch] = b
  bucket_n = bucket_n + 1
  return b
end

-- 字符串最后一个字符必须是 CJK 才作为上下文（标点结尾 = 句边界，不猜）
local function last_cjk(s)
  if type(s) ~= "string" or s == "" then return nil end
  local i = utf8.offset(s, -1)
  if not i then return nil end
  local cp = utf8.codepoint(s, i)
  if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) then
    return s:sub(i)
  end
  return nil
end

local function get_context(ctx)
  -- 1) 当前组合里已锁定的汉字（preedit = 已锁定文本 + 未锁定的原始字母）
  local okp, pe = pcall(function() return ctx:get_preedit().text end)
  if okp and type(pe) == "string" and pe ~= "" then
    local stem = pe:gsub("[a-z]+$", "")  -- 去掉尾部还没上屏的拼音
    stem = stem:gsub("%s", "")
    if stem ~= "" and not stem:match("^[%a]+$") then
      -- 只剩字母（例如格式化 preedit 的前缀音节）= 没有锁定部分，落到下面的历史；
      -- 有锁定文本则以其最后一个 CJK 字为上下文（标点结尾返回 nil，不当上下文）
      return last_cjk(stem)
    end
  end
  -- 2) 上一次上屏的候选（thru=原样按键、raw=原样上屏都不算）
  local okh, rec = pcall(function() return ctx.commit_history:back() end)
  if okh and rec ~= nil then
    local tx = rec.text
    local ty = rec.type
    if ty ~= "thru" and ty ~= "raw" and type(tx) == "string" and tx ~= "" then
      return last_cjk(tx)
    end
  end
  return nil
end

-- 与 vmenu_core.mode_of 同步（独立内联，避免跨组件 require 的模块副本差异）
local function is_vmenu(code)
  if code == "v" then return true end
  if code:sub(1, 5) == "vclip" then return true end
  if code:sub(1, 4) == "vfav" then return true end
  if code:sub(1, 3) == "vqi" then return true end
  if code:sub(1, 4) == "vset" then return true end
  return false
end

-- 分析阶段：全部包在 pcall 里；缓冲结果放在外部 st 里，出错也能原样放出
local function analyze(input, env, st)
  if data == nil then return nil end
  local ok, code = pcall(function() return env.engine.context.input end)
  if not ok or type(code) ~= "string" or code:match("^[a-z]+$") == nil then
    return nil
  end
  if is_vmenu(code) or code:match("^u[a-z]+$") then return nil end -- v 菜单 / 部件反查不掺和
  local ok_a, ascii = pcall(function()
    return env.engine.context:get_option("ascii_mode")
  end)
  if ok_a and ascii then return nil end

  local ok_c, ch = pcall(get_context, env.engine.context)
  if not ok_c or ch == nil then return nil end
  local ok_b, bucket = pcall(bucket_of, ch)
  if not ok_b or bucket == nil then return nil end

  -- 缓冲候选（够 BUFFER_CAP 就停，后面的走原样透传）
  for cand in input:iter() do
    st.n = st.n + 1
    st.buf[st.n] = cand
    if st.n >= BUFFER_CAP then break end
  end
  if st.n == 0 then return { promote = false } end

  -- 打分：候选首字在二元表里的条件概率
  local strong = {}
  for i = 1, st.n do
    local t = st.buf[i].text
    local cnt = nil
    if type(t) == "string" and t ~= "" then
      local fc = t:match("^" .. utf8.charpattern)
      if fc then cnt = bucket.map[fc] end
    end
    if cnt then
      local p = cnt / bucket.total
      if p >= STRONG_P then
        strong[#strong + 1] = { i = i, p = p }
      end
    end
  end
  if #strong == 0 then return { promote = false } end

  table.sort(strong, function(a, b)
    if a.p ~= b.p then return a.p > b.p end
    return a.i < b.i
  end)
  local picked = {}
  local order = {}
  local np = #strong
  if np > MAX_PROMOTE then np = MAX_PROMOTE end
  for k = 1, np do
    local idx = strong[k].i
    picked[idx] = true
    order[#order + 1] = idx
  end
  for i = 1, st.n do
    if not picked[i] then order[#order + 1] = i end
  end
  return { promote = true, order = order }
end

function M.func(input, env)
  local st = { buf = {}, n = 0 }
  local ok, plan = pcall(analyze, input, env, st)
  if not ok or plan == nil or not plan.promote then
    -- 无上下文 / 无数据 / 没有候选过线 / 中途出错：缓冲的按原顺序放，再放后续
    for i = 1, st.n do
      yield(st.buf[i])
    end
    for cand in input:iter() do
      yield(cand)
    end
    return
  end
  local k = 0
  for _, idx in ipairs(plan.order) do
    local c = st.buf[idx]
    if c ~= nil then
      k = k + 1
      pcall(function() c.quality = 1000000 - k end)
      yield(c)
    end
  end
  for cand in input:iter() do
    yield(cand)
  end
end

return M
