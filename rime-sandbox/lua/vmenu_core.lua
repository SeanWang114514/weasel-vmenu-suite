-- v 功能菜单：共享核心（设置 / 剪贴板 / 收藏 / 原符号模式）
-- 设计原则：
--   1) 绝不在 Rime 输入线程里启动子进程（禁用 io.popen / os.execute），这是之前 v2 卡死的根因；
--   2) 普通打字路径完全不读写文件，只有进入 v 相关模式才访问磁盘；
--   3) 所有对外函数都用 pcall 兜底，异常时退化为「不处理」，绝不影响正常输入。
local M = {}

M.DEFAULT_PAGE = 20   -- 默认显示条数
M.MIN_PAGE = 20       -- 下限
M.MAX_PAGE = 50       -- 上限（超出丢弃最旧的）
M.STEP = 10           -- 每次「显示更多」+10
M.WINDOW = 9          -- 管理/删除模式每屏条数，与 menu/page_size 保持一致

-- [防误触] 两次按键之间的最小间隔（毫秒）。低于这个间隔的连续按键会被吞掉。
-- 推荐值 30ms：人类最快打字速度 ≈ 200 WPM ≈ 300ms/键，30ms 远低于人类下限，
-- 但能拦住键盘抖动、系统重复、手滑连击等误输入。
M.MISINPUT_DEFAULT = 30    -- 推荐值（ms）
M.MISINPUT_MIN = 10        -- 允许的最小值（再小就没意义了）
M.MISINPUT_MAX = 200       -- 允许的最大值（再大会影响正常打字）

local raw_flag = false

local function user_dir()
  local ok, d = pcall(rime_api.get_user_data_dir)
  if ok and type(d) == "string" and d ~= "" then return d end
  return "."
end

function M.clip_path() return user_dir() .. "/clipboard-cache.txt" end
function M.fav_path() return user_dir() .. "/cn_dicts/favorites.dict.yaml" end
function M.set_path() return user_dir() .. "/vmenu-settings.txt" end
function M.gui_flag_path() return user_dir() .. "/open-settings.flag" end

-- 【诊断】librime 的 Lua 里 print 不会进 rime 日志（实测：日志里一个字都没有），
-- 所以卡顿诊断统一写到用户目录下的 vmenu-debug.log，便于用文件计数取证。
-- 正式使用时可把 DEBUG_LOG 置 false 彻底关掉。
M.DEBUG_LOG = true
-- 【诊断·按需】把「每次 filter 运行时的本页候选表」也写日志（menu_filter 里用）。
-- 默认 false：那是**每个按键一次文件写入**，排查「画面显示的顺序 / 选中的候选对不上」
-- 这类问题时才临时改 true（配合 tools\verify-grid-digit.ps1）。
M.DEBUG_CAND = false
local function debug_log(msg)
  if not M.DEBUG_LOG then return end
  local f = io.open(user_dir() .. "/vmenu-debug.log", "a")
  if f then
    f:write(os.date("%H:%M:%S "), msg, "\n")
    f:close()
  end
end
M.debug_log = debug_log

-- ---------------------------------------------------------------------------
-- 【卡顿修复·设置读盘】vmenu-settings.txt 的 1 秒 TTL 缓存
-- 用户报障（原话）：「现在在输入的时候有轻微的卡顿」。
-- 根因：menu_processor 每个按键都要问一次防误触开关（misinput_protect=true 时
--   原来还问两遍 —— read_misinput 被调用两次），而 read_misinput → _read_settings
--   每次都是真实 io.open + 逐行解析设置文件。实测本机打开这个文件 ≈1~2ms，
--   每个按键 2 次 = 打字热路径上最大的固定磁盘开销（0.2.7 给收藏读盘加了 TTL，
--   但 0.2.20 加防误触时引入的这两次设置读盘漏掉了，违反本文件开头
--   「普通打字路径完全不读写文件」的设计原则）。
-- 修法：与 fuzzy_filter / en_gate 同构 —— os.time() 秒级节流，同一秒内复用，
--   每秒最多读 1 次盘；设置由 GUI（外部进程）写入，最迟 1 秒生效（无感）；
--   Lua 自己的写函数（write_page / write_misinput）写成功后立刻失效缓存。
-- 读盘 >1ms 时记一条日志（限速：只有真的读盘才可能写），作为卡顿取证通道。
-- ---------------------------------------------------------------------------
local _set_cache, _set_at = nil, -1

