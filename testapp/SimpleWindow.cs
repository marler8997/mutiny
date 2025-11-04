using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

class SimpleWindow : Form
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("mono-2.0-bdwgc.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr mono_get_root_domain();

    public SimpleWindow()
    {
        this.Text = "Simple Window (with Mono)";
        this.Width = 400;
        this.Height = 300;
    }

    [STAThread]
    static void Main()
    {
        // Load Mono DLL explicitly
        string monoDllPath = @"C:\Program Files (x86)\Steam\steamapps\common\REPO\MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll";
        IntPtr monoHandle = LoadLibrary(monoDllPath);
        if (monoHandle == IntPtr.Zero)
        {
            MessageBox.Show("Failed to load mono-2.0-bdwgc.dll from:\n" + monoDllPath, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        // Try to call a Mono function to ensure it's working
        try
        {
            IntPtr domain = mono_get_root_domain();
            // MessageBox.Show("Mono loaded successfully!\nRoot domain: 0x" + domain.ToString("X"), "Mono Test", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Mono loaded but failed to call function:\n" + ex.Message, "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        Application.EnableVisualStyles();
        Application.Run(new SimpleWindow());
    }
}
