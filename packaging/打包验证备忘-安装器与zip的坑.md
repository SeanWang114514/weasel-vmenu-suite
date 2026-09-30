# 打包发布 · 安装器与 zip 的坑（2026-09-27 实测记录）

> 这份是「打包上传 GitHub + Release 双格式分发」这一轮的验证备忘。
> 全部结论都有实测证据（命令 / 日志 / 退出码），不是读代码猜的。
> 下次改 `packaging\build-release.ps1` 或 `packaging\RimeVMenu.iss` 前先读一遍。

## 0. 一句话结论

exe 直装包原来在**任何「目标目录已有文件」的机器上都会安装失败并整机回滚**，
外加两个「界面说成功、其实功能没生效」的静默坑。全部已修 + 已实测。

## 1. 六个已修 bug（按严重程度）

### ① 【致命】覆盖安装必然失败：MoveFile 183 → 整机回滚
- **现象**：装过一次之后再装（或目标目录里已有旧文件），安装器报
  `MoveFile: The existing file appears to be in use (183)`，
  `An error occurred while trying to rename a file in the destination directory`，
  重试 4 次后 Abort → **Rolling back changes**，装了一半的东西全被撤掉。
- **根因**：`[Files]` 里写了 `ignoreversion`。它让 Inno 走「解包到临时目录 →
  `MoveFile` 替换目标」这条路，而那个 `MoveFile` **不带 REPLACE_EXISTING**，
  目标已存在就返回 `183 = ERROR_ALREADY_EXISTS`（报错文案说 "in use" 是误导；
  实测独占锁住文件报的是 `5 / ERROR_ACCESS_DENIED`，不是 183）。
  最大受害者是 804MB 的 `Qwen3-ASR-0.6B-Q8_0.gguf`。
- **修**：`packaging\RimeVMenu.iss` 的 `[Files]` 去掉 `ignoreversion`
  （Inno 改用时间戳/大小判断，同内容直接跳过）。
- **实证**：`_tmp-session\*` 测试里 1KB 占位文件被 804MB 真模型成功替换，
  退出码 0，日志零 `MoveFile`。

### ② 【致命】`PrepareToInstall` 不停 llama-server，模型文件换不掉
- **现象**：语音用过后 `llama-server.exe` 一直把 `.gguf` 映射着，安装器换不掉。
- **修**：`Stop-Helpers.bat` 增加 `llama-server.exe` 的 kill（原来只停
  VMenu / VoiceOverlay / VoiceInput）。
- **实证**：改前 `llama-server` 存活 → 日志出现 `DeleteFile ... in use (32)` +
  回滚；改后跑 `Stop-Helpers.bat` 能把它杀掉（实测 killed）。

### ③ 【严重·静默】装到「上次装过的目录」，不是 Rime 用户目录
- **现象**：不带 `/DIR=` 安装时，文件静默落到**上一次安装记录的目录**，
  而不是注册表 `RimeUserDir`。输入法只读 `RimeUserDir` 里的配置 →
  界面提示安装成功、功能一个都没生效。实测：安装器 `[Run]` 去执行了
  `C:\Users\...\Temp\vmenu-reinstall2\安装-收尾.bat`，开机自启也被改成那个临时目录。
- **根因**：Inno 的 `UsePreviousAppDir` **默认 yes**，它把
  `HKCU\...\Uninstall\{AppId}_is1\InstallLocation` 当作新默认值，
  **压过 `DefaultDirName`，也压过 `InitializeWizard` 里按注册表算出来的值**。