local function settings_invalidate()
  _set_cache, _set_at = nil, -1
end
M.settings_invalidate = settings_invalidate

local function settings_cached()
  local now = os.time()
  if _set_cache ~= nil and now == _set_at then return _set_cache end
  local t0 = os.clock()
  _set_cache = M._read_settings()
  _set_at = now
  local dt = (os.clock() - t0) * 1000
  if dt > 1 then debug_log(("[vmenu] 设置读盘 %.2fms"):format(dt)) end
  return _set_cache
end

-- 请求打开「可视化设置界面」。
-- 这里只写一个标记文件，绝不在这里启动子进程：在 Rime 输入线程里创建进程
-- （io.popen / os.execute）正是之前 v2 卡死的根因。
-- 后台守护脚本 vmenu-watcher.ps1 看到标记文件后删掉它并打开设置窗口。
function M.request_gui()
  local f = io.open(M.gui_flag_path(), "w")
  if not f then return false end
  f:write(tostring(os.time()), "\n")
  f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- 原符号模式（v → 4）
-- 模块内标记 + context option 双写：即使 librime-lua 为每个组件建立独立 Lua 环境，
-- 处理器/翻译器/滤镜三方也一定能读到同一个值。
-- ---------------------------------------------------------------------------
function M.set_raw(ctx, v)
  raw_flag = v and true or false
  if ctx then
    -- ⚠️ 值没变就**不要**写 option：set_option 会让 rime 把候选整份重翻译，
    --    每个按键都无条件写一遍是「打字卡顿」的来源（日志里每个键都刷 updated option）。
    local ok, cur = pcall(function() return ctx:get_option("vraw_mode") end)
    if not (ok and (cur and true or false) == raw_flag) then
      pcall(function() ctx:set_option("vraw_mode", raw_flag) end)
    end
  end
end

function M.raw(ctx)
  if raw_flag then return true end
  if ctx then
    local ok, v = pcall(function() return ctx:get_option("vraw_mode") end)
    if ok and v then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- 模式判定
-- ---------------------------------------------------------------------------
-- 返回 "menu" | "clip" | "fav" | "set" | nil
-- ===== 候选窗口「单行 / 九宫格」状态 =====
-- 默认单行：只放 GRID_COLS 个候选（正好一行，由 menu_filter 限制个数）；
-- 按 ↓ 展开成 GRID_COLS × GRID_ROWS（4 行 × 9 列，靠 weasel 主题 max_width 自动换行）；
-- 选中项在第一行时再按 ↑ 收回去。这里只存状态，真正决定候选个数的是 menu_filter。
M.GRID_COLS = 9
M.GRID_ROWS = 4
M.GRID_OPTION = "vmenu_grid"   -- 状态必须放在 context option 里！
-- [v 一行 4 个] v 功能菜单自己的列数 / 展开行数：
--   用户要求「v 的功能…一行显示 4 个，同时参考正常输入的下键拓展按键进行拓展显示」。
--   收起 = 一行 4 个，按 ↓ 展开 = 4 行 × 4 列 = 16 个。
--   服务端会把这个列数用 ctx.grid_cols 下发给客户端（WeaselUI/HorizontalLayout.cpp 按它排版）。
M.V_COLS = 4
M.V_ROWS = 4
-- [剪贴板 / 常用语：一行 2 个、默认 3 行] 用户要求：
--   剪贴板与常用语「一行 2 个、默认显示 3 行，用正常候选词的逻辑进行选择，拓展栏默认展开」，
--   并特别补充「按上键不要收起，默认就是展开态」。
--   * 因此这两种列表**没有收起态**：一屏固定 2 列 × 3 行 = 6 个；
--   * ↑ 在第一行时不再收起（menu_processor.lua 里对这些编码直接吞掉该键）；
--   * 序号照普通打字来（服务端 ctx.grid_2d=1）：只在高亮那一行画 1 / 2，
--     数字键选的是「高亮那一行」的第 N 个，而不是整屏第 N 个；
--   * 加减号按一屏 6 个翻页。
M.LIST_COLS = 2
M.LIST_ROWS = 3
M.LIST_LIMIT = M.LIST_COLS * M.LIST_ROWS   -- 6

