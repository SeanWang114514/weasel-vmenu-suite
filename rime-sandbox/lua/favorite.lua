-- v3：收藏候选
-- 收藏内容由词库管理器写入 cn_dicts/favorites.dict.yaml，格式：完整内容<Tab>前三个字符
local MAX_ITEMS = 30

local function favorite(input, env)
  if input:sub(1, 2) ~= "v3" then return end

  local query = input:sub(3):lower()
  local dir = rime_api.get_user_data_dir()
  local f = io.open(dir .. "/cn_dicts/favorites.dict.yaml", "r")
  if not f then
    yield(Candidate("vfav", 0, #input, "还没有收藏（请用词库管理器添加）", "收藏"))
    return
  end

  local shown, matched = 0, 0
  for line in f:lines() do
    local word, key = line:match("^([^\t#][^\t]*)\t([^\t]+)")
    if word and key then
      if query == "" or key:lower():sub(1, #query) == query then
        matched = matched + 1
        if shown < MAX_ITEMS then
          shown = shown + 1
          yield(Candidate("vfav", 0, #input, word, "收藏 " .. key))
        end
      end
    end
  end
  f:close()

  if matched == 0 then
    yield(Candidate("vfav", 0, #input, "没有匹配的收藏：" .. query, "收藏"))
  end
end

return favorite