- **修**：`[Setup]` 加 `UsePreviousAppDir=no`。
- **实证**：修后不带 `/DIR=` 安装，`InstallLocation = D:\rime-sandbox\`（= 注册表值），
  文件确实落在 `D:\rime-sandbox`。

### ④ 【严重】`/DIR=` 被 `InitializeWizard` 吃掉
- **根因**：`InitializeWizard` 无条件 `WizardForm.DirEdit.Text := 注册表值`，
  把命令行 `/DIR=` 覆盖掉（静默安装测试时表现成「/DIR 被忽略」）。
- **修**：新增 `DirGivenOnCommandLine()`，只有命令行没给 `/DIR=` 时才套注册表默认值。
- **实证**：`/DIR=<temp>` 安装后 `entries=73` 且日志里 `D:\rime-sandbox` 命中 0 行。

### ⑤ 【严重·静默】zip 里 12 个中文文件名没有 UTF-8 标志（裸 GBK）
- **现象**：`安装.bat` / `语音输入.bat` / `使用说明.md` 等 12 个条目，
  zip 头 `flags=0x0000`（无 UTF-8 位 bit 11），文件名是**裸 GBK 字节**。
  简体中文机的 7-Zip / 资源管理器看着正常（按 ACP 936 解），
  但 **.NET `ZipFile`（严格按 UTF-8 读）、macOS、Linux、任何非 GBK 的 Windows
  全是乱码**，而 `rime-install.bat` 恰恰靠文件名找包。
- **根因**：`7z a -tzip` 在 ACP=936 的机器上**不会**自动选 UTF-8。
  对照组：`Compress-Archive` 同样的文件名写的是 `flags=0x800`（正确）。
- **修**：`build-release.ps1` 打 zip 时加 `-mcu=on`（强制 UTF-8 存名 + 置标志位），
  并新增**回归断言**：非 ASCII 条目必须能被 .NET 解成汉字，否则构建失败。
- **实证**：改后 12 个条目全部 `flags=0x800`，`.NET` 读出 `安装.bat` 等正确名字；
  构建输出 `zip entry names: 12 non-ASCII entries decode as UTF-8 OK`。

### ⑥ 【严重·数据丢失】卸载会删掉用户自己的词库（与 README 承诺相反）
- **现象**：`[Files]` 用通配符装整包，其中 `cn_dicts\mydict.dict.yaml`（个人词库）、
  `cn_dicts\favorites.dict.yaml`（常用语）、`custom_phrase.txt` 都是**用户数据**。
  Inno 默认「安装过的文件卸载时全删」→ 用户词库凭空消失；
  覆盖安装时还会用包里的副本按时间戳盖掉用户新加的词。
  而 README 写的是「**你自己的词库、剪贴板历史等数据保留**」。
- **修**：主条目加 `Excludes:`，这 4 个文件改成单独条目
  `Flags: onlyifdoesntexist uninsneveruninstall`。
- **实证**：在临时目录里先植入 `USERWORD` 哨兵 → 静默卸载 →
  `VMenu.exe` / `lua\` 已删除，`favorites.dict.yaml`（含哨兵）/ `mydict` /
  `custom_phrase.txt` **全部保留**。

## 2. 文档坑（已改 README-必读.md）

- **方式 C 的 `rime-install.bat` 路径不能有空格、也不能加引号**：实测带空格路径
  直接报 `... DummyPkg-9.9.9.zip"" was unexpected at this time`；加引号会被
  误判成包名去 GitHub 下载（`%package:.zip=%.zip` 比较被引号破坏）。
  README 已加警告：先把 zip 挪到无空格目录再用方式 C。
- 顺带核实过的**边界**（不是 bug，是官方规则）：`rime-install.bat` 只复制
  **顶层 `*.yaml` / `*.txt` 和 `opencc\`**，不复制 `lua\`、`cn_dicts\`、外挂 exe。

## 3. 验证过的「不是 bug」

| 疑点 | 结论 |
| --- | --- |
| 安装/卸载脚本「卡住」不返回 | **测试工具的假象**：cmd/pwsh 会等子进程释放继承的 stdio 管道；常驻服务（VMenu watch/sync、设置窗口）一直持有 → 外层看着像挂住。Inno 自己的日志是权威：`[Run]` 之后 `Process exit code: 0`（13s）。单独计 `vmenu-tray-setup.ps1` 只要 13.6s。 |
| `D:\rime-sandbox` 硬编码 | 都是**兜底**（env → 注册表 → `%APPDATA%\Rime` → 旧开发目录），不是硬依赖。 |
| `vmenu-settings-gui.ps1` 的 `$RimeDir` 默认值 | 调用方（watcher、wrapper、打开设置.bat）都显式传 `-RimeDir`。 |
| `设置.bat` 里写死 `D:\rime-sandbox` | 该文件**不在发布包**里（dev 遗留），无害。 |
| 打包的 exe | `VMenuSettings.exe --hotkeytest` exit 0；`VoiceInput.exe --selftest` exit 0，路径解析全部指向 Rime 目录。`vosk_ok=False` 属预期（不装 vosk，走 Qwen3-ASR）。 |

## 4. 复现/回归用的最小测试矩阵

```powershell
# 打包（可选 -NoModels 冒烟 / -SkipExe / -SkipZip）
powershell -File packaging\build-release.ps1

# ① /DIR 生效 + ② 不带 /DIR 落到注册表目录
Start-Process out\RimeVMenu-Setup-1.0.0.exe -ArgumentList `
  '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SKIPPOST',"/DIR=$env:TEMP\A" -Wait
Start-Process out\RimeVMenu-Setup-1.0.0.exe -ArgumentList `
  '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SKIPPOST' -Wait   # 应落到 D:\rime-sandbox