-- 输入码是不是 v 功能菜单（v / vclip / vqi / vfav / vset…）
function M.is_v_code(code)
  return M.mode_of(code) ~= nil
end

-- 「列表型」v 功能：剪贴板 / 常用语 / 管理列表。
-- 只有这些才需要按一屏 4 / 16 个切片、才需要加减号翻页、序号才按「行 × 列」算
-- （数字键在列表里是二维的：第 2 行的 1 选的是本行第 1 个）。
-- 静态菜单（v 主菜单 5 项、v3 快捷输入 7 项）条目本来就少，全部放出来，
-- 序号按 1..N 顺序编号 —— 数字键在菜单里就是顺序选（见 menu_processor.lua 的 cur=="v" 段）。
function M.is_list_code(code)
  local m = M.mode_of(code)
  if m == "clip" or m == "fav" then return true end
  if m == "set" then
    local base = M.parse_sub(code)
    return base == "c" or base == "f"
  end
  return false
end

-- 服务端也需要知道「这次是不是列表型 v 功能」，才能决定两件事：
--   1) 序号按「行 × 列」算（列表）还是按 1..N 顺序算（静态菜单）；
--   2) 数字键要不要被服务端接管（静态菜单永远交给 Lua 顺序选，避免按第 2 行的 1 选错）。
-- ★ 实现方式：C++ 侧（RimeWithWeasel.cpp 的 _VMenuListCode）按同一套前缀自己判断，
--   不走 option —— 试过在 lua_filter 里 ctx:set_option("vmenu_list", …)，结果
--   **服务端当场栈溢出崩溃**（0xc00000fd）：set_option 会通知引擎重跑候选管线，
--   管线又进过滤器、又 set_option … 无限递归。filter 里绝不能改 option。
--   所以这里只保留 is_list_code 供 Lua 自己用（menu_filter / menu_processor），
--   前缀表必须和 C++ 侧保持一致：vclip / vfav / vsetc / vsetf。

-- 注意：lua_processor 与 lua_filter 各自 require 一份本模块（模块级变量不共享），
-- 所以「是否展开」只能通过 ctx 的 option 传递（vraw_mode 也是这么做的）。
-- 第二个参数是「输入码」：给了且是 v 功能菜单时按 4 / 16 算，否则（普通打字）按 9 / 36 算。
-- 省略第二个参数 = 普通打字的旧行为，老的调用点不受影响。
function M.grid_limit(ctx, code)
  -- [一行 2 个] 剪贴板 / 常用语（列表型）：固定 6 个，**不看展开状态** —— 它们永远是展开态。
  if code ~= nil and M.is_list_code(code) then
    return M.LIST_LIMIT
  end
  local ok, open = pcall(function() return ctx:get_option(M.GRID_OPTION) end)
  local opened = (ok and open) and true or false
  if code ~= nil and M.is_v_code(code) then
    if opened then return M.V_COLS * M.V_ROWS end
    return M.V_COLS
  end
  if opened then return M.GRID_COLS * M.GRID_ROWS end
  return M.GRID_COLS
end

local function grid_open(ctx)
  local ok, v = pcall(function() return ctx:get_option(M.GRID_OPTION) end)
  return (ok and v) and true or false
end

local function grid_set(ctx, open)
  open = open and true or false
  -- 同样的道理：状态没变就不写 option（↓/↑ 收起后每个按键都会走到这里）
  if grid_open(ctx) == open then return end
  pcall(function() ctx:set_option(M.GRID_OPTION, open) end)
end

-- vmenu_grid 是「会话级」选项，一旦展开过就会一直开着；新一次输入开始时必须强制复位，
-- 否则普通打字也会按 36 个候选排版，表现为候选窗口换行成 4 行（用户反馈的问题）。
function M.grid_reset(ctx)
  grid_set(ctx, false)
