# Rime VMenu 全家桶（小狼毫输入法增强套件）

把小狼毫（Weasel）输入法升级成**全功能输入套件**：`v` 功能菜单、可视化设置窗口、
剪贴板历史、常用语、前后鼻音模糊输入、下一个候选词预测、**本地语音输入**（Qwen3-ASR）、
候选方格（4 行 × 9 列）……

> **只想装来用 → 别 clone 仓库，去 [Releases](../../releases) 下载。**
> `RimeVMenu-Setup-1.0.1.exe`（双击直装，含语音模型）或
> `RimeVMenu-1.0.1.zip`（解压后双击 `安装.bat`）。
> 安装细节看 [`README-必读.md`](README-必读.md)，功能细节看 [`使用说明.md`](使用说明.md)。

## 功能一览

| 功能 | 说明 |
| --- | --- |
| `v` 功能菜单 | 输入法里按 `v`：设置窗口 / 剪贴板 / 快捷输入（计算、日期、农历…）/ 常用语 / 原符号 |
| 可视化设置窗口 | 原生 `VMenuSettings.exe`：词库管理、剪贴板、模糊音、语音快捷键、防误触（`v` → `1`） |
| 剪贴板历史 | 后台同步，`v` → `2` 调用 |
| 常用语 / 个人词库 | 设置窗口里直接增删改，`加词.bat` / `词库管理.bat` 也行 |
| 下一个候选词预测 | 字级二元统计（`predict-bigram.txt`） |
| 前后鼻音模糊输入 | an/ang、en/eng、in/ing、ian/iang、uan/uang 五对可单独开关 |
| 语音输入 | 按住 `Ctrl+Win` 说话、松开上屏（Qwen3-ASR 本地推理，含流式输出） |
| 语音 CPU 占用 | 识别线程数可在设置窗口调（默认 4，整机占用约 26%），识别率不变 |
| 候选框增强 | 一行 9 个、按 `↓` 展开 4×9 方格、长英文自动截断 |
| 托盘入口 | 右键托盘图标 →「输入法设置 (S)」 |

## 从源码构建（开发者）

需要 Windows 10/11 x64、PowerShell 5.1、[Inno Setup 6](https://jrsoftware.org/isinfo.php)（打 exe 直装包用）。

```bat
git clone https://github.com/SeanWang114514/weasel-vmenu-suite.git
cd weasel-vmenu-suite
下载Qwen模型.bat                                 :: 拉两个 gguf（~971MB，不进 git）
powershell -ExecutionPolicy Bypass -File packaging\build-release.ps1
```

产物在 `out\`：`RimeVMenu-1.0.1.zip`（rime-install 兼容）+ `RimeVMenu-Setup-1.0.1.exe`。
构建脚本支持 `-NoModels`（跳过 971MB 模型，冒烟用）、`-SkipZip`、`-SkipExe`。

> [!IMPORTANT]
> 构建脚本会读取**当前机器的 Rime 用户目录**（注册表 `RimeUserDir`，缺省
> `%APPDATA%\Rime`）作为配置来源，找不到时退回仓库内的 `rime-sandbox\`。
> 所以在本机重打包含有你自己词库的包时，请先确认那是你想要的来源目录。

## 目录结构

```
lua\                  输入法侧逻辑（librime-lua）：v 菜单、模糊音、预测、标点…
cn_dicts\ en_dicts\   词库（rime-ice 基线 + 个人词库/常用语）
packaging\            发布打包：build-release.ps1 + RimeVMenu.iss（Inno Setup）
VMenuSettingsSrc\     设置窗口的 C# 源码（csc 编译成 VMenuSettings.exe）
VMenu.cs              守护/剪贴板同步/VMenu.exe 的 C# 源码
vmenu-settings-gui.ps1 设置窗口的 PowerShell 版（含 QA 自检模式）
vmenu-tray-setup.ps1  托盘「输入法设置」入口的安装/撤销
voice-overlay.py      语音输入悬浮球（PyInstaller 打成 VoiceOverlay.exe）
voice-input.py        命令行语音输入（打成 VoiceInput.exe）
rime-sandbox\         一份可直接用于构建的 Rime 配置快照
```

## 已知注意事项

- **`rime-install.bat`（官方导入）只复制顶层 `*.yaml`/`*.txt` 和 `opencc\`**，
  不复制 `lua\`、`cn_dicts\` 和外挂 exe —— 它只适合「给已装好的机器覆盖更新配置」，
  全新安装请用 exe 或 zip。另外它的 zip 路径**不能带空格、不能加引号**。
- 语音模型（`*.gguf`）不进仓库（超 GitHub 100MB 单文件限制），
  Release 附件里已经带上了；从源码装请先跑 `下载Qwen模型.bat`。
- 想让语音更快（NVIDIA 显卡）：把 llama.cpp 官方 CUDA 构建的 `llama-server.exe`
  和相关 dll 覆盖进安装目录的 `llama.cpp\` 即可。

## 第三方组件与许可

本套件建立在他人成果之上，这些组件**保留各自原有许可**：

- [rime-ice](https://github.com/iDvel/rime-ice) —— 词库与方案基线（见 `rime-sandbox\LICENSE`）
- [llama.cpp](https://github.com/ggml-org/llama.cpp) —— CPU 推理运行时（MIT，含 `LICENSE-LLVM-OpenMP`）
- [Qwen3-ASR](https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF) —— 语音识别模型
- [小狼毫 Weasel](https://github.com/rime/weasel) / [librime](https://github.com/rime/librime) —— 输入法宿主

本仓库自身的脚本与 lua 代码可自由参考使用。