# ③ 覆盖安装不再回滚（连着跑两遍，第二遍是关键）
# ④ 用户数据保留：往 favorites 里加哨兵 → 重装 → 卸载 → 哨兵必须还在
```

> ⚠️ 两个测试注意事项：
> 1. **别在命令行里出现待杀进程的路径名**：`Get-CimInstance ... | Where CommandLine
>    -like '*某个目录*'` 会把**自己**匹配上然后杀掉自己（本次实测踩过，任务直接
>    以 exit -1 静默死掉）。要用运行时拼接的字符串 + 排除 `$PID`。
> 2. 临时目录安装同样会**改真实系统**：`[Run]` 的收尾步骤会改开机自启、
>    重装托盘入口（改 Program Files 里的 `WeaselDeployer.exe`）、重启
>    `WeaselServer`；卸载会把这些再撤掉。测完记得检查/还原：
>    `HKCU\...\Run\RimeVMenuWatcher`、`vmenu-tray-setup.ps1`、`VMenu.exe start`。

## 5. 发布结果（已完成）

- 仓库（公开）：<https://github.com/SeanWang114514/weasel-vmenu-suite>
  —— 281 个文件，约 290MB，分支 `main`，`.gitignore` + `.gitattributes` 已就位。
- Release：<https://github.com/SeanWang114514/weasel-vmenu-suite/releases/tag/v1.0.0>
  —— `RimeVMenu-Setup-1.0.0.exe`（1,195,182,480 字节）与
  `RimeVMenu-1.0.0.zip`（1,199,917,490 字节），远端大小与本地逐字节一致。
- 构建产物已重建并校验：zip sha256 `7FC46D27EFD936FD…`、exe sha256 `469B39DC81394DD2…`。
- **博客介绍文章**（含下载地址 + 项目地址）已发布：
  <https://seanwang114514.github.io/2026/09/30/weasel-vmenu-suite/>
  —— 源文件在 `SeanWang114514/SeanWang114514.github.io` 的
  `_posts/2026-09-30-weasel-vmenu-suite.markdown`，浅克隆留在工作区 `_tmp-blog\`
  （以后改文章直接在里面 `git pull --rebase && git commit && git push`）。
  - 版式对齐站内既有文章：front matter（`layout: post` / `subtitle` / `catalog: true` / `tags`）、
    GitHub 双按钮、「快速下载」卡片、`<!--more-->`、架构 SVG 图（720 宽、`#1677FF` 强调色）、
    从源码构建、已知限制、开源致谢。
  - **两个坑**：① Jekyll 默认**不发布「未来日期」的文章**（`future: false`），日期必须早于构建时间；
    ② 发文章当时本机时钟读 `2026-09-27`，实际是 `09-30`（以 GitHub Actions 时间戳为准），
    先写 09-27 后改名为 `2026-09-30-…` —— **改名会让旧 URL 变 404**，所以日期要在发布前定准。
  - 站点是 GitHub Actions 上的 Jekyll，push 后约 40~60 秒构建完；`search.json` / `archive.html` /
    首页全靠 `site.posts` 自动生成，**不需要手工维护索引**（首页帖子链接是相对路径 `/2026/09/30/…/`）。

### 仓库化时又抓到两个「从源码构建」的坑

7. **仓库里的 `rime-sandbox\` 是过时副本**：缺 `lua\vmenu_core.lua`（整个 v 菜单）、
   `lua\predict_filter.lua`、`lua\phrase_first.lua`，opencc 也不全 —— 全新 clone
   构建出来的包会少功能。已改为从真实 Rime 用户目录重新快照（41 个 lua / 3 个 opencc 全齐），
   排除 `build\`、`*.userdb`（WeaselServer 占用 + 运行时产物）、日志、安装标记，
   并把剪贴板历史清空后入库（隐私）。
8. **`build-release.ps1` 的 `-LlamaSrc` 没有回退**：默认值指向开发者本机路径
   `D:\王修翊\llama.cpp`，找不到就直接 `throw` —— 全新 clone 的机器必然构建失败。
   已补上退回仓库内 `llama.cpp\` 的逻辑（与 `RimeSrc` 一致）。

> 踩坑提醒：`robocopy` 的 `/XD` **不接受带通配符的全路径**
> （`D:\rime-sandbox\*.userdb` 会报 `Invalid Parameter #13`），要用纯目录名；
> 另外 `/XF '*.userdb'` 对**目录**无效（`rime_ice.userdb` 是目录），必须走 `/XD`。
> 还有：`git add -A 2>&1 | Select-Object -First N` 会因为管道提前关闭而让 git 中断，
> 结果**一个文件都没暂存**；中文路径在 `git diff --cached` 里默认是八进制转义，
> 要加 `-c core.quotepath=false` 才能和文件名比对。`git init` 这台机器默认分支是
> `master`，推 `main` 前记得 `git branch -M main`。

### 维护入口

- 重新整理并推送仓库：`powershell -File packaging\stage-suite-repo.ps1`，
  然后到 `repo\weasel-vmenu-suite\` 里 `git add -A && git commit && git push`。
  ⚠️ 该脚本是「全量重刷」`packaging\` 与根目录文件；**改完工作区文件记得重跑它**，
  否则会出现「工作区已修、仓库里还是旧版」的假提交（本次就发生过一次：
  commit message 写了 llama.cpp 回退，但仓库副本没同步）。
- Release 正文：`packaging\RELEASE-NOTES-1.0.0.md`。
