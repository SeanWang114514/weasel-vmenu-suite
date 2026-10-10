# -*- coding: utf-8 -*-
"""UI Automation 焦点判定：问系统「现在有焦点的那个元素能不能接收文字」。

为什么需要它（现有类名表的两大盲区，都是实测出来的）：

1. **浏览器页面里没有聚焦任何输入框**（最常见）。前台窗口类名是
   `Chrome_WidgetWin_1`，而它在类名表里是「这个窗口里默认有可编辑区」的正判名单
   —— 于是一律判 edit、照旧注入，字打进空气里，用户白说一遍、也拿不到「已复制」。
2. 微信 / QQ / 钉钉这类自绘窗口，类名表根本认不出来。

UIA 能直接回答这个问题，和窗口类名无关。实测（`tmp/probe-uia3.py` / `probe-uia4.py`）：

| 场景 | ControlType | ValueIsReadOnly | 结论 |
| --- | --- | --- | --- |
| 记事本编辑区 | Document(50030) | **False** | 能 |
| Chrome 地址栏 | Edit(50004) | — | 能 |
| 页面里的 `<input>` | Edit(50004) | — | 能 |
| Chrome 空白页面 | Document(50030) | **True** | 不能 |
| 桌面 | ListItem(50007) | True | 不能 |
| Chrome 菜单按钮 | Button(50000) | True | 不能 |

**关键的一条**：记事本的编辑区是 `Document` 而不是 `Edit`。所以不能见到 Document
就判「不能」——必须再看 `ValueIsReadOnly`。否则在记事本里说话会被误判成复制，
比现在更糟。这是这个模块唯一容易做错的地方。

用纯 ctypes 调 COM（不引入 comtypes / pywinauto 依赖）：`UIAutomationCore.dll`
是系统自带，`CoCreateInstance(CLSID_CUIAutomation)` 就能拿到 `IUIAutomation`。
"""
import ctypes
import ctypes.wintypes as wt
import threading
import uuid

# ------------------------------------------------------------------ 常量
HRESULT = ctypes.c_long

CLSCTX_ALL = 0x17
COINIT_MULTITHREADED = 0x0

# 属性 ID
P_CONTROLTYPE = 30003
P_NAME = 30005
P_CLASSNAME = 30012
P_ISKEYFOCUSABLE = 30009
P_HASKEYFOCUS = 30008
P_VALUEISREADONLY = 30046

VT_I4, VT_BSTR, VT_BOOL = 3, 8, 11

# ControlType ID
CT_EDIT = 50004
CT_DOCUMENT = 50030
CT_TEXT = 50020
CT_PANE = 50033
CT_WINDOW = 50032
CT_GROUP = 50026
CT_CUSTOM = 50025

CT_NAMES = {
    50000: "Button", 50001: "Calendar", 50002: "CheckBox", 50003: "ComboBox",
    50004: "Edit", 50005: "Hyperlink", 50006: "Image", 50007: "ListItem",
    50008: "List", 50009: "Menu", 50010: "MenuBar", 50011: "MenuItem",
    50012: "ProgressBar", 50013: "RadioButton", 50014: "ScrollBar",
    50015: "Slider", 50016: "Spinner", 50017: "StatusBar", 50018: "Tab",
    50019: "TabItem", 50020: "Text", 50021: "ToolBar", 50022: "ToolTip",
    50023: "Tree", 50024: "TreeItem", 50025: "Custom", 50026: "Group",
    50027: "Thumb", 50028: "DataGrid", 50029: "DataItem", 50030: "Document",
    50031: "SplitButton", 50032: "Window", 50033: "Pane", 50034: "Header",
    50035: "HeaderItem", 50036: "Table", 50037: "TitleBar", 50038: "Separator",
    50039: "SemanticZoom", 50040: "AppBar",
}

# 「结构容器」：这些类型说明**焦点不在某个具体控件上**（在窗口/面板/分组本身）。
# 它们既不能证明「能输入」也不能证明「不能输入」，交给调用方的类名表继续判。
STRUCTURAL_CTS = (CT_PANE, CT_WINDOW, CT_GROUP, CT_CUSTOM)

