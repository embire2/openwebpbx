// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Runtime.InteropServices;
namespace OpenWebPbx.Phone.Windows;
public sealed class VideoSurface : IDisposable
{
    public IntPtr Handle { get; private set; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool MoveWindow(IntPtr handle, int x, int y, int w, int h, bool repaint);
    public VideoSurface(IntPtr parent, int x, int y, int width, int height)
    {
        Handle = CreateWindowEx(0, "STATIC", "", 0x50000000 | 0x04000000 | 0x02000000, x, y, width, height, parent, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (Handle == IntPtr.Zero) throw new InvalidOperationException("Windows could not create the native video surface.");
    }
    public void Resize(int x, int y, int width, int height) { if (Handle != IntPtr.Zero) MoveWindow(Handle, x, y, width, height, true); }
    public void Dispose() { if (Handle == IntPtr.Zero) return; DestroyWindow(Handle); Handle = IntPtr.Zero; }
}
