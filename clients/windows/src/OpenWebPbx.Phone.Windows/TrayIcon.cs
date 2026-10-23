// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Runtime.InteropServices;
namespace OpenWebPbx.Phone.Windows;
/// <summary>Resident registration remains alive when the window is hidden. Fully exited apps cannot receive calls.</summary>
public sealed class TrayIcon : IDisposable
{
    private const uint Callback = 0x8001;
    private readonly Action show, exit, locked, resumed;
    private readonly WindowProc callback;
    private readonly IntPtr window, icon;
    private readonly string className = "OpenWebPBXPhoneTray" + Guid.NewGuid().ToString("N");
    private bool disposed;
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr WindowProc(IntPtr h, uint message, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct WindowClass { public uint cbSize, style; public WindowProc lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string? lpszMenuName; public string lpszClassName; public IntPtr hIconSm; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct NotifyData { public uint Size; public IntPtr Window; public uint Id, Flags, CallbackMessage; public IntPtr Icon; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip; public uint State, StateMask; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info; public uint Timeout; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle; public uint InfoFlags; public Guid Guid; public IntPtr BalloonIcon; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern ushort RegisterClassEx(ref WindowClass c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr module, IntPtr param);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool UnregisterClass(string name, IntPtr instance);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadImage(IntPtr module, string path, uint type, int w, int h, uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint message, ref NotifyData data);
    [DllImport("wtsapi32.dll")] private static extern bool WTSRegisterSessionNotification(IntPtr h, uint flags);
    [DllImport("wtsapi32.dll")] private static extern bool WTSUnRegisterSessionNotification(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr owner, IntPtr rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    public TrayIcon(string iconPath, Action show, Action exit, Action locked, Action resumed)
    {
        this.show = show; this.exit = exit; this.locked = locked; this.resumed = resumed; callback = Process;
        var cls = new WindowClass { cbSize = (uint)Marshal.SizeOf<WindowClass>(), lpfnWndProc = callback, lpszClassName = className };
        if (RegisterClassEx(ref cls) == 0) throw new InvalidOperationException("Tray window could not be registered.");
        window = CreateWindowEx(0, className, "", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        icon = LoadImage(IntPtr.Zero, iconPath, 1, 32, 32, 0x10); if (window == IntPtr.Zero || icon == IntPtr.Zero) { Dispose(); throw new InvalidOperationException("Tray icon could not be created."); }
        var data = Data(); if (!Shell_NotifyIcon(0, ref data)) { Dispose(); throw new InvalidOperationException("Tray icon could not be shown."); } WTSRegisterSessionNotification(window, 0);
    }
    private NotifyData Data() => new() { Size = (uint)Marshal.SizeOf<NotifyData>(), Window = window, Id = 1, Flags = 1 | 2 | 4, CallbackMessage = Callback, Icon = icon, Tip = "OpenWebPBX Free Phone · Double-click to open", Info = "", InfoTitle = "" };
    private IntPtr Process(IntPtr h, uint message, IntPtr w, IntPtr l)
    {
        try
        {
            if (message == Callback && ((long)l & 0xffff) == 0x203) show();
            if (message == Callback && ((long)l & 0xffff) == 0x205)
            {
                var menu = CreatePopupMenu(); try { AppendMenu(menu, 0, 1, "Open phone"); AppendMenu(menu, 0, 2, "Exit"); GetCursorPos(out var point); SetForegroundWindow(window); var choice = TrackPopupMenu(menu, 0x100 | 0x2, point.X, point.Y, 0, window, IntPtr.Zero); if (choice == 1) show(); if (choice == 2) exit(); } finally { DestroyMenu(menu); }
            }
            if (message == 0x2b1 && w.ToInt64() == 7) locked();
            if (message == 0x218 && w.ToInt64() is 7 or 18) resumed();
        }
        catch { /* Never let a managed exception cross the native window procedure. */ }
        return DefWindowProc(h, message, w, l);
    }
    public void Dispose() { if (disposed) return; disposed = true; if (window != IntPtr.Zero) { var data = Data(); Shell_NotifyIcon(2, ref data); WTSUnRegisterSessionNotification(window); DestroyWindow(window); } if (icon != IntPtr.Zero) DestroyIcon(icon); UnregisterClass(className, IntPtr.Zero); GC.KeepAlive(callback); }
}
