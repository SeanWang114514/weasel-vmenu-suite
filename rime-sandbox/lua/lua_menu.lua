-- v 功能菜单：候选项生成（菜单 / 设置 / 剪贴板 / 收藏）
-- 只在 v 相关模式下产出候选；普通输入直接 return，零开销。
local core = require("vmenu_core")

local ZW = "\226\128\139" -- U+200B，用于操作行占位（点错也不会往文档里写可见字符）

local function cand(seg, t, text, comment, quality)
  local c = Candidate(t, seg.start, seg._end, text, comment or "")
  c.quality = quality
  return c
end

local function item(seg, t, text, comment)
  return cand(seg, t, text, comment, 1000000)
end

local function action(seg, comment, n)
  -- 操作行：文本用零宽字符占位，注释才是给用户看的提示
  return cand(seg, "vact", string.rep(ZW, n or 1), comment, -1000000)
end

-- ===== 主菜单 =====
-- 文案尽量短（候选行越短越好看）：正文 2-4 字，注释也压到最短。
-- 说明：原来的第 5 项「文字设置」（vset 纯键盘设置）已按要求去掉，
--       设置请用第 1 项的可视化窗口。vset* 的代码保留但不再可从菜单进入。
local function yield_menu(seg)
  yield(item(seg, "vmenu", "设置", "图形窗口"))
  yield(item(seg, "vmenu", "剪贴板", "历史"))
  yield(item(seg, "vmenu", "快捷输入", "计算 · 日期"))
  yield(item(seg, "vmenu", "常用语", "快捷内容"))
  yield(item(seg, "vmenu", "原符号", "原版 v"))
end

-- ===== 快捷输入（对应雾凇拼音自带的前缀）=====
-- 快捷键 = 「v3 + 字母」：进子菜单后按 c/r/s/u/n/h 即可（数字 1-6 同样有效，
-- 候选窗口上画出来的标签就是 1-6）。选中后把触发前缀写进输入框，之后的按键交给原方案：
--   c 计算 cC（接着输入算式，如 1+2*3）   r 日期 rq   s 时间 sj
--   u Unicode U（如 4e2d）               n 农历 N+今天   h 数字货币转写 R（如 R1234）
-- 原来直接输入这些前缀的方式全部保留：cC / rq / sj / U / N / R。
-- 星期 xq、日期时间 dt、部件拆字 uU 不在这 6 项里（不再从菜单进入），但方案里仍可直接输入。
local function yield_quick(seg)
  yield(item(seg, "vqi", "计算", "按 c"))
  yield(item(seg, "vqi", "日期", "按 r"))
  yield(item(seg, "vqi", "时间", "按 s"))
  yield(item(seg, "vqi", "Unicode", "按 u"))
  yield(item(seg, "vqi", "农历输入", "按 n"))
  yield(item(seg, "vqi", "数字货币转写", "按 h"))
  yield(item(seg, "vqi", "返回", "按 q"))
end
-- ===== 设置根菜单 =====
local function yield_set(seg)
  local page = core.read_page()
  yield(item(seg, "vset", "剪贴板管理 " .. page .. " 条", "按 1"))
  yield(item(seg, "vset", "常用语管理", "按 2"))
  yield(item(seg, "vset", "显示条数 " .. page, "按 3"))
  yield(item(seg, "vset", "清理缓存", "按 4 · 二次确认"))
  yield(item(seg, "vset", "返回", "按 5"))
end

-- ===== 默认显示条数 =====
local function yield_page_size(seg)
  local page = core.read_page()
  local vals = { 20, 30, 40, 50 }
  for i = 1, #vals do
    local v = vals[i]
    local mark = ""
    if v == page then mark = "（当前）" end
    yield(item(seg, "vset", v .. " 条" .. mark, "按 " .. i))
  end
  yield(item(seg, "vset", "返回", "按 5"))
end

-- ===== 二次确认页 =====
local function yield_confirm(seg, what)
  yield(item(seg, "vset", "确认清理" .. what, "1 或 y 确认 · " .. "2 或 n 取消"))
  yield(item(seg, "vset", "取消", "按 2 或 n"))
end

