using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Mutiny
{
    public class ModLoader
    {
        // Import the native log function from our DLL
        // [DllImport("Mutiny.dll", CallingConvention = CallingConvention.Cdecl)]
        // private static extern void NativeLog(string message);

        public static void Initialize()
        {
            try {
                // Call back to native code
                // NativeLog("Hello from managed C# code!");
                Console.Error.WriteLine("Managed initialization complete!");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Exception in Initialize: " + ex.ToString());
            }
        }
    }
}
