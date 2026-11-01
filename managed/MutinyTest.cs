// NOTE: this class is mirrored by il2cpptestfixture
public class Test
{
    public static bool EchoBool(bool v) { return v; }
    public static sbyte EchoI8(sbyte v) { return v; }
    public static byte EchoU8(byte v) { return v; }
    public static short EchoI16(short v) { return v; }
    public static ushort EchoU16(ushort v) { return v; }
    public static int EchoI32(int v) { return v; }
    public static uint EchoU32(uint v) { return v; }
    public static long EchoI64(long v) { return v; }
    public static ulong EchoU64(ulong v) { return v; }
    public static float EchoF32(float v) { return v; }
    public static double EchoF64(double v) { return v; }

    public static ulong U64Max() { return ulong.MaxValue; }
    public static long I64Max() { return long.MaxValue; }
    public static long I64Min() { return long.MinValue; }
    public static float F32Huge() { return 3.4e38f; }
    public static double F64Huge() { return 1e300; }

    public static string NullString() { return null; }
    public static object NullObject() { return null; }

    public static int Overload(int v) { return 1; }
    public static int Overload(string v) { return 2; }
    public static int Overload(double v) { return 3; }
    public static int OverloadIntUint(int v) { return 1; }
    public static int OverloadIntUint(uint v) { return 2; }
    public static int OverloadInt32And64(int v) { return 1; }
    public static int OverloadInt32And64(long v) { return 2; }
    public static int EchoEnum(System.DayOfWeek v) { return (int)v; }
    public static int OverloadIntEnum(int v) { return 1; }
    public static int OverloadIntEnum(System.DayOfWeek v) { return 2; }

    public static long TicksOf(System.TimeSpan v) { return v.Ticks; }
    public static long AddTicks(System.TimeSpan a, System.TimeSpan b, int c) { return a.Ticks + b.Ticks + c; }
    public static object EchoObject(object v) { return v; }
    public static int TypeOrString(System.Type v) { return 1; }
    public static int TypeOrString(string v) { return 2; }
    public static int OverloadBoxed(object v) { return 1; }
    public static int OverloadBoxed(System.TimeSpan v) { return 2; }

    public static int[] I32Array() { return new int[] { 10, 20, 30 }; }
    public static string[] StringArray() { return new string[] { "a", "b" }; }
    public static object[] ObjectArray() { return new object[] { System.TimeSpan.FromTicks(5), null }; }
    public static System.TimeSpan[] TimeSpanArray() { return new System.TimeSpan[] { System.TimeSpan.FromTicks(1), System.TimeSpan.FromTicks(2) }; }
    public static int[] NullI32Array() { return null; }
}

namespace MutinyTest
{
    public class Statics
    {
        public static bool BoolField = true;
        public static sbyte I8Field = -8;
        public static byte U8Field = 8;
        public static short I16Field = -16;
        public static ushort U16Field = 16;
        public static int I32Field = -32;
        public static uint U32Field = 32;
        public static long I64Field = -64;
        public static ulong U64Field = 64;
        public static float F32Field = 1.5f;
        public static double F64Field = 3.25;

        public const int ConstI32 = 42;
        public const float ConstF32 = 2.5f;

        public static int[] I32Array = new int[] { 10, 20, 30 };
        public static string[] StringArray = new string[] { "a", "b" };
        public static int[] NullArray = null;

        public static System.TimeSpan SpanField = System.TimeSpan.FromTicks(7);
        public static System.DayOfWeek DayField = System.DayOfWeek.Friday;
        public static string StringField = "static";
        public static string NullStringField = null;

        public static Instances Instance = Instances.New();
    }

    public class Instances
    {
        public bool BoolField = true;
        public sbyte I8Field = -8;
        public byte U8Field = 8;
        public short I16Field = -16;
        public ushort U16Field = 16;
        public int I32Field = -32;
        public uint U32Field = 32;
        public long I64Field = -64;
        public ulong U64Field = 64;
        public float F32Field = 1.5f;
        public double F64Field = 3.25;

        public Instances Inner;
        public System.TimeSpan SpanField = System.TimeSpan.FromTicks(9);
        private string privateString = "private";

        public static Instances New() { return new Instances { Inner = new Instances() }; }
        public static Instances NullInstance() { return null; }
    }

    // Targets for dotnet-test's detour test. NoInlining keeps every call going through the method's
    // entry point, and each target has to compile to at least the 14 bytes the hook overwrites.
    public static class DetourFixture
    {
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int Target(int v)
        {
            int result = v;
            for (int i = 0; i < 3; i++) result += i;
            return result;
        }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int Replacement(int v)
        {
            return Original(v) + 1000;
        }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int Original(int v)
        {
            throw new System.InvalidOperationException("detour stub was not redirected");
        }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int CallTarget(int v) { return Target(v); }

        public const int ThrownByOriginal = 1;
        public const int ThrownByReplacement = 2;
        public const int Caught = -1;

        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int ThrowingTarget(int v)
        {
            if (v == ThrownByOriginal) throw new System.InvalidOperationException("thrown by the original");
            return v;
        }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int ThrowingReplacement(int v)
        {
            if (v == ThrownByReplacement) throw new System.InvalidOperationException("thrown by the replacement");
            return ThrowingOriginal(v);
        }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static int ThrowingOriginal(int v)
        {
            throw new System.InvalidOperationException("detour stub was not redirected");
        }
        public static int CatchFromThrowingTarget(int v)
        {
            try { return ThrowingTarget(v); }
            catch (System.InvalidOperationException) { return Caught; }
        }

        public class Box { public long X; public long Y; }

        // Compiles to a null check early in the prologue, which DetourInstall has to refuse to move.
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static long NullCheckTarget(Box b) { return b.Y + b.X; }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static long NullCheckReplacement(Box b) { return NullCheckOriginal(b); }
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        public static long NullCheckOriginal(Box b)
        {
            throw new System.InvalidOperationException("detour stub was not redirected");
        }
        public static int CatchFromNullCheckTarget(int unused)
        {
            try { return (int)NullCheckTarget(null); }
            catch (System.NullReferenceException) { return Caught; }
        }
    }

    public class Base
    {
        public int BaseMethod() { return 7; }
        public int BaseField = 8;
    }

    public class Derived : Base
    {
        public static Derived New() { return new Derived(); }
    }
}
