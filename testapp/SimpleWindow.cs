using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.IO;

class SimpleWindow : Form
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string lpFileName);

    // Mono initialization functions
    [DllImport("mono-2.0-bdwgc.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    static extern void mono_set_dirs(string assembly_dir, string config_dir);

    [DllImport("mono-2.0-bdwgc.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    static extern void mono_set_assemblies_path(string path);

    [DllImport("mono-2.0-bdwgc.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    static extern IntPtr mono_jit_init(string domain_name);

    [DllImport("mono-2.0-bdwgc.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr mono_get_root_domain();

    [DllImport("mono-2.0-bdwgc.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr mono_thread_attach(IntPtr domain);

    public SimpleWindow()
    {
        this.Text = "Simple Window (with Mono)";
        this.Width = 400;
        this.Height = 300;
    }

    static void Log(string message)
    {
        Console.WriteLine(message);
        // try
        // {
        //     File.AppendAllText(@"C:\temp\simplewindow.log", DateTime.Now.ToString("HH:mm:ss.fff") + " | " + message + "\n");
        // }
        // catch { }
    }

    [STAThread]
    static void Main()
    {
        Log("SimpleWindow starting...");

        // Use Unity game's Mono configuration
        string gameRoot = @"C:\Program Files (x86)\Steam\steamapps\common\REPO";
        string assemblyDir = Path.Combine(gameRoot, @"REPO_Data\Managed");
        string monoRoot = Path.Combine(gameRoot, "MonoBleedingEdge");
        string monoDllPath = Path.Combine(monoRoot, @"EmbedRuntime\mono-2.0-bdwgc.dll");
        string configDir = Path.Combine(monoRoot, "etc");

        Log("Assembly dir: " + assemblyDir);
        Log("Config dir: " + configDir);
        Log("Loading Mono DLL: " + monoDllPath);

        IntPtr monoHandle = LoadLibrary(monoDllPath);
        if (monoHandle == IntPtr.Zero)
        {
            Log("ERROR: Failed to load mono-2.0-bdwgc.dll");
            MessageBox.Show("Failed to load mono-2.0-bdwgc.dll", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        Log("Mono DLL loaded: 0x" + monoHandle.ToString("X"));

        // Initialize Mono runtime (like Unity does)
        try
        {
            Log("Calling mono_set_assemblies_path...");
            mono_set_assemblies_path(assemblyDir);

            Log("Calling mono_set_dirs...");
            mono_set_dirs(assemblyDir, configDir);

            // Initialize the JIT and create root domain
            Log("Calling mono_jit_init...");
            IntPtr domain = mono_jit_init("SimpleWindow");

            if (domain == IntPtr.Zero)
            {
                Log("ERROR: mono_jit_init failed!");
                MessageBox.Show("mono_jit_init failed!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            Log("Mono initialized! Domain: 0x" + domain.ToString("X"));

            // Attach the main thread to the domain (important for thread-local storage)
            Log("Attaching main thread to domain...");
            IntPtr thread = mono_thread_attach(domain);
            if (thread == IntPtr.Zero)
            {
                Log("ERROR: mono_thread_attach failed!");
            }
            else
            {
                Log("Main thread attached: 0x" + thread.ToString("X"));
            }

            // Verify we can get the root domain
            IntPtr rootDomain = mono_get_root_domain();
            Log("Root domain: 0x" + rootDomain.ToString("X"));
            Log("Mono runtime is ready!");
            Log("Waiting for DLL injection and assembly loading...");
        }
        catch (Exception ex)
        {
            Log("Exception: " + ex.ToString());
            MessageBox.Show("Mono initialization failed:\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        Application.EnableVisualStyles();
        Application.Run(new SimpleWindow());
    }
}