end

-- [一行 2 个 / 默认展开] 剪贴板 / 常用语：进入列表就把「展开」打开，并且在列表里一直保持开着。
-- 为什么必须开着：服务端补丁里「数字键按高亮行选词」「↓↑←→ 逐行移动」「+/- 翻页」三件事
-- 都以 vmenu_grid 为门槛（RimeWithWeasel.cpp），关了这些键就退回 librime 原生行为，
-- 而原生的「本页第 N 个」与屏幕上画的 1/2 序号在高亮不在第一行时会对不上。
-- 只有真的需要写 option 时才写（状态没变就不写），避免每个按键都让 rime 重翻译。
function M.grid_lock(ctx)
  if grid_open(ctx) then return end
  pcall(function() ctx:set_option(M.GRID_OPTION, true) end)
end

-- ===== 候选窗口「下翻」页码（+ 号触发）=====
-- 用户要求：「还有保留 + 号下翻选择预选词的功能」。
-- 收起态一行只放 9 个候选（menu_filter 限个数），所以第 10 个以后本来够不着；
-- 按 + 就把可见窗口整体往后挪 9 个（第 2 页 = 第 10-18 个候选），数字仍然是 1-9，
-- 与「序号按当前可见行重新编号」的标签槽实现天然配套。
-- ctx 的 option 只能是布尔值，所以用 GRID_PAGES 个开关表示 0..GRID_PAGES-1 页。
M.PAGE_OPTION = "vmenu_page"
M.GRID_PAGES = 16  -- [按行滚动] 4=整页翻(36)，16=按行翻(9)：最多 144 个候选 / 9 = 16 屏

local function page_set(ctx, n)
  -- ⚠️ 关键性能点：只在**真的换页**时写 option。旧写法无条件写 4 个开关，
  --    而 page_reset 在每个按键上都会被调用 → 每个键都让 rime 重翻译一整份候选，
  --    表现就是「打字卡顿」（实测：按键时日志里成片刷 updated option: vmenu_page_*）。
  if M.page_get(ctx) == n then return end
  -- ★ 写入顺序也关键：**先把目标页置 true，再清掉其余页**。
  --   反过来（i 从 0 顺着写）会出现「page_0 已清、page_n 还没置」的瞬间，
  --   这一瞬间 rime 就会重翻译一次，filter 读到的页码是 0 →
  --   画面先回到第 1 页再跳到目标页，用户看到的就是**翻页时闪一下/卡一下**。
  --   实测日志：同一次按 = 出现「本页 page=0」紧跟「本页 page=2」两条。
  pcall(function() ctx:set_option(M.PAGE_OPTION .. "_" .. n, true) end)
  for i = 0, M.GRID_PAGES - 1 do
    if i ~= n then
      local ok, cur = pcall(function() return ctx:get_option(M.PAGE_OPTION .. "_" .. i) end)
      if ok and cur then
        pcall(function() ctx:set_option(M.PAGE_OPTION .. "_" .. i, false) end)
      end
    end
  end
end

function M.page_get(ctx)
  for i = 0, M.GRID_PAGES - 1 do
    local ok, v = pcall(function() return ctx:get_option(M.PAGE_OPTION .. "_" .. i) end)
    if ok and v then return i end
  end
  return 0
end

function M.page_set(ctx, n) page_set(ctx, n) end

--- 翻到下一页（到最后一页后回到第 0 页）
function M.page_next(ctx)
  local n = (M.page_get(ctx) + 1) % M.GRID_PAGES
  page_set(ctx, n)
  return n
end

--- 翻回上一页：**不环绕**（第 0 页再按就停在 0）。
--- 环绕会很怪：第 0 页按 - 跳到第 15 页，而候选常常不足 135 条 →
--- menu_filter 的 start>=k 又把它拉回第 0 页显示，用户看到的就是「按了没反应」。
function M.page_prev(ctx)
  local n = M.page_get(ctx)
  if n > 0 then
    page_set(ctx, n - 1)
    return n - 1
  end
  return 0
