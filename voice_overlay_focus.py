# -*- coding: utf-8 -*-
"""焦点判定：语音识别出的文字到底该不该打进当前焦点控件。

需求（用户原话）：「检测语音输入的时候，语音输入的内容是否在一个输入框中；
如果不在输入框，就默认把输入框内容复制一下，然后在悬浮球中弹出提示『已复制』。」

为什么单独成模块：**不依赖 Windows**，所以纯函数回归（`tmp/test-focus-target.py`）
和实机悬浮球跑的是同一份规则表，避免「测试里复刻一份、改一处忘一处」。

判定依据全部来自实机实测（`tmp/probe-focus.py` 的输出）：

| 场景 | 前台窗口类 | 焦点控件类 | 结论 |
| --- | --- | --- | --- |
| 记事本 | Notepad | RichEditD2DPT | 输入框 |
| Chrome / Edge / Electron | Chrome_WidgetWin_1 | 同顶层（渲染进程自绘） | 输入框 |
| Word | OpusApp | _WwG | 输入框 |
| winver 对话框（焦点在「确定」） | #32770 | Button | **不是**输入框 |
| 资源管理器文件列表 | CabinetWClass | DirectUIHWND | **不是**输入框 |
| 桌面 / 任务栏 | Progman / WorkerW / Shell_TrayWnd | 同顶层或子控件 | **不是**输入框 |
| Windows 终端 / conhost | CASCADIA_HOSTING_WINDOW_CLASS / ConsoleWindowClass | — | **不是**输入框 |
| Tk 输入框 / 按钮 / 画布 | TkTopLevel | TkChild（三者同一个 HWND） | **判不了**（照老行为注入） |

两个关键实测结论：

1. **`hwndFocus` 非零也未必可信**：焦点在桌面上时 `GetGUIThreadInfo` 会返回
   上一次的陈旧 `hwndFocus`（常常是个正常控件名）。所以「顶层窗口类名」的负判
   优先级最高，它比焦点控件类名可靠。
2. **焦点控件等于顶层窗口时不能说「不是输入框」**：浏览器/Electron/微信把编辑区
   放在独立渲染进程里，父窗口只看得到顶层 HWND；这时按顶层窗口类名正判。

兜底策略：`FOCUS_UNKNOWN` 一律按老行为照常注入。宁可偶尔把字打进一个收不了字的
窗口（用户看得见、能重来），也不要凭空把用户的输入内容改成「复制到剪贴板」。

已知边界（都是「判不了 -> 照老行为注入」，不会误报「已复制」）：

- **自绘界面**（Tk / WPF / Qt / UWP / 自绘 C++）：输入框不是独立 HWND，焦点控件
  类名对「输入框」和「按钮」是同一个值（实测 Tk 三者都是 TkChild、连
  `GetGUIThreadInfo` 的 caret 与 flags 也完全一样），Windows 层面**无法区分**；
- **同一顶层窗口自己拿焦点时**（如资源管理器的文件列表没聚焦、焦点落回窗口本身）：
  这类窗口里既有输入框又有列表，判负风险太大，所以只在顶层窗口类名明确属于
  「绝无可编辑区」（桌面/任务栏/终端/控制台）时才判负。
"""

FOCUS_EDIT = "edit"          # 焦点确定在可输入控件里 -> 正常注入
FOCUS_NONEDIT = "nonedit"    # 焦点确定不在可输入控件里 -> 改走剪贴板 + 提示
FOCUS_UNKNOWN = "unknown"    # 判不了 -> 按老行为注入

# 顶层窗口类名 → 「绝无可编辑区」（实测：桌面/任务栏/终端/控制台）
NONEDIT_WINDOW_CLASSES = (
    "#32769",                                   # GetDesktopWindow() 的类名
    "progman", "workerw",                       # 桌面（Progman=GetShellWindow()）
    "chineseocrlitedesktop",                    # 本机桌面被这个自绘窗口接管过（实测见过）
    "shell_traywnd", "shell_secondarytraywnd",
    "shell_dll_defview", "shelldll_defview", "tasklistthumbnailwnd",
    "toplevelwindowforoverflowxamlisland", "xamlislandwindow",
    "pathwindowclass", "dragwindow",
    "consolewindowclass", "pseudoconsolewindow", "conhost", "conhosticonsole",
    "cascadia_hosting_window_class",
)

