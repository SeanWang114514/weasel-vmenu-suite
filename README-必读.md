# Rime VMenu 全家桶 · 安装指引（必读）

这是把「小狼毫输入法」升级成**全功能输入套件**的完整打包，包含：

| 功能 | 说明 |
| --- | --- |
| `v` 功能菜单 | 输入法里按 `v` 出功能菜单：设置窗口、剪贴板历史、收藏夹、快捷输入（计算/日期/农历…） |
| 可视化设置窗口 | 原生 `VMenuSettings.exe`，管理词库、剪贴板、模糊音、语音快捷键等（`v` → `1` 打开） |
| 剪贴板历史 | 后台同步，`v` → `2` 调用 |
| 下一个候选词预测 | 字级二元统计（`predict-bigram.txt`），上一个词猜下一个词 |
| 前后鼻音模糊输入 | an/ang、en/eng、in/ing、ian/iang、uan/uang 五对可单独开关 |
| 语音输入 | 按住 `Ctrl+Win` 说话，松开即上屏（Qwen3-ASR 本地识别，含流式输出） |
| 命令行语音输入 | `语音输入.bat`：说完回车，2 秒内自动粘贴 |
| 词库管理 | `词库管理.bat` / `加词.bat`，或设置窗口里直接编辑 |
| 候选框增强 | 一行 9 个、按 `↓` 展开 4×9 方格、长英文自动截断 |
| 托盘菜单 | 右键托盘「输入法设置 (S)」直接打开本套设置窗口 |

---

## 环境要求

- Windows 10/11 x64，**不需要管理员权限**（全部装进用户目录与 HKCU 注册表）
- 小狼毫输入法（Weasel）0.17+；**没装也没关系**，安装器会引导运行随包附带的安装器
- 语音输入的 Qwen3-ASR 模型约 **971MB**（exe 直装包与 zip 包都已包含；从 git 仓库安装的
  请运行一次 `下载Qwen模型.bat`）

## 方式 A：exe 直装（推荐）

1. 下载 Release 里的 `RimeVMenu-Setup-1.0.1.exe`，双击运行；
2. 安装目录**默认 = 你的 Rime 用户目录**（注册表 `RimeUserDir`，通常
   `%APPDATA%\Rime`），一般不用改；
3. 点「安装」→ 结束后会自动执行收尾：注册开机自启、装托盘入口、
   启动后台服务与语音悬浮球、**重新部署输入法**（首次需要编译方案，约半分钟）；
4. 完成后随便找个输入框打 `v`，出菜单即成功。

## 方式 B：zip 解压 + 一键安装（完整功能）

1. 下载 Release 里的 `RimeVMenu-1.0.1.zip`，解压到**任意位置**（路径随意）；
2. 双击解压目录里的 **`安装.bat`**；
3. 它会把整包复制进 Rime 用户目录，然后自动执行与 exe 相同的收尾步骤。

## 方式 C：小狼毫官方 rime-install 导入（只更新配置）

小狼毫自带的包安装器支持直接吃 zip（顶层 `*.yaml` / `*.txt` / `opencc\*` 按官方规则导入）：

```bat
"C:\Program Files\Rime\weasel-0.17.x\rime-install.bat" 全路径\RimeVMenu-1.0.1.zip
```

> ⚠️ **zip 的路径里绝对不能有空格**（也别用引号把路径括起来）。`rime-install.bat`
> 自己解析不了带空格/带引号的参数：实测会直接报
> `... \RimeVMenu-1.0.1.zip"" was unexpected at this time`，或者被误判成包名去
> GitHub 下载。所以请先把 zip 挪到无空格的目录（例如 `C:\RimePkg\`）再导入；
> 路径带空格时请改用方式 A 或 B。
>
> ⚠️ **官方规则的边界**：`rime-install.bat` 只复制**顶层的 `*.yaml`、`*.txt`
> 和 `opencc\`**，**不会**复制 `lua\`、`cn_dicts\`、`en_dicts\` 等子目录，也复制不了
> 语音/设置这些外挂 exe。所以它适合「给已部署好的机器**覆盖更新配置**」；
> **全新安装请用方式 A 或 B**（方式 B 里的 `安装.bat` 会把全部功能装齐）。

## 方式 D：git 源码安装（开发者）

```bat
git clone https://github.com/SeanWang114514/weasel-vmenu-suite.git
cd weasel-vmenu-suite
下载Qwen模型.bat          :: 拉取 Qwen3-ASR 两个模型（>100MB，不进 git）
powershell -File packaging\build-release.ps1    :: 本地打出 zip + exe
```

---

## 装完之后

- **打字**：`v` 出功能菜单，`v` `1` 打开设置窗口，`v` `3` 快捷输入；
- **语音**：按住 `Ctrl+Win` 说话（快捷键在设置窗口 →「语音输入」页可改）；
- **改配置**：一律在**设置窗口**里改，不要手改 `build\` 下的编译产物；
- **重新部署**：改了 `*.custom.yaml` 后双击 `重建部署.bat`，或右键托盘 → 重新部署。

## 文件装到哪了

所有东西都在 **Rime 用户目录**（下面以 `Rime目录` 指代）：

- 输入法配置 / lua / 词库：`Rime目录\*.yaml`、`Rime目录\lua\`、`Rime目录\cn_dicts\` 等
- 后台与界面：`VMenu.exe`（守护/剪贴板/自启）、`VMenuSettings.exe`（设置窗口）
- 语音：`VoiceOverlay.exe`（悬浮球）、`VoiceInput.exe`（命令行版）、
  `llama.cpp\`（CPU 推理运行时）、两个 `Qwen3-ASR*.gguf` 模型
- 你机器上的具体位置看注册表 `HKCU\Software\Rime\Weasel\RimeUserDir`
  （本包开发机是 `D:\rime-sandbox`，文档里出现的这个路径都指你的 Rime 用户目录）

## 卸载

控制面板 → 卸载「RimeVMenu 全家桶」：会停掉后台服务、还原托盘菜单改动、
删除安装的文件；**你自己的词库、剪贴板历史等数据保留**。
（手动撤销托盘改动：`powershell -File Rime目录\vmenu-tray-setup.ps1 -Revert`）

## 常见问题

- **打字没变化 / `v` 没反应**：右键托盘 → 重新部署；还不行就双击 `重建部署.bat`。
- **语音按了没反应**：看 `Rime目录\voice-overlay.log`；确认模型文件在 Rime 目录下
  （git 安装的先跑 `下载Qwen模型.bat`）。CPU 推理首字约 1~3 秒，属正常。
- **想让语音更快（NVIDIA 显卡）**：把 llama.cpp 官方 CUDA 构建的
  `llama-server.exe` 和相关 dll 覆盖进 `Rime目录\llama.cpp\` 即可。
- **设置窗口没弹出来**：双击 `打开设置.bat`，或确认 `VMenu.exe start` 在
  开机自启里跑着（`VMenu.exe status` 可查）。
