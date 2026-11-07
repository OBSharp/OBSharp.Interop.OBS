#Requires -Version 7.0
<#
.SYNOPSIS
    生成 OBS 的 C# P/Invoke 绑定。

.DESCRIPTION
    这些头文件只包含 C 导出声明，因此直接按 C 导出生成 P/Invoke，不需要
    cpp-redirect 再产出 native 中间层。obs.hpp 只有 C++ 模板与内联函数、
    没有任何 C 导出，故不纳入生成范围。

    两个头文件的符号并不在同一个原生库里：obs.h 的符号由 obs 导出，
    obs-frontend-api.h 的符号由 obs-frontend-api 导出。生成器一次只接受
    一个 library-name，所以先统一按主库生成，再把归属其它库的函数改写成
    真实库名（函数名集合由对应头文件单独生成一趟得到）。

    头文件解析由 libclang 完成，Windows 上还需要 MSVC 与 Windows SDK 的
    包含目录才能正确解析系统头（例如 <windows.h>）。这些目录通过 vswhere
    定位 Visual Studio 安装位置后取得，无需预先进入开发者命令提示符。

    生成器默认会跳过变参函数；这里统一开启 --allow-variadic，让这类导出
    至少绑定其定参部分，不会从绑定里静默消失。两趟生成都带上该开关，否则
    暂存趟的函数名集合会比主趟少，库名改写就对不上。

.PARAMETER ObsStudioDirectory
    obs-studio 源码（含头文件）所在目录。

.PARAMETER GeneratedDirectory
    C# 产物目录。

.PARAMETER WorkDirectory
    生成过程的中间文件目录（obsconfig.h 桩、按模块暂存的产物）。

.PARAMETER Namespace
    生成的 C# 命名空间。

.PARAMETER PrimaryLibrary
    主库名，即 obs.h 的符号导出所在的原生库。

.PARAMETER ReturnStringMarshaller
    const char* 返回值封送器类型名。

.PARAMETER NullableHandleMarshaller
    句柄参数封送器类型名。

.PARAMETER GeneratorCommand
    绑定生成器命令；版本由 dotnet-tools.json 固定。

.EXAMPLE
    pwsh ./scripts/Invoke-SourceGenerator.ps1

.EXAMPLE
    dotnet msbuild src/OBSharp.Interop.OBS/OBSharp.Interop.OBS.csproj -t:GenerateObsBindings