# 焦点控件类名 → 「绝无可编辑区」（标准 Win32 死控件 + 实测命中的那几个）
# 注意：Chrome_RenderWidgetHostHWND / Internet Explorer_Server 这类**渲染/文档**
# 控件不在名单里 —— 它们在浏览器里恰恰是正文输入区。
NONEDIT_FOCUS_CLASSES = (
    "button", "static", "syslink", "toolbarwindow32", "rebarwindow32",
    "msctls_statusbar32", "msctls_progress32", "msctls_trackbar32",
    "scrollbar", "systabcontrol32", "systreeview32", "syslistview32",
    "systoolbar32", "listbox", "comboboxex32", "msctls_updown32",
    "tooltips_class32", "shell_traywnd", "shell_secondarytraywnd",
    "traynotifywnd", "shell_dll_defview", "shelldll_defview",
    "progman", "workerw", "directuihwnd", "tasklistthumbnailwnd",
    "toplevelwindowforoverflowxamlisland", "pathwindowclass", "dragwindow",
    # 故意**不**收录的类名，以及原因（都被实测否掉过，别再往这里加）：
    #   TkChild   —— Tk 的 Entry/Button/Canvas 全叫这个名（同一个 HWND），
    #                判负会把「Tk 程序里的输入框」也变成复制；判正又会让
    #                「对着 Tk 按钮说话」凭空注入。两难 -> 留给 unknown 注入。
    #   Windows.UI.Core.CoreWindow / XamlIslandWindow —— UWP 的文本框就画在里面，
    #                同理判不了。
    #   Chrome_RenderWidgetHostHWND / Internet Explorer_Server —— 浏览器正文输入区。
)

# 顶层窗口类名 → 「这个窗口里默认有可编辑区」。这是唯一走「看顶层窗口类名」的正判，
# 名单里每一条都核实过「窗口里有可编辑区」（浏览器/Electron/微信/WebView）。
EDIT_WINDOW_CLASSES = (
    "chrome_widgetwin_1", "chrome_widgetwin_0",        # Chrome / Edge / Electron
    "mozillawindowclass", "mozilla hidden window", "mozillahiddenwindow",
    "applicationsframewindow",                          # Firefox
    "wechatmainwndforpc", "timwindowclass",             # 微信 / QQ
    "sunawtframe",                                      # Java/AWT 自绘界面
    "obsidianmainwnd", "claudedesktop", "fernflowerwndclass",
    "webview", "webview2", "msedgewebview2",
)

# 焦点控件类名里的**编辑类**（正向，子串匹配）
EDIT_FOCUS_SUBSTRINGS = (
    "edit", "richedit", "textbox", "textinput", "textfield", "textarea",
    "inputbox", "scintilla", "_wwg", "windowsforms10.edit", "msctls_edit",
    "editor", "monaco", "richtext", "webbrowser", "internet explorer_server",
    "htmlview", "docview", "tsfinput", "imeedit",
)

# 自绘界面的正向 token（顶层窗口类名带版本号的变体，如 Qt5152QWindowIcon）
EDIT_CLASS_TOKENS = ("chrome_widgetwin", "mozillawindowclass", "webview",
                     "applicationframe", "claudedesktop", "obsidianmainwnd")

# caret（hwndCaret / rcCaret）**不参与判定**，只写进日志。实测它两头都不准：
# 记事本里是 (24,24,25,52)，Tk 里是 (104,8,105,9)，桌面/任务栏上还会留一个
# (3,0,4,9) 的陈旧矩形；而且「有 caret」和「能接收注入」本来就是两件事
# （浏览器正文没有 caret）。它最多只能把 unknown 抬成 edit，而这两者处理相同，
# 所以对决策毫无影响 —— 留着只会让人误以为它有用。


def make_guithreadinfo():
    """GUITHREADINFO 结构（仅 Windows 下可构造）。"""
    import ctypes
    import ctypes.wintypes as wt

    class GUITHREADINFO(ctypes.Structure):
        _fields_ = [("cbSize", wt.DWORD), ("flags", wt.DWORD),
                    ("hwndActive", wt.HWND), ("hwndFocus", wt.HWND),
                    ("hwndCapture", wt.HWND), ("hwndMenuOwner", wt.HWND),
                    ("hwndMoveSize", wt.HWND), ("hwndCaret", wt.HWND),
                    ("rcCaret", wt.RECT)]

    return GUITHREADINFO()


def _low(name):
    return (name or "").strip().lower()