-- ===== 剪贴板 =====
local function yield_clip_list(seg, more, is_admin)
  local page = core.read_page()
  local count = math.min(core.MAX_PAGE, page + core.STEP * more)
  local items = core.read_clip()
  if #items == 0 then
    yield(item(seg, "vclip", "剪贴板历史为空", "请先双击运行 clipboard-sync.bat"))
    return
  end
  local shown = 0
  for i = 1, #items do
    if shown >= count then break end
    shown = shown + 1
    -- [用户要求] 剪贴板候选后面不再显示「剪贴板 n/30」这类位置注释（太占地方，
    --   20% 固定格宽里注释会吃掉小半个格子）。管理列表（v1）只在第一项保留
    --   「显示 N · m 更多」这条操作性提示，也不再带位置前缀。
    local cmt = ""
    if is_admin and i == 1 and count < #items then
      cmt = "显示 " .. math.min(count, #items) .. " · m 更多"
    end
    yield(item(seg, "vclip", items[i], cmt))
  end
  if is_admin then
    if count < core.MAX_PAGE then
      yield(action(seg, "[m] 显示更多 +" .. core.STEP, 1))
    else
      yield(action(seg, "已达上限 " .. core.MAX_PAGE .. " 条", 1))
    end
    yield(action(seg, "[d] 删除模式", 2))
    yield(action(seg, "[x] 清空历史", 3))
    yield(action(seg, "[q] 返回 · 共 " .. #items .. " 条", 4))
  end
end

local function yield_clip_delete(seg)
  local items = core.read_clip()
  local total = #items
  if total == 0 then
    yield(item(seg, "vclip", "剪贴板历史为空", "[q] 返回设置"))
    return
  end
  -- [一屏 6 个] 这里**一次把全部条目都产出**（最多 MAX_PAGE 条），由 menu_filter 按
  -- 「页码 × 一屏 6 个」切窗口。原来是自己按 9 条一组切片（more 记组号），和现在的
  -- 加减号翻页（core.page_next）不是同一套 → 只能删到第 9 条；现在两边都用同一个窗口。
  for i = 1, total do
    local cmt = "第 " .. i .. " 条 · 按标签删除"
    if i == 1 then cmt = cmt .. " · +/- 翻页" end
    yield(item(seg, "vclip", items[i], cmt))
  end
end

-- ===== 常用语（原「收藏」，同一份 favorites.dict.yaml）=====
local function yield_fav_list(seg, query, is_admin)
  local favs = core.read_fav()
  local shown = 0
  for i = 1, #favs do
    if core.fav_match(favs[i], query) then
      shown = shown + 1
      if shown > core.MAX_PAGE then break end
      yield(item(seg, "vfav", favs[i].word, "常用语 " .. favs[i].key))
    end
  end
  if shown == 0 then
    if query == "" then
      yield(item(seg, "vfav", "还没有常用语", "在设置窗口里添加"))
    else
      yield(item(seg, "vfav", "没有匹配的常用语：" .. query, "常用语"))
    end
  end
  if is_admin then
    yield(action(seg, "[d] 删除模式", 1))
    yield(action(seg, "[x] 清空常用语", 2))
    yield(action(seg, "[q] 返回 · 共 " .. #favs .. " 条", 3))
  end
end

local function yield_fav_delete(seg)
  local favs = core.read_fav()
  local total = #favs
  if total == 0 then
    yield(item(seg, "vfav", "还没有常用语", "[q] 返回设置"))
    return
  end
  -- 同 yield_clip_delete：一次全产出，交给 menu_filter 的一屏 6 个窗口切片。
  for i = 1, total do
    local cmt = "第 " .. i .. " 条 · 按标签删除"
    if i == 1 then cmt = cmt .. " · +/- 翻页" end
    yield(item(seg, "vfav", favs[i].word, cmt))
  end
end

-- ===== 入口 =====
local function gen(input, seg, env)
  local ctx = env.engine.context
  local code = ctx.input
  -- 段文本必须等于整体编码，否则候选范围不合法，直接放弃
  if type(code) ~= "string" or input ~= code then return end
  if core.raw(ctx) then return end
  -- 英文 / ASCII 模式：不产出任何 v 功能候选
  local ok_ascii, ascii = pcall(function() return ctx:get_option("ascii_mode") end)
  if ok_ascii and ascii then return end

  local mode = core.mode_of(code)
  if mode == nil then return end

  if mode == "menu" then
    yield_menu(seg)
    return
  end

  if mode == "clip" then
    yield_clip_list(seg, 0, false)
    return
  end

  if mode == "fav" then
    yield_fav_list(seg, code:sub(5), false)
    return
  end

  if mode == "quick" then
    yield_quick(seg)
    return
  end

  -- mode == "set"
  if code == "vset" then
    yield_set(seg)
    return
  end
  if code == "vsetn" then
    yield_page_size(seg)
    return
  end
  if code == "vsetx" then
    yield_confirm(seg, "剪贴板历史缓存")
    return
  end

  local base, act, more = core.parse_sub(code)
  if not base then
    -- 未知的 vset* 编码：回到设置菜单，避免出现空白候选框
    yield_set(seg)
    return
  end

  if act == "x" then
    if base == "c" then yield_confirm(seg, "剪贴板历史缓存") else yield_confirm(seg, "全部常用语") end
    return
  end
  if act == "d" then
    if base == "c" then yield_clip_delete(seg) else yield_fav_delete(seg) end
    return
  end
  if base == "c" then
    yield_clip_list(seg, more, true)
  else
    yield_fav_list(seg, "", true)
  end
end

return gen
