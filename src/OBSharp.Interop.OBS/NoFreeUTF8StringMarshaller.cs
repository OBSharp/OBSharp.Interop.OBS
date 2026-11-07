using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace OBSharp.Interop.OBS;

/// <summary>
/// 「只复制、不释放」的 UTF-8 字符串封送器（返回值方向）。
/// </summary>
[CustomMarshaller(typeof(string), MarshalMode.ManagedToUnmanagedOut, typeof(NoFreeUTF8StringMarshaller))]
internal static unsafe class NoFreeUTF8StringMarshaller
{
    /// <summary>
    /// 把原生 UTF-8 字符串复制成托管字符串；<paramref name="unmanaged"/> 归原生侧，这里只读不释放。
    /// </summary>
    public static string? ConvertToManaged(byte* unmanaged)
        => Marshal.PtrToStringUTF8((nint)unmanaged);
}