# 其余所有非 Edit/Document 的类型都是「确定收不了文字」的死物（Button/Text/
# ListItem/Image/ScrollBar/MenuItem/TabItem/Thumb/ToolBar/StatusBar/…）。

EDIT = "edit"            # 确定能输入
NONEDIT = "nonedit"      # 确定收不了文字
UNKNOWN = "unknown"      # 说不准（结构容器 / 读不到）


class GUID(ctypes.Structure):
    _fields_ = [("Data1", wt.DWORD), ("Data2", wt.WORD), ("Data3", wt.WORD),
                ("Data4", ctypes.c_byte * 8)]


def _guid(s):
    return GUID.from_buffer_copy(uuid.UUID(s).bytes_le)


_CLSID_UIA = _guid("ff48dba4-60ef-4201-aa87-54103eef594e")
_IID_UIA = _guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")


class _VUNION(ctypes.Union):
    _fields_ = [("llVal", ctypes.c_longlong), ("lVal", ctypes.c_long),
                ("bstrVal", ctypes.c_void_p), ("punkVal", ctypes.c_void_p)]


class VARIANT(ctypes.Structure):
    _fields_ = [("vt", ctypes.c_ushort), ("r1", ctypes.c_ushort),
                ("r2", ctypes.c_ushort), ("r3", ctypes.c_ushort), ("val", _VUNION)]


# ------------------------------------------------- 纯决策（selftest 直接测它）
def decide(control_type, value_readonly):
    """把 UIA 的 (ControlType, ValueIsReadOnly) 映射成 edit/nonedit/unknown。

    **纯函数**，不碰 Windows —— selftest 与回归测试跑的就是实机用的这一份。
    """
    if control_type is None:
        return UNKNOWN
    if control_type == CT_EDIT:
        return EDIT
    if control_type == CT_DOCUMENT:
        # 记事本的编辑区就是 Document！只读标志才是分水岭：
        #   可写 Document（记事本、Word 正文）-> 能输入
        #   只读 Document（浏览器页面正文）  -> 收不了文字
        if value_readonly is False:
            return EDIT
        if value_readonly is True:
            return NONEDIT
        return UNKNOWN                      # 读不到只读标志 -> 不敢下结论
    if control_type in STRUCTURAL_CTS:
        return UNKNOWN                      # 焦点在窗口/面板本身，交给类名表
    return NONEDIT                          # 其余全是死物


# ------------------------------------------------------------------ COM 管道
class _Uia:
    """每个线程一份 IUIAutomation（COM 对象是单元线程绑定的）。"""

    def __init__(self):
        import ctypes as c
        self.ole32 = c.windll.ole32
        self.oleaut32 = c.windll.oleaut32
        self.ole32.CoCreateInstance.argtypes = [
            c.POINTER(GUID), c.c_void_p, wt.DWORD, c.POINTER(GUID),
            c.POINTER(c.c_void_p)]
        self.ole32.CoCreateInstance.restype = HRESULT
        self.ole32.CoInitializeEx.argtypes = [c.c_void_p, wt.DWORD]
        self.ole32.CoInitializeEx.restype = HRESULT
        self.ptr = None

    def open(self):
        self.ole32.CoInitializeEx(None, COINIT_MULTITHREADED)
        p = ctypes.c_void_p()
        hr = self.ole32.CoCreateInstance(
            ctypes.byref(_CLSID_UIA), None, CLSCTX_ALL,
            ctypes.byref(_IID_UIA), ctypes.byref(p))
        if hr != 0 or not p.value:
            return False
        self.ptr = p
        return True

    def _vt(self, punk, index, restype=HRESULT, *extra):
        tbl = ctypes.cast(punk, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)))
        return ctypes.WINFUNCTYPE(restype, ctypes.c_void_p, *extra)(tbl.contents[index])

    def release(self, p):
        if p:
            try:
                self._vt(p, 2, ctypes.c_ulong)(p)
            except Exception:
                pass

    def _bstr(self, p):
        if not p:
            return ""
        s = ctypes.wstring_at(p)
        self.oleaut32.SysFreeString(ctypes.c_void_p(p))
        return s

    def _prop(self, el, pid):
        v = VARIANT()
        hr = self._vt(el, 10, HRESULT, ctypes.c_int,
                      ctypes.POINTER(VARIANT))(el, pid, ctypes.byref(v))
        if hr != 0:
            return None
        if v.vt == VT_I4:
            return v.val.lVal
        if v.vt == VT_BOOL:
            return bool(v.val.lVal)
        if v.vt == VT_BSTR:
            return self._bstr(v.val.bstrVal)
        return None

    def focused_facts(self):
        """取焦点元素的事实；拿不到返回 None。"""
        el = ctypes.c_void_p()
        hr = self._vt(self.ptr, 8, HRESULT,
                      ctypes.POINTER(ctypes.c_void_p))(self.ptr, ctypes.byref(el))
        if hr != 0 or not el.value:
            return None
        try:
            return {
                "ct": self._prop(el, P_CONTROLTYPE),
                "cls": self._prop(el, P_CLASSNAME) or "",
                "name": self._prop(el, P_NAME) or "",
                "readonly": self._prop(el, P_VALUEISREADONLY),
                "keyfocus": self._prop(el, P_ISKEYFOCUSABLE),
                "hasfocus": self._prop(el, P_HASKEYFOCUS),
            }
        finally:
            self.release(el)


