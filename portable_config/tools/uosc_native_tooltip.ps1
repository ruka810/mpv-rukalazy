param(
    [ValidateSet('launch', 'server')]
    [string]$Mode,
    [string]$PipeName,
    [int]$OwnerPid = 0
)

$ErrorActionPreference = 'Stop'

if ($Mode -eq 'launch') {
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode server -PipeName `"$PipeName`" -OwnerPid $OwnerPid"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing', 'System.Web.Extensions' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public sealed class UoscTooltipForm : Form
{
    private const int WM_MOUSEACTIVATE = 0x0021;
    private const int WM_NCHITTEST = 0x0084;
    private const int MA_NOACTIVATE = 3;
    private const int HTTRANSPARENT = -1;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;

    public Label TextLabel { get; private set; }
    private Font ownedTextFont;
    private float ownedTextFontSize;

    public UoscTooltipForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(22, 22, 22);
        Opacity = 0.96;
        // Keep the tooltip above its mpv owner without making it a global
        // topmost window. A global topmost helper can participate in Windows'
        // foreground arbitration when menus are opened or hovered.
        TopMost = false;
        TextLabel = new Label();
        TextLabel.AutoSize = false;
        TextLabel.ForeColor = Color.FromArgb(245, 245, 245);
        TextLabel.BackColor = BackColor;
        TextLabel.TextAlign = ContentAlignment.TopLeft;
        TextLabel.UseCompatibleTextRendering = false;
        Controls.Add(TextLabel);
    }

    public void SetTextFont(float pointSize)
    {
        if (ownedTextFont != null && Math.Abs(ownedTextFontSize - pointSize) < 0.01f) return;

        Font nextFont;
        try { nextFont = new Font("Microsoft YaHei UI", pointSize, FontStyle.Italic, GraphicsUnit.Point); }
        catch { nextFont = new Font(FontFamily.GenericSansSerif, pointSize, FontStyle.Italic, GraphicsUnit.Point); }

        Font previousFont = ownedTextFont;
        ownedTextFont = nextFont;
        ownedTextFontSize = pointSize;
        TextLabel.Font = nextFont;
        if (previousFont != null) previousFont.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && ownedTextFont != null)
        {
            ownedTextFont.Dispose();
            ownedTextFont = null;
        }
        base.Dispose(disposing);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return parameters;
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_MOUSEACTIVATE)
        {
            message.Result = (IntPtr)MA_NOACTIVATE;
            return;
        }
        if (message.Msg == WM_NCHITTEST)
        {
            message.Result = (IntPtr)HTTRANSPARENT;
            return;
        }
        base.WndProc(ref message);
    }
}

public sealed class UoscWindowOwner : IWin32Window
{
    public IntPtr Handle { get; private set; }
    public UoscWindowOwner(IntPtr handle) { Handle = handle; }
}

