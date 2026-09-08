using System.Runtime.CompilerServices;
using UnityEngine;

namespace Mutiny
{
    public class Ticker : MonoBehaviour
    {
        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern void OnUpdate();

        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern void OnGui();

        private void Update()
        {
            OnUpdate();
        }

        private void OnGUI()
        {
            OnGui();
        }
    }
}