#>
[CmdletBinding()]
param(
    # obs-studio 源码（含头文件）所在目录
    [string] $ObsStudioDirectory = 'lib/obs-studio',
    # C# 产物目录
    [string] $GeneratedDirectory = 'src/OBSharp.Interop.OBS/Generated',
    # 生成过程的中间文件目录
    [string] $WorkDirectory = 'artifacts/obs-bindings',
    # 生成的 C# 命名空间
    [string] $Namespace = 'OBSharp.Interop.OBS',
    # 主库：obs.h 的符号导出所在的原生库
    [string] $PrimaryLibrary = 'obs',
    # const char* 返回值封送器：原生侧不转让所有权，只复制不释放
    [string] $ReturnStringMarshaller = 'OBSharp.Interop.OBS.NoFreeUTF8StringMarshaller',
    # 句柄参数封送器：托管 null 映射为原生 NULL
    [string] $NullableHandleMarshaller = 'OBSharp.Interop.OBS.NullableSafeHandleMarshaller',
    # 生成器命令；版本由 dotnet-tools.json 固定
    [string] $GeneratorCommand = 'dotnet tool run OBSharp.Interop.NativeBindGenerator'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = Split-Path -Parent $PSScriptRoot

# 归属主库的头文件。obs.h 只是伞形头文件，生成器只收集显式列出的头文件
# 里的声明，因此 libobs 的公开头文件必须逐一列出。
$BindingHeaders = @(
    'libobs/obs.h'
    'libobs/obs-data.h'
    'libobs/obs-properties.h'
    'libobs/obs-interaction.h'
    'libobs/obs-missing-files.h'
    'libobs/obs-source.h'
    'libobs/obs-encoder.h'
    'libobs/obs-output.h'
    'libobs/obs-service.h'
    'libobs/obs-hotkey.h'
    'libobs/obs-audio-controls.h'
    'libobs/obs-module.h'
    'libobs/obs-avc.h'
    'libobs/obs-hevc.h'
    'libobs/obs-av1.h'
    'libobs/obs-nal.h'
)

# 归属其它原生库的头文件；Library 是其符号真正所在的库名
$BindingModules = @(
    [pscustomobject]@{
        Header  = 'frontend/api/obs-frontend-api.h'
        Library = 'obs-frontend-api'
    }
)

# obsconfig.h 由 CMake 配置时生成，源码树里没有；绑定只需要宏可见，取值无关。
$ObsConfigStubLines = @(
    '#pragma once'
    '#define OBS_DATA_PATH "data"'
    '#define OBS_PLUGIN_PATH "plugins"'
    '#define OBS_PLUGIN_DESTINATION "plugins"'
    '#define OBS_INSTALL_PREFIX ""'
    '#define OBS_RELEASE_CANDIDATE 0'
    '#define OBS_BETA 0'
)

# LibraryImport 声明形如 [LibraryImport("obs", EntryPoint = "obs_canvas_create")]
$LibraryImportPattern = '\[LibraryImport\("([^"]+)", EntryPoint = "([^"]+)"\)\]'

function Resolve-RepoPath {
    param([Parameter(Mandatory)] [string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RootPath $Path))
}

function Split-CommandLine {
    param([string] $CommandLine)

    $tokens = [System.Collections.Generic.List[string]]::new()
    $token = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    $started = $false

    foreach ($character in $CommandLine.ToCharArray()) {
        if ($character -eq '"') {
            $inQuotes = -not $inQuotes
            $started = $true
            continue
        }

        if (-not $inQuotes -and [char]::IsWhiteSpace($character)) {
            if ($started) {
                $tokens.Add($token.ToString())
                [void] $token.Clear()
                $started = $false
            }

            continue
        }

        [void] $token.Append($character)
        $started = $true
    }

    if ($started) {
        $tokens.Add($token.ToString())
    }

    # 用逗号包一层，避免单个元素被调用方当成标量展开
    return , $tokens.ToArray()
}

function Get-VsWherePath {
    $installerRoots = @()
    if (${env:ProgramFiles(x86)}) {
        $installerRoots += ${env:ProgramFiles(x86)}
    }

    if ($env:ProgramFiles) {
        $installerRoots += $env:ProgramFiles
    }

    foreach ($root in $installerRoots) {
        $candidate = Join-Path $root 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command -Name 'vswhere.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    return $null
}

function Get-LatestDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $NamePattern
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $Path -Directory |
        Where-Object { $_.Name -match $NamePattern } |
        Sort-Object -Property @{ Expression = { [version] $_.Name } } -Descending |
        Select-Object -First 1
}

function Get-WindowsSdkIncludeDirectories {
    $kitsRoot = $null
    foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
        )) {
        $value = (Get-ItemProperty -LiteralPath $key -Name 'KitsRoot10' -ErrorAction SilentlyContinue).KitsRoot10
        if ($value) {
            $kitsRoot = $value
            break
        }
    }

    if (-not $kitsRoot) {
        return @()
    }

    $version = Get-LatestDirectory -Path (Join-Path $kitsRoot 'Include') -NamePattern '^\d+(\.\d+)+$'
    if (-not $version) {
        return @()
    }

    $directories = @()
    foreach ($part in @('ucrt', 'um', 'shared')) {
        $directory = Join-Path $version.FullName $part
        if (Test-Path -LiteralPath $directory) {
            $directories += $directory
        }
    }

    return $directories
}