public static class UoscNativeTooltip
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const uint GA_ROOT = 2;

    public static void Run(string pipeName, int ownerPid)
    {
        EnableDpiAwareness();
        Application.EnableVisualStyles();
        var form = new UoscTooltipForm();
        IntPtr unusedHandle = form.Handle;

        var context = new ApplicationContext();
        form.FormClosed += delegate { context.ExitThread(); };
        Process ownerProcess = WatchOwnerExit(ownerPid, form);
        Task.Factory.StartNew(delegate { Serve(pipeName, form); }, TaskCreationOptions.LongRunning);
        Application.Run(context);
        if (ownerProcess != null) ownerProcess.Dispose();
    }

    private static void EnableDpiAwareness()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { try { SetProcessDPIAware(); } catch { } }
    }

    private static Process WatchOwnerExit(int ownerPid, UoscTooltipForm form)
    {
        if (ownerPid <= 0) return null;
        try
        {
            Process owner = Process.GetProcessById(ownerPid);
            owner.EnableRaisingEvents = true;
            owner.Exited += delegate
            {
                try
                {
                    if (!form.IsDisposed) form.BeginInvoke((Action)delegate { form.Close(); });
                }
                catch { }
            };
            return owner;
        }
        catch { return null; }
    }

    private static IntPtr GetRootWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        IntPtr root = GetAncestor(hwnd, GA_ROOT);
        return root == IntPtr.Zero ? hwnd : root;
    }

    private static void Serve(string pipeName, UoscTooltipForm form)
    {
        var serializer = new JavaScriptSerializer();
        while (!form.IsDisposed)
        {
            try
            {
                using (var pipe = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.None))
                {
                    pipe.WaitForConnection();
                    using (var reader = new StreamReader(pipe, Encoding.ASCII))
                    {
                        string encoded = reader.ReadLine();
                        if (String.IsNullOrEmpty(encoded)) continue;
                        string json = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
                        var data = serializer.Deserialize<Dictionary<string, object>>(json);
                        form.BeginInvoke((Action)delegate { Apply(form, data); });
                    }
                }
            }
            catch
            {
                if (form.IsDisposed) return;
            }
        }
    }

    private static void Apply(UoscTooltipForm form, Dictionary<string, object> data)
    {
        string command = StringValue(data, "command");
        if (command == "shutdown")
        {
            form.Close();
            return;
        }
        if (command == "hide")
        {
            form.Hide();
            return;
        }
        if (command != "show") return;

        long rawHandle;
        if (!Int64.TryParse(StringValue(data, "window_id"), out rawHandle))
        {
            form.Hide();
            return;
        }
        IntPtr renderHwnd = new IntPtr(rawHandle);
        IntPtr ownerHwnd = GetRootWindow(renderHwnd);
        RECT client;
        POINT origin = new POINT();
        if (renderHwnd == IntPtr.Zero || ownerHwnd == IntPtr.Zero || IsIconic(ownerHwnd) ||
            !GetClientRect(renderHwnd, out client) || !ClientToScreen(renderHwnd, ref origin))
        {
            form.Hide();
            return;
        }

        int osdWidth = Math.Max(1, NumberValue(data, "osd_width"));
        int osdHeight = Math.Max(1, NumberValue(data, "osd_height"));
        float scaleX = (client.Right - client.Left) / (float)osdWidth;
        float scaleY = (client.Bottom - client.Top) / (float)osdHeight;
        int right = origin.X + (int)Math.Round(NumberValue(data, "right") * scaleX);
        int left = origin.X + (int)Math.Round(NumberValue(data, "left") * scaleX);
        int top = origin.Y + (int)Math.Round(NumberValue(data, "top") * scaleY);
        string text = StringValue(data, "text");
        if (String.IsNullOrEmpty(text))
        {
            form.Hide();
            return;
        }

        Rectangle screen = Screen.FromPoint(new Point(right, top)).Bounds;
        float pointSize = Math.Max(9.0f, NumberValue(data, "font_size") * Math.Max(scaleX, scaleY) * 0.72f);
        form.SetTextFont(pointSize);

        int padding = Math.Max(10, (int)Math.Round(10 * Math.Max(scaleX, scaleY)));
        int maxWidth = Math.Min(520, Math.Max(220, screen.Width / 3));
        TextFormatFlags textFlags = TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl;
        Size measured = TextRenderer.MeasureText(text, form.TextLabel.Font,
            new Size(maxWidth - padding * 2, Int32.MaxValue), textFlags);
        int width = Math.Min(maxWidth, Math.Max(180, measured.Width + padding * 2));
        Size wrapped = TextRenderer.MeasureText(text, form.TextLabel.Font,
            new Size(width - padding * 2, Int32.MaxValue), textFlags);
        int height = Math.Max((int)Math.Round(30 * Math.Max(scaleX, scaleY)), wrapped.Height + padding * 2);

        int x = right;
        if (x + width > screen.Right) x = left - width;
        x = Math.Max(screen.Left, Math.Min(x, screen.Right - width));
        int y = Math.Max(screen.Top, Math.Min(top, screen.Bottom - height));

        form.Size = new Size(width, height);
        form.TextLabel.Location = new Point(padding, padding);
        form.TextLabel.Size = new Size(width - padding * 2, height - padding * 2);
        form.TextLabel.Text = text;
        if (!form.Visible) form.Show(new UoscWindowOwner(ownerHwnd));
        SetWindowPos(form.Handle, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    private static int NumberValue(Dictionary<string, object> data, string key)
    {
        object value;
        if (!data.TryGetValue(key, out value) || value == null) return 0;
        try { return Convert.ToInt32(value); }
        catch { return 0; }
    }

    private static string StringValue(Dictionary<string, object> data, string key)
    {
        object value;
        return data.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : String.Empty;
    }
}
'@

[UoscNativeTooltip]::Run($PipeName, $OwnerPid)
