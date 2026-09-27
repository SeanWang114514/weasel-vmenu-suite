-- v 功能菜单：候选压制 / 收藏插入滤镜（必须排在 engine/filters 最后）
-- 作用：
--   1) 处于 v 相关模式时，只保留本功能自己的候选，
--      丢掉 script_translator / melt_eng / punctuator 产生的竞争候选
--      （例如输入 v 时的「于 与 vac van var」、输入 vclip 时的英文词）；
--   2) 正常打字时，输入满 3 个字符命中收藏编码，就把收藏内容插到候选第 2 位。
-- 性能：非 v 模式且没命中收藏时直接透传，不做任何缓存表分配，避免影响打字速度。
local core = require("vmenu_core")

local function passthrough(input)
  for cand in input:iter() do
    yield(cand)
  end
end

-- 把 fav 插到第 pos 位，并把整表 quality 改成从高到低递减：
-- 这样无论菜单是按「滤镜产出顺序」还是按「quality 排序」决定先后，结果都一致。
local function place(list, pos, fav)
  local out = {}
  local n = #list
  if pos < 1 then pos = 1 end
  for i = 1, n do
    if i == pos then out[#out + 1] = fav end
    out[#out + 1] = list[i]
  end
  if pos > n then out[#out + 1] = fav end
  for i = 1, #out do
    local c = out[i]
    pcall(function() c.quality = 1000000 - i end)
  end
  return out
end

-- 序号不再由这里（候选注释）产生！
-- 2026-09-18 修正：注释在 Weasel 水平布局里排在候选词的**后面**，实测渲染成
-- 「这个1 这股2」，而且注释是翻译阶段由过滤器生成的 —— 移动高亮不会重新跑过滤器，
-- 所以注释里的序号永远钉在第一行，做不到「按高亮行重新编号」。
-- 现在序号由 Weasel 侧的标签槽负责（WeaselUI/HorizontalLayout.cpp 的 GetLabelText
-- 覆写）：标签槽在词的左侧，每帧重算，随高亮行给 1-9。此文件不再碰 comment。
-- 按「一屏 lim 个 + 页码偏移」取窗口：返回 (候选表, 起止下标)。
-- 普通打字、原符号模式、v 列表共用同一套窗口逻辑（页码由 menu_processor 用 +/- 改）。
-- ★ 这里刻意**不**在函数里 yield：把结果交回调用方再 yield，避免依赖
--   「嵌套函数里 yield」这种 librime-lua 生成器语义。
local function window_of(input, ctx, lim)
  local page = core.page_get(ctx)
  local start = page * lim
  local need = start + lim        -- 本页最多需要前 need 个
  if need < lim then need = lim end
  local buf = {}
  local k = 0
  local t0 = os.clock()
  for cand in input:iter() do
    k = k + 1
    buf[k] = cand
    -- 【卡顿修复】早停：rime-ice 对 1-2 个字母能产出上千条候选，
    -- 而可见窗口最多也就 need 个，把后面全部遍历+建表纯属浪费（每个键都做一遍）。
    if k >= need then break end
  end
  -- 只在真的翻过头时才回到第一页；早停时 k 就是「候选总数不足 need」，判定不变。
  -- ★ 顺手把**页码也复位**：否则页码会停在一个「空页」上（例如第 15 页），
  --   表现是①按了翻页画面没变化（用户以为键坏了）②下一页要多遍历上百个候选（翻页卡顿）。
  if start >= k then
    if page > 0 then pcall(core.page_reset, ctx) end
    start = 0
  end
  do
    local dt = (os.clock() - t0) * 1000
    if dt > 15 then
      core.debug_log(("[vmenu] 候选遍历偏慢 %.1fms (k=%d lim=%d page=%d)"):format(dt, k, lim, page))
    end
  end
  -- [诊断] 每次 filter 运行都把本页候选打一行到 vmenu-debug.log。
  -- 默认关闭：这是**每个按键一次文件写入**，开着会影响按键手感；
  -- 排查「显示的顺序和选中的不是同一个」这类问题时把 core.DEBUG_CAND 改成 true。
  if core.DEBUG_CAND then
    local dbg = {}
    for i = start + 1, math.min(k, start + lim) do
      local c = buf[i]
      if c then
        dbg[#dbg + 1] = ("%d[%s]{%s}%s"):format(i - start, tostring(c.text),
          tostring(c.comment), tostring(c.type))
      end
    end
    core.debug_log(("[vmenu] 本页 page=%d k=%d lim=%d :: %s"):format(page, k, lim,
      table.concat(dbg, " ")))
  end
  return buf, start, k
end

-- [第二十轮] 纯数字常用语编码在候选框里长什么样。
-- 用户诉求（原话）：「输入数字的时候会变成候选状态，也就是无法在输入如 13 的时候直接按 "-" 等
--   按键在后面插入一个 "-"，但是要保留数字作为常用语的编码（… 输入 1 等词的时候不会输入
--   而是正常地加在后面）」。
-- 原来的毛病有两个：
--   ① 只敲了前 2 位（如 13）时候选框是**空的**（实测面板只有 32x8，什么都看不见），
--      用户看到的就是「数字进了候选状态、却哪儿都不显示」；
--   ② 敲满 3 位（131）时框里只有那条常用语，于是方案自己的标点处理
--      （librime 的 punctuator 提交的是「当前选中的候选」）会把整条常用语打出去，
--      而不是把数字留着 —— 这与「只有回车才上屏整条常用语」冲突。
-- 把「已输入的数字本身」做成候选第 1 位（默认选中项），两个毛病一起解决：
--   * 框里看得见自己敲的数字；
--   * `.` `,` 这些标点上屏时提交的是**数字本身**（13 → 「13。」），常用语仍然只有回车才出。
-- type 用 "raw"：与 librime 自己的「原样上屏」候选同类，数字/小数点的识别逻辑也认它。
-- [第二十一轮] digit_cand 已删除 —— 用户诉求（原话）：
--   「把第一个 131 删除 只留下第二个（这个也最好不要显示序号）」
--   纯数字编码输入时只保留「常用语预览」（第 2 位，质量最高），
--   不再在第 1 位插一条「数字本身」的候选（否则用户看到两个带序号的条目很困惑）；
--   序号也由服务端 ctx.grid_2d=2 通知客户端不画（见 HorizontalLayout.cpp GetLabelText）。
--   menu_processor.lua 那边的「数字分支」已经足够：
--   数字能延伸编码 → 并进；延伸不了 → 直接上屏；- / = / + → 上屏数字再插符号。
--   数字作为候选对齐方格已经没必要了，去掉反而干净。

local function filter(input, env)
  local ctx = env.engine.context
  local code = ctx.input

  local want = nil
  local fav = nil

  if type(code) == "string" and code ~= "" then
    local ok_raw, raw = pcall(core.raw, ctx)
    local ok_ascii, ascii = pcall(function() return ctx:get_option("ascii_mode") end)
    if ok_raw and raw then
      -- [原符号模式 = 和普通打字完全同步] 用户反馈：「v5 的候选词选择逻辑没有和正常的
      -- 候选词选择逻辑同步」。原因是这里原来直接 passthrough：候选**全部**放出去
      -- （几十条英文词 / 上百个符号），Weasel 按宽度折成 4 行、只在高亮行画 1-9，
      -- 而服务端的数字键补丁有「输入以 v 开头就不接管」的闸门 → 序号画着却按不动，
      -- 按 3 反而把符号编码补成 v3。
      -- 现在改成和普通打字**同一套**：收起 9 个（一行）/ 展开 36 个（↓ 展开 4 行），
      -- 页码由 +/- 改，数字键按「高亮那一行」选（服务端补丁已对原符号模式放行）。
      local lim = core.grid_limit(ctx)
      local buf, start, k = window_of(input, ctx, lim)
      for i = start + 1, math.min(k, start + lim) do
        if buf[i] then yield(buf[i]) end
      end
      return
    end
    if ok_ascii and ascii then
      passthrough(input)
      return
    end
    want = core.want_type(code)
    if want == nil then
      local t_fav = os.clock()
      local ok_fav, hit = pcall(core.fav_hit, code)
      local dt_fav = (os.clock() - t_fav) * 1000
      if dt_fav > 3 then
        core.debug_log(("[vmenu] fav_hit 偏慢 %.2fms (code=%s)"):format(dt_fav, code))
      end
      if ok_fav and type(hit) == "table" then fav = hit end
    end
  end

  -- [第二十一轮] raw_digit 已删除（见文件顶部注释）。纯数字编码的常用语预览由
  --   下面的 fav 分支自动产出（只占第 2 位，且服务端通知前端不画序号）。

  if want == nil and fav == nil then
    -- 正常打字、没命中收藏：只放出当前状态允许的个数
    --   单行（默认）= 9 个，正好一行；按 ↓ 展开后 = 36 个，自动换成 4 行 × 9 列
    -- 用户要求：「还有保留 + 号下翻选择预选词的功能」：收起态一行只有 9 个，第 10 个以后
    -- 够不着；按 +（下翻）就把可见窗口整体后移一屏（9 或 36 个），序号仍是 1-9
    -- （序号由 Weasel 标签槽按当前可见行给）。窗口逻辑见上面的 window_of。
    local lim = core.grid_limit(ctx)
    local buf, start, k = window_of(input, ctx, lim)
    for i = start + 1, math.min(k, start + lim) do
      if buf[i] then yield(buf[i]) end
    end
    return
  end

  -- [一行 2 个 / 一行 4 个] v 功能菜单的可见个数与翻页：
  --   * 列表模式（剪贴板 / 常用语 / 管理列表）= **固定一屏 6 个**（2 列 × 3 行，永远是展开态，
  --     用户要求「一行 2 个、默认 3 行、默认展开、按上键不要收起」）；加减号按 6 个翻页。
  --   * 静态菜单（v 主菜单 / v3 快捷输入 / 设置根菜单）本来就 5-7 条，全部放出来，
  --     交给 Weasel 按 4 列自动换行（不会把第 5 项「原符号」藏起来）。
  local is_v = (want ~= nil)
  local is_list = is_v and core.is_list_code(code or "")

  local buf = {}
  local n = 0
  local lim = core.grid_limit(ctx)
  if is_v then
    lim = is_list and core.grid_limit(ctx, code) or 36
  end
  local start = 0
  if is_list then
    start = core.page_get(ctx) * lim
  end
  local need = start + lim
  if need < lim then need = lim end
  local stop_n = is_v and need or lim
  for cand in input:iter() do
    if want ~= nil then
      -- v 相关模式：只留自己的候选
      if cand.type == want or cand.type == "vact" then
        n = n + 1
        buf[n] = cand
        if n >= stop_n then break end   -- 【卡顿修复】够一屏就停
      end
    else
      -- 正常打字：全收，顺便把已经存在的同一条收藏候选去掉，避免重复
      if cand.type == "vfav" and cand.text == fav.word then
        -- 丢弃重复
      else
        n = n + 1
        buf[n] = cand
        if n >= lim then break end   -- 【卡顿修复】够一屏就停（收藏还占 1 位，多收 1 个也无妨）
      end
    end
  end

  if want ~= nil then
    if n == 0 then
      passthrough(input)
      return
    end
    -- 翻过头（例如删到只剩 3 条还停在第 2 页）就回第 1 页，绝不留空窗口
    if is_list and start >= n then
      if core.page_get(ctx) > 0 then pcall(core.page_reset, ctx) end
      start = 0
    end
    -- 同样受当前窗口限制：普通打字收起 9 / 展开 36；v 列表固定 6 个。
    for i = start + 1, math.min(n, start + lim) do
      -- v 菜单的序号同样交给 Weasel 的标签槽（v 菜单一行 4 个，按高亮行给 1-4；
      -- 剪贴板 / 常用语一行 2 个，按高亮行给 1-2）。
      -- 候选自带的注释（如快捷输入的「按 1 · …」）保持原样，不再拼数字。
      if buf[i] then yield(buf[i]) end
    end
    -- [诊断] v 功能候选的本页窗口（翻页排查用）：和上面 DEBUG_CAND 同一个开关。
    -- 只在 v 模式下写，普通打字路径不受影响（见 core.DEBUG_CAND 注释）。
    if core.DEBUG_CAND then
      local dbg = {}
      for i = start + 1, math.min(n, start + lim) do
        local c = buf[i]
        if c then
          local t = tostring(c.text):sub(1, 24):gsub("[\128-\191]+$", "")  -- 截断不留半个汉字
          dbg[#dbg + 1] = t
        end
      end
      core.debug_log(("[vmenu] v候选 page=%d start=%d lim=%d n=%d code=%s :: %s")
        :format(core.page_get(ctx), start, lim, n, tostring(code),
          table.concat(dbg, " | ")))
    end
    return
  end

  -- 收藏固定占第 2 位（数字编码输入时这就是唯一的候选：常用语预览）
  local c = Candidate("vfav", 0, #code, fav.word, "常用语")
  c.quality = 500000
  local out = place(buf, 2, c)
  for i = 1, #out do
    if i > lim then break end
    yield(out[i])
  end
end

return filter
