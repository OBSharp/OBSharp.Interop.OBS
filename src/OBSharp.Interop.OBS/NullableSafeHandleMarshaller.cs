using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace OBSharp.Interop.OBS;

/// <summary>
/// 可空句柄参数封送器（null ↔ 原生 NULL），用于生成代码里 <c>Xxx?</c> 形态的句柄参数。
/// </summary>
[CustomMarshaller(typeof(SafeHandle), MarshalMode.ManagedToUnmanagedIn, typeof(NullableSafeHandleMarshaller))]
internal struct NullableSafeHandleMarshaller
{
    /// <summary>
    /// 原生侧函数只在调用期间使用句柄指针；null 映射为 0。
    /// </summary>
    private SafeHandle? _managed;

    /// <summary>
    /// 是否已 <c>DangerousAddRef</c>（句柄已关闭时 AddRef 会抛，此时不持有）。
    /// </summary>
    private bool _addRef;

    /// <summary>
    /// 接收托管句柄并钉住它；null 表示原生 NULL。
    /// </summary>
    public void FromManaged(SafeHandle? managed)
    {
        _managed = managed;
        if (managed is null)
            return;

        bool addRef = false;
        managed.DangerousAddRef(ref addRef);
        _addRef = addRef;
    }

    /// <summary>
    /// 句柄 → 原生指针（null → 0）。
    /// </summary>
    public readonly nint ToUnmanaged()
        => _managed is null ? 0 : _managed.DangerousGetHandle();

    /// <summary>
    /// 原生调用结束后解除钉住。
    /// </summary>
    public void Free()
    {
        if (_managed is not { } managed || !_addRef)
            return;

        managed.DangerousRelease();
        _addRef = false;
    }
}
