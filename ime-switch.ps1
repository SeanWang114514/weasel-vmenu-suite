param(
  [ValidateSet('query','activate-weasel','activate-pinyin')]
  [string]$Action = 'query'
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("1F02B6C5-7842-4EE6-8A0B-9A24183A95CA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITfInputProcessorProfiles {
    void Register();
    void Unregister();
    void AddLanguageProfile(ref Guid rclsid, ushort langid, ref Guid guidProfile,
        [MarshalAs(UnmanagedType.LPWStr)] string pchDesc, uint cchDesc,
        [MarshalAs(UnmanagedType.LPWStr)] string pchIconFile, uint cchFile, uint uIconIndex);
    void RemoveLanguageProfile(ref Guid rclsid, ushort langid, ref Guid guidProfile);
    void EnumInputProcessorInfo(out IntPtr ppEnum);
    void GetDefaultLanguageProfile(ushort langid, ref Guid catid, out Guid pclsid, out Guid pguidProfile);
    void SetDefaultLanguageProfile(ushort langid, ref Guid rclsid, ref Guid guidProfiles);
    void ActivateLanguageProfile(ref Guid rclsid, ushort langid, ref Guid guidProfiles);
    void GetActiveLanguageProfile(ref Guid rclsid, ushort langid, out Guid pguidProfile);
}

public static class TsfIme {
    static readonly Guid CLSID_Profiles = new Guid("33C53A50-F456-4884-B049-85FD643ECFED");
    public static readonly Guid Weasel   = new Guid("A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A");
    public static readonly Guid WeaselPf = new Guid("3D02CAB6-2B8E-4781-BA20-1C9267529467");
    public static readonly Guid Pinyin   = new Guid("86598FB9-66A2-463E-B9C2-AEB906D477AD");
    public static readonly Guid PinyinPf = new Guid("607FDF85-FCC8-4DBD-A365-41296F980C9C");
    static readonly ushort ZH = 0x0804;

    static ITfInputProcessorProfiles GetProfiles() {
        return (ITfInputProcessorProfiles)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_Profiles));
    }

    public static string Query(Guid clsid) {
        var p = GetProfiles();
        Guid prof = Guid.Empty;
        p.GetActiveLanguageProfile(ref clsid, ZH, out prof);
        return prof.ToString();
    }

    public static void Activate(Guid clsid, Guid profile) {
        var p = GetProfiles();
        Guid c = clsid, g = profile;
        p.ActivateLanguageProfile(ref c, ZH, ref g);
    }
}
"@

switch ($Action) {
  'query' {
    "WEASEL_ACTIVE_PROFILE = $([TsfIme]::Query([TsfIme]::Weasel))"
    "PINYIN_ACTIVE_PROFILE = $([TsfIme]::Query([TsfIme]::Pinyin))"
  }
  'activate-weasel' {
    [TsfIme]::Activate([TsfIme]::Weasel, [TsfIme]::WeaselPf)
    Start-Sleep -Milliseconds 500
    "AFTER: WEASEL_ACTIVE_PROFILE = $([TsfIme]::Query([TsfIme]::Weasel))"
  }
  'activate-pinyin' {
    [TsfIme]::Activate([TsfIme]::Pinyin, [TsfIme]::PinyinPf)
    Start-Sleep -Milliseconds 500
    "AFTER: PINYIN_ACTIVE_PROFILE = $([TsfIme]::Query([TsfIme]::Pinyin))"
  }
}
