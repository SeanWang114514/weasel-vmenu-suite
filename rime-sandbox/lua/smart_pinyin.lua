-- smart_pinyin —— 共享拼音音节校验（smart_punct / smart_punct_filter 共用）
local M = {}

local PY = {}
local py_list = [[
a o e ai ei ao ou an en ang eng er
ba bo bai bei bao ban ben bang beng bi bie biao bin bing bu
pa po pai pei pao pou pan pen pang peng pi pie piao pin ping pu
ma mo me mai mei mao mou man men mang meng mi mie miao miu min ming mu
fa fo fei fou fan fen fang feng fu
da de dai dei dao dou dan den dang deng dong di dia die diao diu ding du duo dui duan dun
ta te tai tao tou tan tang teng tong ti tie tiao ting tu tuo tui tuan tun
na ne nai nei nao nou nan nen nang neng nong ni nie niao niu nin ning nu nuo nuan nun nv nve
la le lai lei lao lou lan lang leng long li lia lie liao liu lin ling lu luo luan lun lv lve
ga ge gai gei gao gou gan gen gang geng gong gu gua guo guai gui guan gun guang
ka ke kai kei kao kou kan ken kang keng kong ku kua kuo kuai kui kuan kun kuang
ha he hai hei hao hou han hen hang heng hong hu hua huo huai hui huan hun huang
ji jia jie jiao jiu jin jing ju jue juan jun jiong
qi qia qie qiao qiu qin qing qu que quan qun qiong
xi xia xie xiao xiu xin xing xu xue xuan xun xiong
zha zhe zhi zhai zhei zhao zhou zhan zhen zhang zheng zhong zhu zhua zhuo zhuai zhui zhuan zhun zhuang
cha che chi chai chao chou chan chen chang cheng chong chu chua chuo chuai chui chuan chun chuang
sha she shi shai shei shao shou shan shen shang sheng shu shua shuo shuai shui shuan shun shuang
re ri rao rou ran ren rang reng rong ru rua ruo rui ruan run
za ze zi zai zei zao zou zan zen zang zeng zong zu zuo zui zuan zun
ca ce ci cai cao cou can cen cang ceng cong cu cuo cui cuan cun
sa se si sai sao sou san sen sang seng song su suo sui suan sun
ya yo ye yao you yan yin yang ying yong yi yu yue yuan yun
wa wo wai wei wan wen wang weng wu
m n ng
]]
for s in py_list:gmatch("%S+") do PY[#PY + 1] = s end

-- 整词是否可被音节完全切分（带回溯 + 记忆化；s 为小写字母串）
function M.valid(s)
  if type(s) ~= "string" or s == "" or not s:match("^[a-z]+$") then return false end
  local n = #s
  local memo = {}
  local function ok(pos)
    if pos > n then return true end
    local v = memo[pos]
    if v ~= nil then return v end
    local hit = false
    for i = 1, #PY do
      local syl = PY[i]
      if s:sub(pos, pos + #syl - 1) == syl then
        if ok(pos + #syl) then hit = true break end
      end
    end
    memo[pos] = hit
    return hit
  end
  return ok(1)
end

return M
