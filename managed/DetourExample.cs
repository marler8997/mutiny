// How a precompiled C# mod hooks a game method with DetourInstall from Mutiny.dll. dotnet-test runs
// this on each mono runtime, so it stays correct. The Compiled Mods section of the README describes
// the function itself, including which targets it refuses.
//
// Mutiny.dll is injected, so it may not be loaded when a mod starts. Call TryInstall once per frame,
// from a MonoBehaviour's Update for example, until it returns true. A hook takes effect when it's
// installed, so anything the game did before then has already happened.
using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace MutinyExample
{
    // Stands in for a class in the game. NoInlining is only here to keep the example deterministic:
    // a real method may have callers that inlined it, which a hook can't affect.
    public static class Game
    {
        [MethodImpl(MethodImplOptions.NoInlining)]
        public static int Score(int v)
        {
            int result = v;
            for (int i = 0; i < 3; i++) result += i;
            return result;
        }
    }

    public static class DetourExample
    {
        // Runs instead of the target. It has the target's exact signature, with `this` as the first
        // parameter if the target is an instance method (`ref` if it's a struct's).
        static int ScoreHook(int v)
        {
            return ScoreOriginal(v) + 1000;
        }

        // Calling this calls the original. The body never runs, because TryInstall redirects this
        // method to the trampoline. It has to be a real method because Unity's mscorlib stubs out
        // Reflection.Emit, so a caller can't be generated at runtime. Keep the throw: a body as short
        // as `return 0;` is too small to redirect, and by then the target is already hooked.
        [MethodImpl(MethodImplOptions.NoInlining)]
        static int ScoreOriginal(int v)
        {
            throw new InvalidOperationException("detour stub was not redirected");
        }

        // The answers we need to tell apart. The README lists them all.
        const uint ResultOk = 0;
        const uint ResultNotReady = 1;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        delegate uint DetourInstallFunction(IntPtr target, IntPtr hook, out IntPtr trampoline);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr GetModuleHandleW(string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
        static extern IntPtr GetProcAddress(IntPtr module, string name);

        // Why the last TryInstall returned false, for logging.
        public static string Waiting = "";

        static bool failed;

        // Throws the first time it fails for good, then keeps returning false so a caller that runs
        // every frame doesn't throw every frame.
        public static bool TryInstall()
        {
            if (failed) return false;
            try
            {
                return Install();
            }
            catch (Exception e)
            {
                failed = true;
                Waiting = "failed: " + e.Message;
                throw;
            }
        }

        static bool Install()
        {
            // Look it up with GetModuleHandle because a DllImport of Mutiny.dll would search the disk
            // for it. Not loaded yet just means it hasn't been injected yet.
            var mutiny = GetModuleHandleW("Mutiny.dll");
            if (mutiny == IntPtr.Zero)
            {
                Waiting = "Mutiny.dll is not loaded";
                return false;
            }
            var address = GetProcAddress(mutiny, "DetourInstall");
            if (address == IntPtr.Zero)
                throw new InvalidOperationException("this Mutiny.dll has no DetourInstall; update Mutiny");
            var install = (DetourInstallFunction)Marshal.GetDelegateForFunctionPointer(
                address, typeof(DetourInstallFunction));

            IntPtr trampoline;
            var result = install(CodeOf(typeof(Game), "Score"), CodeOf(typeof(DetourExample), "ScoreHook"), out trampoline);
            if (result == ResultNotReady)
            {
                Waiting = "Mutiny does not know the main thread yet";
                return false;
            }
            Check("Score", result);

            // Mutiny doesn't go back to not ready, so this can't answer that.
            IntPtr unused;
            Check("ScoreOriginal", install(CodeOf(typeof(DetourExample), "ScoreOriginal"), trampoline, out unused));
            return true;
        }

        // Every other result is a bug or a target that can't be hooked, so retrying can't help, and
        // installing again wouldn't either. Mutiny's log says why.
        static void Check(string what, uint result)
        {
            if (result != ResultOk)
                throw new InvalidOperationException("DetourInstall on " + what + " answered " + result + ", see Mutiny's log");
        }

        // GetFunctionPointer compiles the method, which can run its class's static constructor. If that
        // constructor throws, the class stays broken for good, so install a hook once the game would
        // have initialized the class anyway.
        static IntPtr CodeOf(Type type, string name)
        {
            const BindingFlags any = BindingFlags.Static | BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            var method = type.GetMethod(name, any);
            if (method.ContainsGenericParameters)
                throw new ArgumentException(name + " is an open generic, and asking for its code aborts mono");
            return method.MethodHandle.GetFunctionPointer();
        }
    }
}
