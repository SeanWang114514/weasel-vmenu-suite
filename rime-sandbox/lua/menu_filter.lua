-- 当输入正好是 v（功能菜单）时，只保留菜单候选，
-- 丢弃 script_translator / melt_eng 产生的 于 与 vac van var 等候选，
-- 保证候选预览框里稳定显示菜单。
local function filter(input, env)
  local all = {}
  for cand in input:iter() do
    all[#all + 1] = cand
  end

  local code = ""
  if env and env.engine and env.engine.context then
    code = env.engine.context.input or ""
  end

  if code == "v" then
    local menu = {}
    for _, cand in ipairs(all) do
      if cand.type == "vmenu" then menu[#menu + 1] = cand end
    end
    if #menu > 0 then
      for _, cand in ipairs(menu) do yield(cand) end
      return
    end
  end

  for _, cand in ipairs(all) do yield(cand) end
end

return filter