function Get-NativeIncludeDirectories {
    # 非 Windows 平台没有 MSVC，libclang 自己就能找到系统头。
    if (-not $IsWindows) {
        return @()
    }

    $vsWherePath = Get-VsWherePath
    if (-not $vsWherePath) {
        throw '未找到 vswhere.exe，无法定位 Visual Studio 安装位置。请安装 Visual Studio 或 Visual Studio Build Tools（含 C++ 生成工具）。'
    }

    # vswhere -find 支持 ** 通配，这里拿到所有工具集的 include 目录
    $msvcIncludes = & $vsWherePath -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'VC\Tools\MSVC\**\include'
    if ($LASTEXITCODE -ne 0) {
        throw "vswhere 执行失败（退出码 $LASTEXITCODE）：$vsWherePath"
    }

    # 只保留 <工具集版本>\include，排除 atlmfc\include 之类的子目录
    $msvcInclude = $msvcIncludes |
        Where-Object { $_ -match '\\VC\\Tools\\MSVC\\[^\\]+\\include$' } |
        Sort-Object -Property @{ Expression = { [version] (Split-Path (Split-Path $_ -Parent) -Leaf) } } -Descending |
        Select-Object -First 1
    if (-not $msvcInclude) {
        throw 'vswhere 没有找到 MSVC 工具集，请确认 Visual Studio 已安装「使用 C++ 的桌面开发」工作负载。'
    }

    return @($msvcInclude) + @(Get-WindowsSdkIncludeDirectories)
}

function Invoke-BindGenerator {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $command = Split-CommandLine -CommandLine $GeneratorCommand
    if ($command.Count -eq 0) {
        throw '生成器命令为空，请检查 -GeneratorCommand。'
    }

    $executable = $command[0]
    if (-not (Get-Command -Name $executable -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "找不到绑定生成器可执行文件「$executable」，请检查 -GeneratorCommand：$GeneratorCommand"
    }

    $prefixArguments = @()
    if ($command.Count -gt 1) {
        $prefixArguments = $command[1..($command.Count - 1)]
    }

    & $executable @prefixArguments @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "绑定生成器执行失败（退出码 $LASTEXITCODE）：$GeneratorCommand"
    }
}

function Update-BindLibraryNames {
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $OutputDirectory
    )

    # 暂存产物只用来建立「函数名 -> 真实库名」的映射
    $moduleLibraries = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($moduleFile in Get-ChildItem -LiteralPath $StagingDirectory -Filter '*.g.cs' -File -Recurse) {
        $moduleText = Get-Content -LiteralPath $moduleFile.FullName -Raw
        foreach ($match in [regex]::Matches($moduleText, $LibraryImportPattern)) {
            $moduleLibraries[$match.Groups[2].Value] = $match.Groups[1].Value
        }
    }

    if ($moduleLibraries.Count -eq 0) {
        throw "没有从暂存产物中读到任何导出函数：$StagingDirectory"
    }

    $totalEntries = 0
    $retargetedFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($outputFile in Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.g.cs' -File -Recurse) {
        $outputText = Get-Content -LiteralPath $outputFile.FullName -Raw

        # 脚本块在 Replace 内同步执行，用哈希表把结果带回外层作用域
        $state = @{ Entries = 0; Changed = $false }
        $evaluator = {
            param($match)

            $entryPoint = $match.Groups[2].Value
            $library = $null
            if (-not $moduleLibraries.TryGetValue($entryPoint, [ref] $library)) {
                return $match.Value
            }

            $state.Entries++
            if ([string]::Equals($library, $match.Groups[1].Value, [System.StringComparison]::Ordinal)) {
                return $match.Value
            }

            $state.Changed = $true
            return '[LibraryImport("' + $library + '", EntryPoint = "' + $entryPoint + '")]'
        }

        $updatedText = [regex]::Replace($outputText, $LibraryImportPattern, $evaluator)
        $totalEntries += $state.Entries

        if (-not $state.Changed) {
            continue
        }

        [System.IO.File]::WriteAllText($outputFile.FullName, $updatedText, [System.Text.UTF8Encoding]::new($false))
        $retargetedFiles.Add($outputFile.Name)
    }

    if ($totalEntries -ne $moduleLibraries.Count) {
        throw "主产物中只找到 $totalEntries 个模块导出函数，少于暂存产物的 $($moduleLibraries.Count) 个，请检查头文件是否同时参与主趟生成。"
    }

    Write-Host "已修正 $totalEntries 个函数、共 $($retargetedFiles.Count) 个文件的 LibraryImport 库名：$($retargetedFiles -join ', ')"
}

