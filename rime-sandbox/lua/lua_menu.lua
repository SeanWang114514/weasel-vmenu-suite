-- input == "v" 时提供的功能菜单候选
-- 候选 type 固定为 vmenu，供 menu_filter 识别并压制普通中英文候选。
local function menu(input, env)
  if input ~= "v" then return end

  local function make(text, comment)
    local c = Candidate("vmenu", 0, #input, text, comment)
    c.quality = 1000000
    return c
  end

  yield(make("功能菜单（按 1 无效）", "提示"))
  yield(make("剪贴板", "按 2 进入"))
  yield(make("收藏", "按 3 进入"))
  yield(make("原符号输入", "按 4 进入"))
end

return menu
