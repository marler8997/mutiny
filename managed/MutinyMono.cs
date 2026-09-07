using System.Runtime.CompilerServices;
using UnityEngine;

namespace Mutiny
{
    public class Ticker : MonoBehaviour
    {
        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern void OnUpdate();

        private void Update()
        {
            OnUpdate();
        }
    }
}
