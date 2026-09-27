# Rime VMenu 全家桶 1.0.0

把小狼毫（Weasel）输入法一步升级成**全功能输入套件**。两个包**功能完全一致**，按喜好选一个下载即可。

## 下载哪个？

| 文件 | 适合谁 | 怎么装 |
| --- | --- | --- |
| **`RimeVMenu-Setup-1.0.0.exe`**（1.1 GB） | 大多数人 | 双击 → 一路下一步。自动识别你的小狼毫用户目录、装好后台服务、托盘入口，并自动部署 |
| **`RimeVMenu-1.0.0.zip`**（1.1 GB） | 想手动/绿色安装，或用小狼毫官方 `rime-install` 导入配置 | 解压后双击 **`安装.bat`**；只更新配置见下方说明 |

> 首次安装会带 **971 MB 语音模型**（Qwen3-ASR，本地离线推理），所以包体积大。不想要语音功能可以装完后删掉安装目录里的两个 `*.gguf`。

## 装好的功能

- **`v` 功能菜单** —— 输入法里按 `v`：设置窗口 / 剪贴板 / 快捷输入（计算、日期、农历、序号…）/ 常用语 / 原符号
- **可视化设置窗口**（原生 `VMenuSettings.exe`）—— 词库管理、剪贴板、模糊音开关、语音快捷键、防误触，改完即生效
- **剪贴板历史** —— 后台自动记录，`v` → `2` 调用
- **常用语 / 个人词库** —— 设置窗口直接增删改，或用 `加词.bat` / `词库管理.bat`
- **下一个候选词预测** —— 字级二元统计，打完一个字就提示下一个
- **前后鼻音模糊输入** —— an/ang、en/eng、in/ing、ian/iang、uan/uang 五对可单独开关
- **本地语音输入** —— 按住 `Ctrl+Win` 说话、松开上屏，流式输出，全程离线
- **候选框增强** —— 一行 9 个候选，按 `↓` 展开 4×9 方格，长英文自动截断
- **托盘入口** —— 右键托盘图标 →「输入法设置 (S)」

## 环境要求

- Windows 10 / 11 x64
- 小狼毫 [Weasel](https://github.com/rime/weasel)（exe 包在检测不到时会自动拉起内置的 0.17.4 安装器）
- 全程**不需要管理员权限**（装进用户目录、只写 `HKCU`）
- 语音走 CPU 推理即可用；有 N 卡可换 llama.cpp 的 CUDA 版 `llama-server.exe` 提速

## zip 用户：只想更新配置（方式 C）

小狼毫自带 `rime-install.bat` 可直接吃本 zip，但遵守官方规则：**只复制顶层 `*.yaml`、`*.txt` 和 `opencc\`**，
不复制 `lua\`、`cn_dicts\` 和外挂 exe —— 适合给已部署好的机器覆盖更新配置。

```bat
"C:\Program Files\Rime\weasel-0.17.4\rime-install.bat" C:\RimePkg\RimeVMenu-1.0.0.zip
```

> ⚠️ zip 路径**不能有空格、也不能加引号**（`rime-install.bat` 自身解析不了，会报 batch 语法错或误当成包名去 GitHub 下载）。请先把 zip 挪到无空格目录。

## 卸载

控制面板 →「RimeVMenu 全家桶」卸载：会停后台服务、还原托盘菜单改动、删除安装的文件。
**你自己的词库、常用语、剪贴板历史会保留**（已实测）。

## 校验

```
RimeVMenu-Setup-1.0.0.exe   sha256  469B39DC81394DD26DAF96EBE377FBA52DD2B8D8991AC40EA1BF92C5EBE5B586
RimeVMenu-1.0.0.zip         sha256  7FC46D27EFD936FD0BBBD2AEF155AC7570D15DBDDD25203606CC254170A87B6E
```

## 从源码构建

见仓库 [README.md](https://github.com/SeanWang114514/weasel-vmenu-suite#从源码构建开发者)：
clone → `下载Qwen模型.bat` → `powershell -File packaging\build-release.ps1`，即可复现上面两个包。

---

### 本版修掉的问题（都经过实测）

- 覆盖安装必定失败并**整机回滚**（`MoveFile` 报 183 / "file appears to be in use"）—— 已修
- 语音用过后 `llama-server.exe` 占着模型导致装不上 —— 安装前会先停掉
- 不带 `/DIR=` 安装时，文件会**静默装到上次的目录**而不是当前小狼毫用户目录（界面提示成功、功能却没生效）—— 已修
- zip 里中文文件名缺少 UTF-8 标志，在非 GBK 环境（macOS/Linux/.NET）会乱码 —— 已修
- 卸载会删掉用户自己的词库，与承诺相反 —— 已修，改为保留

第三方组件（rime-ice / llama.cpp / Qwen3-ASR / 小狼毫）保留各自原有许可。