def judge_focus_target(fg_cls, focus_cls, focus_hwnd, known_window_class=True,
                       uia=None):
    """返回 FOCUS_EDIT / FOCUS_NONEDIT / FOCUS_UNKNOWN（纯函数，无副作用）。

    参数：顶层窗口类名、焦点控件类名、有没有焦点控件、类名是否读到了，
    外加 **UI Automation 的判定** `uia`（`voice_overlay_uia.decide()` 的结果，
    取值 FOCUS_EDIT / FOCUS_NONEDIT / FOCUS_UNKNOWN / None）。

    UIA 补的正是类名表最大的两个盲区（实测数据见 `voice_overlay_uia.py`）：
    浏览器页面里**没有聚焦任何输入框**（前台类名 Chrome_WidgetWin_1 在正判白名单里，
    旧逻辑一律判 edit -> 字打进空气、也拿不到「已复制」），以及微信/QQ 这类自绘窗口。

    判定顺序：

    1. **顶层窗口类名**命中「绝无可编辑区」名单（桌面/任务栏/终端/控制台）
       -> NONEDIT。优先级最高，也高于「拿不到焦点控件」：实测焦点在桌面/任务栏时
       会拿回来一个**陈旧**的 hwndFocus，不加这道闸就会把一次误判放大成
       「点了桌面也照抄剪贴板」；
    2. **UIA 说能输入**（Edit，或**可写的** Document —— 记事本的编辑区就是 Document）
       -> EDIT。排在类名正判之前：它是直接问系统「谁拿着焦点」，比类名可靠；
    3. **UIA 说收不了文字**（只读 Document、Button/ListItem/Text…）-> NONEDIT；
    4. 拿不到焦点控件（focus_hwnd == 0）-> UNKNOWN；
    5. **顶层窗口类名**命中「自绘界面默认有可编辑区」白名单 -> EDIT。必须排在
       「焦点控件类名的负判」之前：Chrome 地址栏等非编辑控件的类名无法枚举，
       而这些顶层窗口里确实有可编辑区，先判负会让浏览器里说话永远走复制分支；
    6. 焦点控件类名命中编辑类（Edit/RichEdit/TextBox/Scintilla/_WwG…）-> EDIT。
       实测：真有个可编辑控件拿到焦点时，hwndFocus 一定是它、绝不是顶层窗口；
    7. 焦点控件类名命中死物名单（Button/Static/TrayNotifyWnd/DirectUIHWND/TkChild…）
       -> NONEDIT；
    8. 焦点控件类名命中自绘白名单 / 正向 token -> EDIT；
    9. 其余 -> UNKNOWN（**没有正向证据**；最终要不要复制由 `wants_copy()` 定）。
    """
    focus_cls_l = _low(focus_cls)
    fg_cls_l = _low(fg_cls)

    if known_window_class and fg_cls_l in NONEDIT_WINDOW_CLASSES:
        return FOCUS_NONEDIT
    if uia == FOCUS_EDIT:
        return FOCUS_EDIT
    if uia == FOCUS_NONEDIT:
        return FOCUS_NONEDIT
    if not focus_hwnd:
        return FOCUS_UNKNOWN
    if fg_cls_l in EDIT_WINDOW_CLASSES:
        return FOCUS_EDIT
    for sub in EDIT_FOCUS_SUBSTRINGS:
        if sub in focus_cls_l:
            return FOCUS_EDIT
    if focus_cls_l in NONEDIT_FOCUS_CLASSES:
        return FOCUS_NONEDIT
    if focus_cls_l in EDIT_WINDOW_CLASSES:
        return FOCUS_EDIT
    for sub in EDIT_CLASS_TOKENS:
        if sub in focus_cls_l:
            return FOCUS_EDIT
    return FOCUS_UNKNOWN


def wants_copy(state, uia_available):
    """最终策略：**非输入框就复制**（用户要求：「所有」非输入框场景都要复制）。

    为什么需要单独一个函数：`judge_focus_target` 只回答「有没有正向证据」，
    而「没有证据时该注入还是该复制」是**策略**，不是判定。分开写才能让
    selftest 把两种情形都钉住。

    * `FOCUS_NONEDIT` -> 复制。这是明确的负判。
    * `FOCUS_UNKNOWN` + **UIA 这次是好的** -> 复制。UIA 会直接告诉你
      「现在拿着焦点的是窗口/面板本身，不是一个能输入的元素」
      （ControlType 落在 Pane/Window/Group/Custom），这就是「没有输入框」。
      用户要的是「所有非输入框都复制」，所以这里不再照旧注入。
    * `FOCUS_UNKNOWN` + **UIA 完全不可用**（模块没导入 / CoCreateInstance 失败）
      -> 不复制，维持老行为注入。这一条是**防呆**：UIA 挂掉时若一律复制，
      等于所有软件里打字都变成静默复制，比偶尔打空严重得多。
    * `FOCUS_EDIT` -> 不复制。
    """
    if state == FOCUS_NONEDIT:
        return True
    if state == FOCUS_UNKNOWN:
        return bool(uia_available)
    return False
