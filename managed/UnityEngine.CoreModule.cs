// A stand-in for the real UnityEngine.CoreModule.dll with two jobs.
//
// MutinyMono.dll is compiled against it: only the assembly name and the type names matter for
// that, since in a real game mono binds the reference by name to the copy the game has already
// loaded. Everything here must therefore be shaped like the real thing, and MutinyMono.cs must
// not reference anything that only exists here.
//
// TestGameMono loads it in place of the real one, so the members mutinymono.zig looks up
// (GameObject's constructor, Object.DontDestroyOnLoad, GameObject.AddComponent,
// MonoBehaviour.useGUILayout) have working managed bodies with no engine behind them, and
// TestPlayerLoop is the player loop the test game drives every frame. TestPlayerLoop is test
// only and has no counterpart in Unity.
using System;
using System.Collections.Generic;
using System.Reflection;

namespace UnityEngine
{
    public class Object
    {
        public static void DontDestroyOnLoad(Object target) { }
    }
    public class Component : Object { }
    public class Behaviour : Component { }
    public class MonoBehaviour : Behaviour
    {
        private bool _useGUILayout = true;
        public bool useGUILayout { get { return _useGUILayout; } set { _useGUILayout = value; } }
    }
    public class GameObject : Object
    {
        public Component AddComponent(Type componentType)
        {
            Component component = (Component)Activator.CreateInstance(componentType);
            TestPlayerLoop.Add(component);
            return component;
        }
    }
    public static class TestPlayerLoop
    {
        private static readonly List<Component> components = new List<Component>();
        private const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        internal static void Add(Component component) { components.Add(component); }
        public static void Update() { Invoke("Update"); }
        public static void OnGUI() { Invoke("OnGUI"); }

        private static void Invoke(string name)
        {
            foreach (Component component in components)
            {
                MethodInfo method = component.GetType().GetMethod(name, Flags);
                if (method == null) continue;
                try { method.Invoke(component, null); }
                catch (TargetInvocationException e) { throw e.InnerException; }
            }
        }
    }
}
