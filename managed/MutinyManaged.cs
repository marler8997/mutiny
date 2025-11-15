using System;
using System.IO;
using System.Runtime.InteropServices;

namespace MarlerMod
{
    public class ModLoader
    {
        // Import the native log function from our DLL
        [DllImport("MarlerMod.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void NativeLog(string message);

        public static void Initialize()
        {
            try
            {
                // Write to console (if available)
                Console.WriteLine("MarlerMod.ModLoader.Initialize() called!");

                // Write to a file
                File.AppendAllText(@"C:\temp\marlermod-managed.log",
                    DateTime.Now.ToString("HH:mm:ss.fff") + " | MarlerMod managed code initialized!\n");

                // Call back to native code
                NativeLog("Hello from managed C# code!");

                Console.WriteLine("Managed initialization complete!");
            }
            catch (Exception ex)
            {
                string error = "Exception in Initialize: " + ex.ToString();
                try
                {
                    File.AppendAllText(@"C:\temp\marlermod-managed.log", error + "\n");
                }
                catch { }
            }
        }
    }
}