end

function M.page_reset(ctx)
  page_set(ctx, 0)
end

-- 方向键：返回 true 表示已被我们处理（要吞掉，不能让原生导航器再动一次）
--   ↓：收起时展开；已展开时往下跳一行（+9）
--   ↑：在第一行时收回成单行；否则往上跳一行（-9）
--   ←/→：在同一行内左右移动
-- 方向键：本机 librime-lua **没有**「只移动高亮」的 API（实测探针结果）：
--   ctx.select           = function —— 但它不是「移动高亮」，而是「选中并上屏」
--   ctx.select_candidate / set_selected_candidate_index / highlight / move_selection
--   / menu / get_menu / selected_candidate_index 全部 = nil（不存在）
-- 所以这里绝不能再调用 ctx.select（否则第二次按 ↓ 就把候选打出去了）。
-- 现在的分工：**Lua 只负责「展开 / 收起」与「+ 下翻页码」**；真正的「移动高亮」
-- 由自编 Weasel 补丁做（RimeWithWeasel.cpp 把方向键转成 highlight_candidate_on_current_page，
-- 见仓库 docs/GRID-CANDIDATE-DLL.md）。补丁处理掉的按键不会落到这里；落到这里只有三种情况：
-- ① 还没展开（↓ 要展开）② 补丁越界放行（第一行按 ↑ 要收起）③ 跑的是原版 server（没有补丁）。
function M.grid_key(ctx, repr)
  local is_arrow = (repr == "Down" or repr == "Up" or repr == "Left" or repr == "Right")
  if not is_arrow then
    -- 任何其它键（继续打字、上屏、选词）都收回成单行
    grid_set(ctx, false)
    return false
  end
  local ok_menu, has = pcall(function() return ctx:has_menu() end)
  if not (ok_menu and has) then return false end
  if repr == "Down" then
    if not grid_open(ctx) then
      -- 【第二十七轮 / 关闭后重开必回第 1 页】用户报障（原话）：
      --   「翻到第二页 → 按上键收起 → 再次打开，仍显示关闭前那一页；
      --     关闭后重新打开无论如何显示默认第一页」。
      -- 根因：页码 vmenu_page_* 是会话级 option，收起动作只写 vmenu_grid、不清页码，
      -- 重开后 menu_filter.window_of 仍按 old page * lim 取窗口起点 → 停在关闭前那一页。
      -- 修法：在**展开的瞬间**无条件复位页码 —— 不管它怎么残留，重开必从第 1 屏开始。
      -- 页码复位放在 grid_set **之前**：中间帧 = (收起, 第1页) = 正常单行，先写 grid
      -- 则会先画出 (展开, 第2页) 这个怪画面。page_set 有「值没变不写 option」守卫，
      -- 页码本来就是 0 时只多一次 get_option、零额外重翻译；pcall 隔离保证展开必完成。
      debug_log(("[vmenu] 展开网格：复位前 page=%d"):format(M.page_get(ctx)))
      pcall(M.page_reset, ctx)
      grid_set(ctx, true)     -- 第一次 ↓：展开成 4 行 × 9 列
      return true
    end
    -- 已展开还能收到 ↓ = Weasel 侧补丁判定「已在最后一行、再按 ↓ 越界」才放行到这里
    -- → 按「继续翻页」处理：整屏翻 36 个，新一屏的第 1 行 = 原来的第 5 行（以此类推）。
    -- 「光标停在翻页前所在列的最上方」由补丁在放行后把高亮放回**同一列**（col = 高亮 % 9）。
    M.page_next(ctx)
    return true
  end
  if repr == "Up" then
    if grid_open(ctx) then
      -- ↑ 只在「选中项位于第一行」时折叠：Weasel 侧补丁发现 -9 越界才会把按键放行到这里，
      -- 越界正说明当前在第一行，所以这里折叠是正确的；在下面几行时补丁会先处理掉按键。
      -- 【第二十七轮】收起时把页码一并拉回第 1 页：否则残留 page=1 时，收起后的单行
      -- 会显示第 10-18 个候选（关了栏反而更靠后，同样违背「关闭 = 回到默认」）；
      -- 页码在写 grid **之前**复位，中间帧 = (展开, 第1页) = 正常画面，
      -- 反过来则会先画出 (收起, 第2页)。pcall 隔离：页码复位失败也必须完成收起。
      debug_log(("[vmenu] 收起网格：复位前 page=%d"):format(M.page_get(ctx)))
      pcall(M.page_reset, ctx)
      grid_set(ctx, false)    -- ↑：收回单行
      return true
    end
    return false
  end
  return false                -- ← / → 也由 Weasel 补丁做行内移动；落到这里说明没补丁，放行给原生导航器