$ObsStudioDirectory = Resolve-RepoPath -Path $ObsStudioDirectory
$GeneratedDirectory = Resolve-RepoPath -Path $GeneratedDirectory
$WorkDirectory = Resolve-RepoPath -Path $WorkDirectory

$obsHeaderPath = Join-Path $ObsStudioDirectory 'libobs/obs.h'
if (-not (Test-Path -LiteralPath $obsHeaderPath)) {
    throw "未找到 obs-studio 头文件：$obsHeaderPath。请先初始化 lib/obs-studio 子模块。"
}

$configStubDirectory = Join-Path $WorkDirectory 'include'
$stagingDirectory = Join-Path $WorkDirectory 'staging'

New-Item -ItemType Directory -Path $configStubDirectory -Force | Out-Null
[System.IO.File]::WriteAllLines(
    (Join-Path $configStubDirectory 'obsconfig.h'),
    $ObsConfigStubLines,
    [System.Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $stagingDirectory) {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
}

New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $GeneratedDirectory -Force | Out-Null

# 传给 libclang 的参数：C 语言、obsconfig.h 桩、libobs 头目录，以及 Windows 上的系统头目录
$clangArguments = [System.Collections.Generic.List[string]]::new()
$clangArguments.AddRange([string[]] @('-x', 'c'))

$includeDirectories = @($configStubDirectory, (Join-Path $ObsStudioDirectory 'libobs'))
$nativeIncludeDirectories = @(Get-NativeIncludeDirectories)
if ($nativeIncludeDirectories.Count -gt 0) {
    Write-Host "使用 MSVC/SDK 头目录：$($nativeIncludeDirectories -join ', ')"
    $includeDirectories += $nativeIncludeDirectories
}

foreach ($includeDirectory in $includeDirectories) {
    $clangArguments.Add('-I')
    $clangArguments.Add($includeDirectory)
}

$headerArguments = [System.Collections.Generic.List[string]]::new()
foreach ($header in $BindingHeaders) {
    $headerArguments.Add('--header')
    $headerArguments.Add((Join-Path $ObsStudioDirectory $header))
}

foreach ($module in $BindingModules) {
    $headerArguments.Add('--header')
    $headerArguments.Add((Join-Path $ObsStudioDirectory $module.Header))
}

Write-Host "正在生成 OBS 绑定到 $GeneratedDirectory"

Push-Location -LiteralPath $RootPath
try {
    # 主趟：全部头文件一起生成，库名统一按主库
    Invoke-BindGenerator -Arguments (@(
            [string[]] $headerArguments
            '--csharp-output', $GeneratedDirectory
            '--namespace', $Namespace
            '--library-name', $PrimaryLibrary
            '--return-string-marshaller', $ReturnStringMarshaller
            '--nullable-handle-marshaller', $NullableHandleMarshaller
            # 变参函数只绑定定参部分，而不是整类跳过
            '--allow-variadic'
            '--'
        ) + [string[]] $clangArguments)

    # 从趟：归属其它原生库的头文件逐个单独生成，产物只作暂存，用于取出其导出函数名
    # 选项必须与主趟一致（含 --allow-variadic），否则函数名集合会与主产物对不上
    foreach ($module in $BindingModules) {
        $moduleStagingDirectory = Join-Path $stagingDirectory $module.Library
        Invoke-BindGenerator -Arguments @(
            '--header', (Join-Path $ObsStudioDirectory $module.Header)
            '--csharp-output', $moduleStagingDirectory
            '--namespace', $Namespace
            '--library-name', $module.Library
            '--allow-variadic'
            '--'
            [string[]] $clangArguments
        )
    }
}
finally {
    Pop-Location
}

if ($BindingModules.Count -gt 0) {
    Update-BindLibraryNames -StagingDirectory $stagingDirectory -OutputDirectory $GeneratedDirectory
}

Write-Host "OBS 绑定生成完成：$GeneratedDirectory"
