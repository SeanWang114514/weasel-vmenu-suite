; ============================================================================
; RimeVMenu.iss - 小狼毫全家桶 exe 直装包（Inno Setup 6）
;
; 装什么：完整包（RIME 配置 + lua + 词库 + VMenu/VMenuSettings/语音 exe +
; llama.cpp CPU 运行时 + Qwen3-ASR 模型 + 一键收尾脚本）。
; 装到哪：小狼毫的 Rime 用户目录（注册表 RimeUserDir，缺省 %APPDATA%\Rime），
; 与 zip 包 安装.bat 的落点完全一致 —— 两种格式装出来的是同一套东西。
;
; 编译（build-release.ps1 调用）：
;   iscc.exe packaging\RimeVMenu.iss
; 输入：..\stage\RimeVMenu-1.0.1\ （由 build-release.ps1 搭好）
; ============================================================================

#define MyAppName "Rime VMenu 全家桶"
#define MyAppNameShort "RimeVMenu"
; 下面两个 define 用 #ifndef 包住，是为了让构建脚本能用 ISCC 的 /D 覆盖出 GPU 版：
;   powershell -File packaging\build-release.ps1 -Gpu
;     -> /DMyAppVersion=1.1.0-GPU /DMyStageDir=..\stage\RimeVMenu-1.1.0-GPU
; 不加 #ifndef 的话，这里的 #define 会**永远压过**命令行 /D，GPU 版会静默编成
; CPU 版的文件名和 stage 目录（内容却是 GPU 的），非常难查。
; 另外 /D 的值不能带引号（带了 Inno 会把引号当值的一部分，OutputBaseFilename 非法）。
; 下面两行就是无参数构建（CPU 版）时的默认值。
#ifndef MyVerNum
  #define MyVerNum "1.1.0"
#endif
#ifndef MyAppVersion
  #define MyAppVersion "1.1.0"
#endif
#ifndef MyStageDir
  #define MyStageDir "..\stage\RimeVMenu-1.1.0"
#endif

