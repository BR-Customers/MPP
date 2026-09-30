// A spooler failure whose Message is already a complete, self-describing,
// single-line diagnosis -- so Protocol.HandleRequest can put it on the wire as-is.
// Spooler.cs is the only thing that throws it.

using System;
using System.Runtime.Serialization;

namespace BlueRidge.MesZebraBridge
{
    [Serializable]
    public class SpoolException : Exception
    {
        public SpoolException(string message) : base(message) { }

        protected SpoolException(SerializationInfo info, StreamingContext context)
            : base(info, context) { }
    }
}