end
function M.mode_of(code)
  if type(code) ~= "string" or code == "" then return nil end
  if code == "v" then return "menu" end
  if code:sub(1, 5) == "vclip" then return "clip" end
  if code:sub(1, 4) == "vfav" then return "fav" end
  if code:sub(1, 3) == "vqi" then return "quick" end
  if code:sub(1, 4) == "vset" then return "set" end
  return nil
end

-- 解析 vsetc / vsetf 系列：返回 base("c"/"f"), act(""/"d"/"x"), more(m 的个数)
function M.parse_sub(code)
  if type(code) ~= "string" then return nil end
  local base, act, ms = code:match("^vset([cf])([dx]?)(m*)$")
  if not base then return nil end
  return base, act, #ms
end

-- 每个模式下「必须保留」的候选类型；vact 为操作行，任何 v 模式下都保留
function M.want_type(code)
  local m = M.mode_of(code)
  if m == "menu" then return "vmenu" end
  if m == "clip" then return "vclip" end
  if m == "fav" then return "vfav" end
  if m == "quick" then return "vqi" end
  if m == "set" then
    local base, act = M.parse_sub(code)
    if base == "c" and act ~= "x" then return "vclip" end
    if base == "f" and act ~= "x" then return "vfav" end
    return "vset"
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- 设置读写
-- ---------------------------------------------------------------------------
function M.read_page()
  local page = M.DEFAULT_PAGE
  local f = io.open(M.set_path(), "r")
  if not f then return page end
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(%d+)")
    if k == "clip_page" then
      local n = tonumber(v)
      if n and n >= M.MIN_PAGE and n <= M.MAX_PAGE then page = n end
    end
  end
  f:close()
  return page
end

function M.write_page(n)
  n = tonumber(n) or M.DEFAULT_PAGE
  if n < M.MIN_PAGE then n = M.MIN_PAGE end
  if n > M.MAX_PAGE then n = M.MAX_PAGE end
  -- [防误触] 读出现有设置，保留其它字段
  local old = M._read_settings()
  local path = M.set_path()
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write("# v 功能菜单设置\n")
  f:write("clip_page=" .. tostring(n) .. "\n")
  f:write("misinput_protect=" .. (old.misinput_protect or "true") .. "\n")
  f:write("misinput_interval=" .. tostring(old.misinput_interval or M.MISINPUT_DEFAULT) .. "\n")
  f:close()
  os.remove(path)
  local ok = os.rename(tmp, path) and true or false
  if ok then settings_invalidate() end  -- 自己刚写完：缓存立刻失效，读到新值
  return ok
end

-- [防误触] 读取所有设置（内部辅助）
function M._read_settings()
  local s = { clip_page = M.DEFAULT_PAGE, misinput_protect = true, misinput_interval = M.MISINPUT_DEFAULT }
  local f = io.open(M.set_path(), "r")
  if not f then return s end
  for line in f:lines() do
    local k1, v1 = line:match("^%s*([%w_]+)%s*=%s*(%d+)")
    if k1 == "clip_page" then
      local n = tonumber(v1)
      if n and n >= M.MIN_PAGE and n <= M.MAX_PAGE then s.clip_page = n end
    elseif k1 == "misinput_interval" then
      local n = tonumber(v1)
      if n and n >= M.MISINPUT_MIN and n <= M.MISINPUT_MAX then s.misinput_interval = n end
    end
    local k2, v2 = line:match("^%s*([%w_]+)%s*=%s*(%a+)")
    if k2 == "misinput_protect" then
      s.misinput_protect = (v2 == "true")
    end
  end
  f:close()
  return s
