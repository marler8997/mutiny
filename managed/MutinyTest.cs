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
