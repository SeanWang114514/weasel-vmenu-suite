--[[
前后鼻音模糊过滤器（fuzzy_filter）

依赖 speller/algebra 中启用的 10 条韵尾 n ⇄ ng derive 规则（ang/an、eng/en、
ing/in、iang/ian、uang/uan 成对），prism 编译期把「后鼻音写法」也认成同一音节。

行为：
  * 总开关开（默认）：输入与词的真实拼音只差韵尾 n/ng（模糊命中）时保留候选，
    并把真实拼音写进 comment 的内联标注协议，自编 Weasel 据此把拼音
    以灰色小字画在候选词中间（如 应答 → 「应 ying 答」）。
    调低模糊词权重：除模糊命中外一切候选保持原序；模糊命中的候选
    整体挪到「最后一个精确命中」之后 —— 精确词在前、模糊词紧随其后
    （仍见于候选首页），其余候选（含长尾单字）位置完全不变。
  * 总开关关：模糊命中的候选直接隐藏，只留与输入完全一致的。
  * 逐对开关（2026-09 新增）：总开关开的前提下，某一韵母对
    （an_ang / en_eng / in_ing / ian_iang / uan_uang）单独关掉后，
    「只差这一对」的模糊候选按关闭处理（直接隐藏），其它对照常模糊。
    一个候选里若同时有多个模糊音节、其中任一音节所属的韵母对被关闭，
    整条候选也隐藏（否则会出现「半开半关」的漏网词）。
    分组规则按最长韵尾判定：uang→uan_uang、iang→ian_iang、ang→an_ang、
    eng→en_eng、ing→in_ing；识别不了的韵尾（如 ong/on 打字容错规则）
    不受逐对开关影响，维持旧行为。

开关文件：<用户目录>\fuzzy-settings.txt
  nasal=true|false          总开关（缺省 = true）
  nasal_an_ang=true|false   逐对开关，缺省 = true（共 5 对）
  nasal_en_eng / nasal_in_ing / nasal_ian_iang / nasal_uan_uang 同上
读取节流：最多每秒读一次（os.time 秒级），普通打字路径几乎无磁盘开销。

内联标注协议（comment）：
  "\2" .. "off1:py1;off2:py2;..."
  off = 插入点（候选文本中、对应汉字之后的字符数，1 基），py = 真实拼音音节。
  前缀 \2（STX 控制字符）不会出现在正常注释里，Weasel 端据此识别。

只处理带 spelling_hints 注释（全角 ［拼音］）的候选 —— 即主翻译器的中文候选；
英文 / v 菜单 / 符号 / 部件反查等候选没有该注释，原样放行。

约束（见 AGENT-HANDOFF）：不在普通路径启动进程；对外逻辑 pcall 兜底；
绝不 ctx:set_option；异常时一律原样放行，绝不影响正常输入。
]]

local M = {}

local MARK = "\2"          -- 内联标注协议前缀
local PAIRS = { "an_ang", "en_eng", "in_ing", "ian_iang", "uan_uang" }
local last_sec = -1
-- 默认全部开启（与旧版 nasal=true 行为一致）
local cached = { master = true,
                 pairs = { an_ang = true, en_eng = true, in_ing = true,
                           ian_iang = true, uan_uang = true } }

local function user_dir()
  local ok, d = pcall(rime_api.get_user_data_dir)
  if ok and type(d) == "string" and d ~= "" then return d end
  return "."
end

-- 读开关（每秒最多一次；文件缺失/字段缺失 = 维持当前值，默认 true）
-- 读全文再逐字段找，对首行注释（GUI 写入的标题行）免疫。
-- 注意 nasal= 的模式要求 = 紧跟在 nasal 后（允空格），不会误中 nasal_an_ang=。
local function read_switch()
  local now = os.time()
  if now ~= last_sec then
    last_sec = now
    local ok, f = pcall(io.open, user_dir() .. "/fuzzy-settings.txt", "r")
    if ok and f then
      local all = f:read("*a")
      f:close()
      if all then
        local flag = all:match("nasal%s*=%s*(%a+)")
        if flag then cached.master = (flag == "true") end
        for _, p in ipairs(PAIRS) do
          local v = all:match("nasal_" .. p .. "%s*=%s*(%a+)")
          if v then cached.pairs[p] = (v == "true") end
        end
      end
    end
  end
  return cached
