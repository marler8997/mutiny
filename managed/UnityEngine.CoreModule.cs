// A stand-in for the real UnityEngine.CoreModule.dll, enough to compile against: only the
// assembly name and the type names matter, since mono binds the reference by name to the copy
// the game has already loaded.
namespace UnityEngine
{
    public class Object { }
    public class Component : Object { }
    public class Behaviour : Component { }
    public class MonoBehaviour : Behaviour { }
}
