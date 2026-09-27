--[[
en_gate —— 中文模式下的「英文候选」开关

功能：设置窗口里勾选/取消「中文模式下显示英文候选」后：
  * 开（默认，en_candidates=true）：什么都不做，原样放行（与不挂这个滤镜一致）。
  * 关（en_candidates=false）：把「纯英文候选」从候选列表里隐藏 —— 输入 hello
    不再出现 hello / OK 这类纯 ASCII 词条，中文词条完全不受影响。

判定「纯英文候选」的条件（同时满足才隐藏）：
  1. 输入是纯字母（a-z）—— v 菜单/符号/部件反查等模式不进来；
  2. 候选文本是英文词形状：字母开头，含字母/数字/空格/常见连接标点
     （. ' + - _ & / @ # ( )）—— 覆盖 Apple TV+、Apple TV 4K、AppleCare+ 这类；
     日期 2026-09-25（数字开头）、中英混排（含中文）不满足 → 不会被隐藏；
  3. 候选类型不是 v 功能菜单的类型（vmenu/vclip/vfav/vset/vact/vqi —— 剪贴板
     里存了一段英文时，v→2 的列表照常显示，不会被误杀）。

实现约束（本机 Weasel 0.17.4 的 librime-lua 实测）：
  * 循环内直接 yield 会让翻译对象提前失效，滤镜被放弃（fail-open）→ 开关失效。
    因此与 fuzzy_filter 同构：循环内只收集、循环结束后统一 yield。
  * 迭代器按 generic-for 语义显式调用 f(state, ctrl)，终止（nil/异常）均 pcall 兜住。
  * 异常一律保守保留候选，绝不影响正常输入。

开关文件：<用户目录>\candidate-settings.txt
  en_candidates=true|false（文件缺失/字段缺失 = true，即保持雾凇原生行为）
读取节流：最多每秒读一次（os.time 秒级），普通打字路径几乎无磁盘开销。

约束（与 fuzzy_filter 相同）：不启动进程、不 set_option、异常一律原样放行。
]]

local M = {}

local last_sec = -1
local cached = true            -- 默认开（= 保持原生行为）

local function user_dir()
  local ok, d = pcall(rime_api.get_user_data_dir)
  if ok and type(d) == "string" and d ~= "" then return d end
  return "."
end

local function read_switch()
  local now = os.time()
  if now ~= last_sec then
    last_sec = now
    local ok, f = pcall(io.open, user_dir() .. "/candidate-settings.txt", "r")
    if ok and f then
      local all = f:read("*a")
      f:close()
      if all then
        local flag = all:match("en_candidates%s*=%s*(%a+)")
        if flag then cached = (flag == "true") end
      end
    end
  end
  return cached
end

-- 英文词形状（字母开头；字母 / 数字 / 空格 / 常见连接标点）
local function looks_english(t)
  return type(t) == "string" and t:match("^[%a][%a%d %. '%+%-%_&%/%@%#%(%)]*$") ~= nil
end

-- v 功能菜单产的候选（类型名都以 v 开头）：永远不隐藏
local function is_vmenu_type(ty)
  return type(ty) == "string" and #ty > 0 and ty:byte(1) == 118 -- 'v'
end

function M.func(input, env)
  local okr, on = pcall(read_switch)
  if not okr then on = true end
  if on ~= false then
    for cand in input:iter() do yield(cand) end   -- 开：零开销原样放行
    return
  end

  local raw = ""
  local oki, inp = pcall(function() return env.engine.context.input end)
  if oki and type(inp) == "string" then raw = inp end
  raw = raw:lower()
  if #raw == 0 or raw:match("^[a-z]+$") == nil then
    for cand in input:iter() do yield(cand) end   -- 非纯字母输入：整段放行
    return
  end

  -- 关：收集模式（见头部「实现约束」）
  local okIt, it, istate = pcall(function() return input:iter() end)
  if not okIt or type(it) ~= "function" then
    for cand in input:iter() do yield(cand) end
    return
  end
  local keep = {}
  local ctrl = nil
  while true do
    local okn, cand = pcall(it, istate, ctrl)
    if not okn or cand == nil then break end
    ctrl = cand
    local okc, drop = pcall(function()
      return (not is_vmenu_type(cand.type)) and looks_english(cand.text)
    end)
    if okc and drop then
      -- 纯英文候选：隐藏（不进 keep）
    else
      keep[#keep + 1] = cand      -- 判定出错时保守保留
    end
  end
  for i = 1, #keep do yield(keep[i]) end
end

return M