end

-- 一个真实音节属于哪一对前后鼻音（给逐对开关用）。
-- 输入是「真实拼音」；按 n/ng 里较长的那个写法判组：
--   uang → uan_uang、iang → ian_iang、ang → an_ang、eng → en_eng、ing → in_ing
-- 认不出来（ong/on 这类打字容错派生）返回 nil = 不受逐对开关管。
local function pair_of(real)
  local last = real:sub(-1)
  local long
  if last == "n" then long = real .. "g"
  elseif last == "g" then long = real
  else return nil end
  local n = #long
  if n >= 4 and long:sub(-4) == "uang" then return "uan_uang" end
  if n >= 4 and long:sub(-4) == "iang" then return "ian_iang" end
  if n >= 3 and long:sub(-3) == "ang" then return "an_ang" end
  if n >= 3 and long:sub(-3) == "eng" then return "en_eng" end
  if n >= 3 and long:sub(-3) == "ing" then return "in_ing" end
  return nil
end

-- 数字符号数（UTF-8 码点个数；Lua 模式没有 |，先整体吞多字节序列再数剩余字节）
local function cp_len(s)
  local n = 0
  s = s:gsub("[\194-\244][\128-\191]+", function() n = n + 1 return "" end)
  return n + #s
end

-- 拆分 ［拼音］ 注释为音节表；非法（空 / 含分隔符残留）返回 nil
local function syllables_of(hint)
  local syls = {}
  for tok in hint:gmatch("%S+") do
    tok = tok:lower():gsub("ü", "v"):gsub("'", "")
    if #tok == 0 then return nil end
    syls[#syls + 1] = tok
  end
  if #syls == 0 then return nil end
  return syls
end

-- 一个真实音节允许的输入写法：{ {form=, fuzz=bool}, ... }
-- 第一项永远是原样（fuzz=false），第二项是韵尾 n ⇄ ng 变体（fuzz=true）
local function variants_of(sy)
  local t = { { form = sy, fuzz = false } }
  local n = #sy
  if n >= 3 and sy:sub(-2) == "ng" then
    t[#t + 1] = { form = sy:sub(1, -2), fuzz = true }  -- ying 可输 yin
  elseif n >= 2 and sy:sub(-1) == "n" then
    t[#t + 1] = { form = sy .. "g", fuzz = true }      -- yin  可输 ying
  end
  return t
end

-- 把输入串与音节表逐音节对齐。
-- prefer_variant=false：精确写法优先（多数情形一次通过）；
-- prefer_variant=true ：模糊写法优先（处理「精确前缀会剩尾巴」的歧义，如 nang/nan）。
-- 成功返回 segs（模糊音节的 {at=字序, py=真实音节} 列表，at 为插入点）、fuzzed；
-- 任一音节对不上或输入有剩余 → 返回 nil（原样放行）。
local function align(raw, syls, prefer_variant)
  local pos = 1
  local segs = {}
  local fuzzed = false
  for i = 1, #syls do
    local vs = variants_of(syls[i])
    local pick = nil
    if prefer_variant then
      for _, v in ipairs(vs) do
        if v.fuzz and raw:sub(pos, pos + #v.form - 1) == v.form then pick = v break end
      end
      if not pick then
        for _, v in ipairs(vs) do
          if not v.fuzz and raw:sub(pos, pos + #v.form - 1) == v.form then pick = v break end
        end
      end
    else
      for _, v in ipairs(vs) do
        if not v.fuzz and raw:sub(pos, pos + #v.form - 1) == v.form then pick = v break end
      end
      if not pick then
        for _, v in ipairs(vs) do
          if v.fuzz and raw:sub(pos, pos + #v.form - 1) == v.form then pick = v break end
        end
      end
    end
    if not pick then return nil, false end
    pos = pos + #pick.form
    if pick.fuzz then
      fuzzed = true
      segs[#segs + 1] = { at = i, py = syls[i] }
    end
  end
  if pos - 1 ~= #raw then return nil, false end
  return segs, fuzzed
end

-- 分类一个候选：返回 nil（不处理）或 { fuzz=bool, segs=..., blocked=bool }
-- blocked：模糊命中里有任何一个音节所属的韵母对被逐对开关关掉（→ 应隐藏）
local function classify(cand, raw, pairs)
  local cmt = cand.comment
  if type(cmt) ~= "string" then return nil end
  local hint = cmt:match("^［(.-)］$")
  if not hint or #hint == 0 then return nil end
  local syls = syllables_of(hint)
  if not syls then return nil end
  local text = cand.text
  if type(text) ~= "string" or #text == 0 then return nil end
  local nchar = cp_len(text)
  if nchar ~= #syls then return nil end        -- 音节数与字数不一致（组句/残缺）→ 放行
  local segs, fuzzed = align(raw, syls, false)
  if segs == nil then segs, fuzzed = align(raw, syls, true) end
  if segs == nil then return nil end           -- 对不上（简拼/补全/异拼）→ 原样放行
  local blocked = false
  if fuzzed and pairs then
    for _, s in ipairs(segs) do
      local p = pair_of(s.py)
      if p and pairs[p] == false then blocked = true break end
    end
  end
  return { fuzz = fuzzed, segs = segs, blocked = blocked }
end

function M.func(input, env)
  local master = false
  local pairs = nil
  local okr, cfg = pcall(read_switch)
  if okr and type(cfg) == "table" then
    master = (cfg.master ~= false)
    pairs = cfg.pairs
  else
    master = true            -- 读开关失败按旧行为（开）走，绝不影响输入
  end

  local raw = ""
  local oki, inp = pcall(function() return env.engine.context.input end)
  if oki and type(inp) == "string" then raw = inp end
  raw = raw:lower():gsub("ü", "v"):gsub("'", "")
  local is_plain = #raw > 0 and raw:match("^[a-z]+$") ~= nil

  if not is_plain then
    -- 非纯字母输入（v 菜单/符号/部件反查等）：整段原样放行
    for cand in input:iter() do yield(cand) end
    return
  end

  if not master then
    -- 总开关关：仅模糊命中的丢弃，其余保持原序流式放行
    for cand in input:iter() do
      local okc, r = pcall(classify, cand, raw, pairs)
      local drop = okc and r ~= nil and r.fuzz
      if not drop then yield(cand) end
    end
    return
  end

  -- 总开关开（调低模糊词权重）：除模糊命中外一切保持原序；
  -- 被逐对开关挡住的模糊词直接隐藏；
  -- 其余模糊命中的候选整体挪到「最后一个精确命中」之后 —— 精确词在前、
  -- 模糊词紧随其后（仍见于候选首页、带灰色拼音），其余长尾位置不变。
  local stream, lastA, fuzz = {}, 0, {}
  for cand in input:iter() do
    local okc, r = pcall(classify, cand, raw, pairs)
    if okc and r then
      if r.fuzz then
        if not r.blocked then
          pcall(function()
            local spec = {}
            for _, s in ipairs(r.segs) do spec[#spec + 1] = s.at .. ":" .. s.py end
            cand:get_genuine().comment = MARK .. table.concat(spec, ";")
          end)
          fuzz[#fuzz + 1] = cand
        end
        -- blocked 的候选既不进 stream 也不进 fuzz = 直接隐藏
      else
        stream[#stream + 1] = cand
        lastA = #stream                   -- 记录最后一个精确命中的位置
      end
    else
      stream[#stream + 1] = cand
    end
  end
  if lastA == 0 then lastA = #stream end  -- 没有任何精确命中 → 模糊词沉底
  for i = 1, lastA do yield(stream[i]) end
  for i = 1, #fuzz do yield(fuzz[i]) end
  for i = lastA + 1, #stream do yield(stream[i]) end
end

return M