[Setup]
AppId={{7C4E1B52-9A6F-4D2E-8C31-5B0A9E7D2F41}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=SeanWang114514
AppPublisherURL=https://github.com/SeanWang114514/weasel-vmenu-suite
VersionInfoVersion={#MyVerNum}
DefaultDirName={userappdata}\Rime
; ★ 必须关掉「沿用上次安装目录」：Inno 默认 UsePreviousAppDir=yes，会把上一次安装
; 写进 HKCU\...\Uninstall\{AppId}_is1\InstallLocation 的目录当成新默认值，
; **同时压过 DefaultDirName 和 InitializeWizard 里按注册表算出来的 RimeUserDir**。
; 后果很隐蔽：装了别处（或换过 RimeUserDir）之后再装，文件会静默落到旧目录，
; 而输入法只读注册表里的 RimeUserDir —— 界面提示「安装成功」但功能一个都没生效。
; 本包的目标目录永远是「当前的 Rime 用户目录」，所以这个默认行为必须关掉。
; （显式 /DIR= 仍然优先，安装向导里也能手动改。）
UsePreviousAppDir=no
DisableProgramGroupPage=yes
; 装到用户目录 + 改 HKCU，全程不需要管理员
PrivilegesRequired=lowest
OutputDir=..\out
OutputBaseFilename={#MyAppNameShort}-Setup-{#MyAppVersion}
Compression=lzma2/normal
SolidCompression=no
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\VMenu.exe
UninstallDisplayName={#MyAppName}
CloseApplications=force
LZMANumBlockThreads=2

[Languages]
Name: "chs"; MessagesFile: "compiler:Default.isl"

[Files]
; 注意 Flags 里**不能**用 ignoreversion（等价于 overwritereadonly + 强制替换）：
; 大文件（Qwen3-ASR 804MB）走的是「解包到临时目录 -> MoveFile 替换目标」这条路，
; 目标已存在时 Inno 的 MoveFile 会以 183 (ERROR_ALREADY_EXISTS) 失败 ——
; 报错文案却说「file appears to be in use」，重试 4 次后 Abort，**整台机器的安装回滚**
; （2026-09-27 实测：覆盖安装时模型已存在 -> 安装失败）。
; 去掉 ignoreversion 后 Inno 用时间戳/大小判断，同内容文件直接跳过，
; 真正需要替换时也走可以覆盖的写入路径。
;
; 用户数据文件（个人词库 / 常用语 / 自定义短语 / 剪贴板历史）从主条目里排除，
; 单独用 onlyifdoesntexist + uninsneveruninstall 装：
;   * 覆盖安装时绝不用安装包里的副本盖掉用户自己的词库（时间戳谁新谁赢＝会误删数据）；
;   * 卸载时保留，兑现 README「你自己的词库、剪贴板历史等数据保留」的承诺
;     （默认行为是「安装过的文件卸载时全删」，会导致用户词库凭空消失）。
Source: "{#MyStageDir}\*"; DestDir: "{app}"; \
  Excludes: "cn_dicts\mydict.dict.yaml,cn_dicts\favorites.dict.yaml,custom_phrase.txt,clipboard-cache.txt"; \
  Flags: recursesubdirs createallsubdirs
Source: "{#MyStageDir}\cn_dicts\mydict.dict.yaml"; DestDir: "{app}\cn_dicts"; \
  Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#MyStageDir}\cn_dicts\favorites.dict.yaml"; DestDir: "{app}\cn_dicts"; \
  Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#MyStageDir}\custom_phrase.txt"; DestDir: "{app}"; \
  Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#MyStageDir}\clipboard-cache.txt"; DestDir: "{app}"; \
  Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
Name: "{autoprograms}\{#MyAppNameShort} 设置"; Filename: "{app}\VMenu.exe"; Parameters: "open"
Name: "{autoprograms}\{#MyAppNameShort} 语音输入悬浮球"; Filename: "{app}\语音输入-悬浮球.bat"
Name: "{autoprograms}\{#MyAppNameShort} 使用说明"; Filename: "notepad.exe"; Parameters: """{app}\使用说明.md"""

[Run]
Filename: "{cmd}"; \
  Parameters: "/c """"{app}\安装-收尾.bat"""""; \
  StatusMsg: "正在完成安装：启动后台服务 / 托盘入口 / 部署输入法（首次可能需要 1 分钟）..."; \
  Flags: runascurrentuser waituntilterminated; \
  Check: SkipPost

[UninstallDelete]
; 部署产生的运行时文件随卸载一并清掉；userdb 等用户数据保留
Type: files; Name: "{app}\open-settings.flag"
Type: files; Name: "{app}\vmenu-debug.log"
Type: files; Name: "{app}\voice-overlay.log"
Type: files; Name: "{app}\lua-probe.txt"
Type: files; Name: "{app}\panel-probe.txt"

[Code]
// 安装目录默认值 = 注册表 RimeUserDir（小狼毫自定义用户目录），否则 %APPDATA%\Rime。
// InitializeWizard 在静默模式下同样会执行，所以 /VERYSILENT 也能拿到正确目录。
var DefaultRimeDir: String;

function ResolveDefaultDir(): String;
var
  s: String;
begin
  Result := ExpandConstant('{userappdata}\Rime');
  if RegQueryStringValue(HKCU, 'Software\Rime\Weasel', 'RimeUserDir', s) then
    if s <> '' then Result := s;
end;

// 命令行里是否显式给了 /DIR=（显式指定优先，绝不覆盖用户的选择）。
function DirGivenOnCommandLine(): Boolean;
var
  i: Integer;
  p: String;
begin
  Result := False;
  for i := 1 to ParamCount do
  begin
    p := ParamStr(i);
    if CompareText(Copy(p, 1, 5), '/DIR=') = 0 then
    begin
      Result := True;
      exit;
    end;
  end;
end;

procedure InitializeWizard();
begin
  DefaultRimeDir := ResolveDefaultDir();
  // 只有用户没在命令行上指定 /DIR= 时，才用注册表算出来的 Rime 用户目录做默认值。
  // 之前这里是无条件赋值：既会吃掉 /DIR=（静默安装测试时表现为 /DIR 被忽略、
  // 直接装进注册表里的 RimeUserDir），也让 UsePreviousAppDir 的旧目录彻底无法纠正。
  if not DirGivenOnCommandLine() then
    WizardForm.DirEdit.Text := DefaultRimeDir;
end;

// 打包测试用 /SKIPPOST 跳过收尾（服务/托盘/部署），只验证解包与文件落位。
function SkipPost(): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 1 to ParamCount do
    if CompareText(ParamStr(i), '/SKIPPOST') = 0 then
    begin
      Result := False;
      exit;
    end;
end;

// 覆盖安装前先停掉常驻进程，否则正在运行的 exe 无法被替换。
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  stopBat: String;
begin
  Result := '';
  stopBat := ExpandConstant('{app}\Stop-Helpers.bat');
  if FileExists(stopBat) then
    Exec(ExpandConstant('{cmd}'), '/c ""' + stopBat + '""', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
end;

// 卸载时：停后台服务 -> 撤销开机自启 -> 还原托盘菜单（文件删除之前执行）。
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    if FileExists(ExpandConstant('{app}\VMenu.exe')) then
      Exec(ExpandConstant('{app}\VMenu.exe'), 'stop', '', SW_HIDE,
        ewWaitUntilTerminated, ResultCode);
    Exec(ExpandConstant('{cmd}'),
      '/c reg delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v RimeVMenuWatcher /f',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if FileExists(ExpandConstant('{app}\vmenu-tray-setup.ps1')) then
      Exec(ExpandConstant('{cmd}'),
        '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' +
        ExpandConstant('{app}\vmenu-tray-setup.ps1') + '" -Revert',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