end

-- [防误触] 读取防误触开关和间隔（供 menu_processor 调用）
-- 返回两个值：enabled (bool), interval_ms (number)
-- ★ 这是**每个按键**都会走的热路径：走 1 秒 TTL 缓存（settings_cached），
--   不再每个键 io.open 设置文件 —— 这正是「输入轻微卡顿」的来源。
function M.read_misinput()
  local s = settings_cached()
  return s.misinput_protect, s.misinput_interval
end

-- [防误触] 写入防误触设置（供设置面板调用）
function M.write_misinput(enabled, interval)
  interval = tonumber(interval) or M.MISINPUT_DEFAULT
  if interval < M.MISINPUT_MIN then interval = M.MISINPUT_MIN end
  if interval > M.MISINPUT_MAX then interval = M.MISINPUT_MAX end
  local old = M._read_settings()
  local path = M.set_path()
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write("# v 功能菜单设置\n")
  f:write("clip_page=" .. tostring(old.clip_page or M.DEFAULT_PAGE) .. "\n")
  f:write("misinput_protect=" .. (enabled and "true" or "false") .. "\n")
  f:write("misinput_interval=" .. tostring(interval) .. "\n")
  f:close()
  os.remove(path)
  local ok = os.rename(tmp, path) and true or false
  if ok then settings_invalidate() end  -- 自己刚写完：缓存立刻失效，读到新值
  return ok
end