# 线程本地：COM 对象不能跨线程用
_local = threading.local()


def _worker_facts():
    u = getattr(_local, "uia", None)
    if u is None:
        u = _Uia()
        _local.uia = u
        if not u.open():
            _local.uia = None
            return None
    try:
        return u.focused_facts()
    except Exception:
        _local.uia = None                   # 坏了就下次重建
        return None


def focused_verdict(timeout=0.5):
    """返回 `(verdict, facts)`；verdict ∈ edit/nonedit/unknown。

    **必须在独立线程里跑并设超时**：UIA 要问目标进程的 provider，那个进程卡住时
    调用会一直挂着。这个函数在悬浮球的 UI 线程里被调用，挂住 = 悬浮球整个冻住。
    实测正常耗时 5~30ms，超时给 0.5s 已经很宽松。
    """
    box = {}

    def run():
        try:
            box["f"] = _worker_facts()
        except Exception as e:              # pragma: no cover
            box["err"] = repr(e)

    th = threading.Thread(target=run, daemon=True)
    th.start()
    th.join(timeout)
    if th.is_alive():
        return UNKNOWN, {"err": "timeout>%.1fs" % timeout}
    f = box.get("f")
    if not f:
        return UNKNOWN, {"err": box.get("err") or "no focused element"}
    return decide(f.get("ct"), f.get("readonly")), f


def _selftest():
    """纯逻辑自检（不需要真窗口）。"""
    n = 0
    # Edit 永远是能输入（地址栏、页面里的 input）
    assert decide(CT_EDIT, None) == EDIT; n += 1
    assert decide(CT_EDIT, True) == EDIT; n += 1
    # Document：只读标志是分水岭 —— 记事本(可写) vs 浏览器页面(只读)
    assert decide(CT_DOCUMENT, False) == EDIT; n += 1
    assert decide(CT_DOCUMENT, True) == NONEDIT; n += 1
    assert decide(CT_DOCUMENT, None) == UNKNOWN; n += 1
    # 结构容器 -> 交给类名表
    for ct in STRUCTURAL_CTS:
        assert decide(ct, None) == UNKNOWN; n += 1
    # 死物 -> 不能输入
    for ct in (50000, 50020, 50007, 50006, 50014, 50011, 50019, 50027, 50017):
        assert decide(ct, None) == NONEDIT; n += 1
    # 拿不到 -> unknown（不猜）
    assert decide(None, None) == UNKNOWN; n += 1
    print("uia selftest OK (%d)" % n)
    return 0


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    v, f = focused_verdict()
    print("verdict=%s" % v)
    for k, val in sorted(f.items()):
        print("   %-9s = %r" % (k, val))
    if isinstance(f.get("ct"), int):
        print("   ControlType = %s(%s)" % (f["ct"], CT_NAMES.get(f["ct"], "?")))
