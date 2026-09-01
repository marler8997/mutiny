namespace MutinyTest
{
    public class Echo
    {
        public static bool Bool(bool v) { return v; }
        public static sbyte I8(sbyte v) { return v; }
        public static byte U8(byte v) { return v; }
        public static short I16(short v) { return v; }
        public static ushort U16(ushort v) { return v; }
        public static int I32(int v) { return v; }
        public static uint U32(uint v) { return v; }
        public static long I64(long v) { return v; }
        public static ulong U64(ulong v) { return v; }
        public static float F32(float v) { return v; }
        public static double F64(double v) { return v; }
    }

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

        public static Instances New() { return new Instances(); }
        public static Instances NullInstance() { return null; }
        public static string NullString() { return null; }
        public static object NullObject() { return null; }
    }

    public class Constants
    {
        public static ulong U64Max() { return ulong.MaxValue; }
        public static long I64Max() { return long.MaxValue; }
        public static long I64Min() { return long.MinValue; }
        public static float F32Huge() { return 3.4e38f; }
        public static double F64Huge() { return 1e300; }
    }
}
