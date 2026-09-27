-- v2：剪贴板候选
-- 隔离设计：只读取由独立后台脚本写入的缓存文件，
-- 绝不在 Rime 输入线程里启动 PowerShell 或任何子进程（这是之前卡死的原因）。
local MAX_ITEMS = 30

local function read_lines(path)
  local list = {}
  local f = io.open(path, "r")
  if not f then return list end
  local n = 0
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      n = n + 1
      if n > MAX_ITEMS then break end
      list[#list + 1] = line
    end
  end
  f:close()
  return list
end

local function clipboard(input, env)
  if input ~= "v2" then return end

  local dir = rime_api.get_user_data_dir()
  local lines = read_lines(dir .. "/clipboard-cache.txt")

  if #lines == 0 then
    yield(Candidate("vclip", 0, #input, "剪贴板为空（请先运行 clipboard-sync.bat）", "剪贴板"))
    return
  end

  for _, line in ipairs(lines) do
    yield(Candidate("vclip", 0, #input, line, "剪贴板"))
  end
end

return clipboard