-- ---------------------------------------------------------------------------
-- 剪贴板历史（由独立的 clipboard-sync.bat 后台写入，Lua 只读写文本文件）
-- ---------------------------------------------------------------------------
function M.read_clip()
  local list = {}
  local f = io.open(M.clip_path(), "r")
  if not f then return list end
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then list[#list + 1] = line end
    if #list >= M.MAX_PAGE then break end
  end
  f:close()
  return list
end

function M.write_clip(list)
  local path = M.clip_path()
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  if list then
    for i = 1, #list do
      if i > M.MAX_PAGE then break end
      f:write(list[i], "\n")
    end
  end
  f:close()
  os.remove(path)
  return os.rename(tmp, path) and true or false
end

-- ---------------------------------------------------------------------------
-- 收藏（cn_dicts/favorites.dict.yaml）：正文在 "..." 之后，格式 内容<Tab>键<Tab>词频
-- ---------------------------------------------------------------------------
local FAV_HEADER = "# Rime dictionary\n"
  .. "# encoding: utf-8\n"
  .. "---\n"
  .. "name: favorites\n"
  .. "version: \"2026-09-11\"\n"
  .. "sort: by_weight\n"
  .. "...\n"

function M.read_fav()
  local list = {}
  local f = io.open(M.fav_path(), "r")
  if not f then return list end
  local body = false
  for line in f:lines() do
    if body then
      local word, key = line:match("^([^\t#][^\t]*)\t([^\t]+)")
      if word and key then
        list[#list + 1] = { word = word, key = key }
      end
    elseif line:match("^%.%.%.") then
      body = true
    end
  end
  f:close()
  return list
end

function M.write_fav(list)
  local path = M.fav_path()
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(FAV_HEADER)
  if list then
    for i = 1, #list do
      local it = list[i]
      if it and it.word and it.word ~= "" and it.key and it.key ~= "" then
        f:write(it.word, "\t", it.key, "\t100000\n")
      end
    end
  end
  f:close()
  os.remove(path)
  local ok = os.rename(tmp, path) and true or false
  if ok then M.fav_invalidate() end  -- 刚写完，缓存立刻失效：新收藏马上能命中
  return ok
end

-- ---------------------------------------------------------------------------
-- 【卡顿修复】收藏列表 TTL 缓存
-- 问题：fav_hit / fav_exact / digit_prefix 都在**按键热路径**上，而它们原来每次
--       都调 M.read_fav() —— 也就是每个键都 io.open + 逐行解析 favorites.dict.yaml。
--       在输入线程里做磁盘 I/O 就是「打字卡顿」的来源（本文件开头的设计原则第 2 条
--       本来就写着「普通打字路径完全不读写文件」，这里把它真正落实）。
-- 做法：热路径改走 fav_cached()，同一份列表在 FAV_TTL 秒内复用；任何写入立刻失效。
--       收藏是「用户手动维护」的低频数据，最多 3 秒的旧值对体验没有影响；
--       而 v 菜单列表这类需要绝对最新的地方仍然直接用 M.read_fav()（保持原语义）。
-- ---------------------------------------------------------------------------
local FAV_TTL = 3          -- 秒：缓存有效期
local _fav_cache = nil
local _fav_at = 0
local _fav_reads = 0       -- 真实读盘次数（诊断用，见 M.fav_reads）

local function fav_cached()
  local now = os.time()
  if _fav_cache and (now - _fav_at) < FAV_TTL then return _fav_cache end
  local t0 = os.clock()
  _fav_cache = M.read_fav()
  _fav_at = now
  _fav_reads = _fav_reads + 1
  debug_log(("[vmenu] 收藏读盘 #%d  %.2fms  %d 条"):format(_fav_reads,
        (os.clock() - t0) * 1000, #_fav_cache))
  return _fav_cache
end

function M.fav_invalidate()
  _fav_cache = nil
  _fav_at = 0
end

function M.fav_reads() return _fav_reads end


-- 正常打字时的收藏命中：输入满 3 个字符后，只要输入的 3 个字符是某条收藏
-- 编码的开头（编码本身不足 3 位的不用这种方式，靠 v 菜单取用），就命中它。
-- 只在输入 >= 3 个字符时查找，2 个字符以内不读文件，保证打字速度。
function M.fav_hit(code)
  if type(code) ~= "string" or #code < 3 then return nil end
  local key = code:lower()
  local list = fav_cached()   -- 【卡顿修复】热路径走缓存，不再每个键读盘
  for i = 1, #list do
    local k = (list[i].key or ""):lower()
    local w = list[i].word or ""
    if w ~= "" and (k == key or k:sub(1, #key) == key) then
      return { word = w, key = list[i].key }
    end
  end
  return nil
end

-- 纯数字收藏编码（如 131）在正常打字时有一个先天问题：
-- 中文模式下数字是「选字键」，根本进不了编码。所以由 menu_processor 在
-- 输入为空 / 全是数字时接管：只要「已输入的数字 + 刚按的数字」还是某条
-- 数字编码的开头，就把这个数字并进编码，而不是交给选字逻辑。
function M.digit_prefix(s)
  if type(s) ~= "string" or s == "" then return false end
  if not s:match("^%d+$") then return false end
  local list = fav_cached()   -- 【卡顿修复】同上：数字编码热路径也不读盘
  for i = 1, #list do
    local k = list[i].key or ""
    if #s <= #k and k:match("^%d+$") and k:sub(1, #s) == s then return true end
  end
  return false
end

-- 收藏编码「原样打完」才算精确命中：只有当输入和某条收藏编码完全相同
-- （不分大小写）时返回，用于「打完编码 + 回车 = 直接调用收藏内容」。
-- 与 fav_hit 的区别：fav_hit 是「前 3 位就算命中」（用于候选第 2 位预览），
-- fav_exact 要求整条编码一字不差，避免回车抢走正常的原始输入。
function M.fav_exact(code)
  if type(code) ~= "string" or code == "" then return nil end
  local key = code:lower()
  local list = fav_cached()   -- 【卡顿修复】同上：回车判定也不读盘
  for i = 1, #list do
    local k = (list[i].key or ""):lower()
    local w = list[i].word or ""
    if w ~= "" and k == key then
      return { word = w, key = list[i].key }
    end
  end
  return nil
end

function M.fav_match(it, query)
  if query == nil or query == "" then return true end
  query = query:lower()
  local k = (it.key or ""):lower()
  local w = (it.word or ""):lower()
  if k:sub(1, #query) == query then return true end
  if w:find(query, 1, true) == 1 then return true end
  return false
end

return M
