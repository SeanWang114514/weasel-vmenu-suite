-- 词组优先（phrase_first）
-- 用户诉求（第二十四轮，原话）：
--   「在输入拼音的时候 首先输入的是词组 就让词组的词优先 单个文字放到后面较靠后」
-- 即：同一串拼音里，先把「词组」整体提到最前面，单字紧随其后、整体后移。
--
-- 实现：对**有限长度的候选窗口**做一次稳定划分（stable partition）——
--   ① 只看前 N 个候选（默认 100，可用 phrase_first/limit 调整），
--      因为候选是惰性产出的，无界扫描会把每次按键拖慢；第 1 页只有 36 个，
--      100 已经足够覆盖「词组排在很后面」的场景；
--   ② 命中「词组」的原顺序整体提前，未命中的保持原顺序紧随其后；
--   ③ 窗口之外的候选原样接在后面（不重复、不丢）。
--
-- 「词组」的判定（三条全中才算）：
--   * 码点数 ≥ 2（单字不参与）；
--   * 不含 ASCII 字母/数字（英文候选如 OK、3D 不参与，避免抢中文单字的位）；
--   * 至少 2 个汉字（CJK 基本区），从而排除标点串（——）与 emoji（emoji 在
--     simplifier@emoji 之后才产生，这里天然看不到，但仍然防御一下）。
--
-- 放置位置：必须排在 predict_filter / pin_cand_filter **之前** ——
--   预测词与用户置顶（收藏）要在重排之后仍然能压到第 1 位，否则会被词组顶走。
--
-- 本滤镜是 long_word_filter 的超集（它只提前 2 个、只到第 4 位），
-- 因此方案里把 long_word_filter 从引擎链上撤掉了，避免重复劳动与互相打架。

local M = {}

local core = require("vmenu_core")

local function is_phrase(cand)
  local text = cand.text
  if type(text) ~= "string" or text == "" then return false end
  -- 含英文字母或数字 → 不是中文词组
  if text:find("[%a%d]") then return false end
  local len = utf8.len(text)
  if not len or len < 2 then return false end
  -- 至少两个汉字：排除标点串、单个生僻符号等
  local cjk = 0
  for p in utf8.codes(text) do
    local cp = utf8.codepoint(text, p)
    if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) then
      cjk = cjk + 1
    end
  end
  return cjk >= 2
end

function M.init(env)
  local config = env.engine.schema.config
  local ns = (env.name_space or "phrase_first"):gsub("^*", "")
  -- 窗口大小：每次按键最多缓存多少个候选做重排
  M.limit = config:get_int(ns .. "/limit") or 100
  if M.limit < 9 then M.limit = 9 end
end

function M.func(input, env)
  local limit = M.limit or 100
  local head = {}
  for cand in input:iter() do
    head[#head + 1] = cand
    if #head >= limit then break end
  end

  -- 判定只做一次（每键最多 100 次扫描，避免重复 utf8 遍历拖慢打字）
  local flag = {}
  local phrase_count = 0
  for i = 1, #head do
    flag[i] = is_phrase(head[i])
    if flag[i] then phrase_count = phrase_count + 1 end
  end
  -- 窗口里一个词组都没有 = 无可重排，原样放行（绝大多数日常输入走这条快路径）
  if phrase_count == 0 then
    for i = 1, #head do yield(head[i]) end
    for cand in input:iter() do yield(cand) end
    return
  end

  -- 诊断：确实发生了「词组被提到单字前面」才记一条（避免每键都写日志）
  if phrase_count > 0 and not flag[1] then
    core.debug_log(("[vmenu] 词组前置：窗口 %d、词组 %d 个，原首位 <%s>"):format(
      #head, phrase_count, tostring(head[1].text)))
  end

  -- 稳定划分：词组原顺序在前，其余（单字 / 英文 / 标点）原顺序在后
  for i = 1, #head do
    if flag[i] then yield(head[i]) end
  end
  for i = 1, #head do
    if not flag[i] then yield(head[i]) end
  end
  -- 窗口之外的候选：Translation 的位置已经推进到这里，再 iter 一次即可续上
  for cand in input:iter() do yield(cand) end
end

return M
