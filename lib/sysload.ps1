# ------------------------------------------------------------- system load ----
# CPU, RAM and GPU memory in one row under the limit bars (showSystem). The numbers
# come from Windows itself - WMI's performance classes, whose names are the same in
# every Windows language - read every two seconds in a runspace of their own, so a
# slow query never stalls the window. With several graphics cards the one with the
# most memory of its own is shown (the gaming card rather than the one in the CPU);
# sysGpu picks another by part of its name. The tooltip lists them all.

$SysEverySeconds = 2

# Graphics cards by DXGI: name, memory of its own and the LUID the counters are named by.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace ClawdSys {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AdapterDesc1 {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubSysId, Revision;
        public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public uint LuidLow; public int LuidHigh; public uint Flags;
    }
    // Only the vtable slots matter for the methods never called.
    [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAdapter1 {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        void EnumOutputs(); void GetDesc(); void CheckInterfaceSupport();
        [PreserveSig] int GetDesc1(out AdapterDesc1 desc);
    }
    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFactory1 {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        void EnumAdapters(); void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
        [PreserveSig] int EnumAdapters1(uint index, out IAdapter1 adapter);
    }
    public class Gpu { public string Name; public string Luid; public ulong Total; }
    public static class Dxgi {
        [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);
        public static List<Gpu> Adapters() {
            var list = new List<Gpu>();
            Guid iid = typeof(IFactory1).GUID;
            IntPtr p;
            if (CreateDXGIFactory1(ref iid, out p) != 0) return list;
            var f = (IFactory1)Marshal.GetObjectForIUnknown(p);
            Marshal.Release(p);
            for (uint i = 0; i < 16; i++) {
                IAdapter1 a;
                if (f.EnumAdapters1(i, out a) != 0) break;
                AdapterDesc1 d;
                if (a.GetDesc1(out d) == 0 && (d.Flags & 2) == 0) {   // 2 - software (Basic Render Driver)
                    list.Add(new Gpu { Name = d.Description.Trim(), Total = d.DedicatedVideoMemory.ToUInt64(),
                                       Luid = String.Format("luid_0x{0:x8}_0x{1:x8}", d.LuidHigh, d.LuidLow) });
                }
                Marshal.ReleaseComObject(a);
            }
            Marshal.ReleaseComObject(f);
            return list;
        }
    }
}
'@

# The card to show: the one named by sysGpu (part of its name), else the most memory of its own.
function Select-SysGpu($gpus, [string]$prefer) {
    $gpus = @($gpus | Where-Object { $_ -and $_.total -gt 0 })
    if (-not $gpus.Count) { return $null }
    if ($prefer) {
        $hit = @($gpus | Where-Object { $_.name -like "*$prefer*" })
        if ($hit.Count) { return $hit[0] }
    }
    return @($gpus | Sort-Object { [double]$_.total } -Descending)[0]
}

$script:SysState = [hashtable]::Synchronized(@{ stop = $false; at = [datetime]::MinValue; error = $null
                                                cpu = $null; ramUsed = $null; ramTotal = $null; gpus = @() })
$SysReadScript = {
    param($st, $every, $gpus)
    while (-not $st.stop) {
        try {
            $cpu = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
            # Utility is what Task Manager shows (it follows the clock speed); older systems only have Time.
            $c = $cpu.PercentProcessorUtility
            if ($null -eq $c) { $c = $cpu.PercentProcessorTime }
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $list = @()
            if ($gpus.Count) {
                $rows = @()
                try { $rows = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop) } catch {}
                # Counter instances are luid_0x..._0x..._phys_N - one per physical part of a card.
                foreach ($g in $gpus) {
                    $used = 0.0
                    foreach ($r in $rows) {
                        if ("$($r.Name)".StartsWith($g.Luid, [StringComparison]::OrdinalIgnoreCase)) { $used += [double]$r.DedicatedUsage }
                    }
                    $list += @{ name = $g.Name; total = [double]$g.Total; used = $used }
                }
            }
            $st.cpu      = [math]::Min(100.0, [double]$c)
            $st.ramTotal = 1KB * [double]$os.TotalVisibleMemorySize
            $st.ramUsed  = $st.ramTotal - 1KB * [double]$os.FreePhysicalMemory
            $st.gpus     = $list
            $st.at       = [datetime]::Now
            $st.error    = $null
        } catch { $st.error = $_.Exception.Message }
        for ($i = 0; $i -lt 10 * $every -and -not $st.stop; $i++) { Start-Sleep -Milliseconds 100 }
    }
}
$script:SysReader = $null

function Start-SysLoad {
    if ($script:SysReader) { return }
    $gpus = @()
    try { $gpus = @([ClawdSys.Dxgi]::Adapters()) } catch {}
    $script:SysState.stop = $false
    $ps = [powershell]::Create()
    [void]$ps.AddScript($SysReadScript).AddArgument($script:SysState).AddArgument($SysEverySeconds).AddArgument($gpus)
    $script:SysReader = @{ ps = $ps; handle = $ps.BeginInvoke() }
    $script:SysTimer.Start()
}

function Stop-SysLoad {
    $script:SysTimer.Stop()
    if (-not $script:SysReader) { return }
    $script:SysState.stop = $true
    $r = $script:SysReader
    $script:SysReader = $null
    try { [void]$r.ps.BeginStop($null, $null) } catch {}
}

function Format-SysGB([double]$bytes) {
    return ($bytes / 1GB).ToString('0.0', [cultureinfo]::InvariantCulture)
}

# One of the three columns: the bar and the number in the level colour past warnPercent.
function Set-SysCell($bar, $text, $pct) {
    $w = ($BarWidth - 20) / 3
    if ($null -eq $pct) {
        $bar.Width = 0
        $text.Text = '--'
        $text.Foreground = New-Brush '#FF8B8B94'
        return
    }
    $p = [int][math]::Round([math]::Max(0, [math]::Min(100, $pct)))
    $lvl = Get-Level $p
    $bar.Width = $w * $p / 100.0
    $bar.Background = New-Brush $(if ($lvl -eq 'ok') { '#FF2DD4BF' } else { $Palette[$lvl].Wpf })
    $text.Text = "$p%"
    $text.Foreground = New-Brush $(if ($lvl -eq 'ok') { '#FFD4D4D8' } else { $Palette[$lvl].Wpf })
}

function Update-SysRow {
    if (-not $script:Cfg.showSystem) { return }
    $st = $script:SysState
    $fresh = ([datetime]::Now - $st.at).TotalSeconds -lt 5 * $SysEverySeconds + 5
    $cpu = $(if ($fresh) { $st.cpu } else { $null })
    $ram = $(if ($fresh -and $st.ramTotal) { 100.0 * $st.ramUsed / $st.ramTotal } else { $null })
    $g   = $(if ($fresh) { Select-SysGpu $st.gpus ([string]$script:Cfg.sysGpu) } else { $null })
    $gpu = $(if ($g) { 100.0 * $g.used / $g.total } else { $null })
    Set-SysCell $UI.BarCpu $UI.LineCpu $cpu
    Set-SysCell $UI.BarRam $UI.LineRam $ram
    Set-SysCell $UI.BarGpu $UI.LineGpu $gpu

    $tip = @()
    if ($null -ne $cpu) { $tip += 'CPU  {0:0}%' -f $cpu }
    if ($null -ne $ram) { $tip += 'RAM  {0} / {1} GB' -f (Format-SysGB $st.ramUsed), (Format-SysGB $st.ramTotal) }
    foreach ($x in @($st.gpus | Where-Object { $_.total -gt 0 })) {
        $mark = $(if ($g -and $x.name -eq $g.name) { [char]0x25B8 } else { ' ' })
        $tip += '{0} {1}  {2} / {3} GB' -f $mark, $x.name, (Format-SysGB $x.used), (Format-SysGB $x.total)
    }
    if (-not $fresh) { $tip = @(T 'sys.noData') }
    $tip = $tip -join "`n"
    if ($tip -ne $script:SysTip) { $script:SysTip = $tip; $UI.SysPanel.ToolTip = $tip }
}

# Redrawn on a timer of its own - the main refresh may be ten seconds apart.
$script:SysTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SysTimer.Interval = [TimeSpan]::FromSeconds($SysEverySeconds)
$script:SysTimer.add_Tick({ try { Update-SysRow } catch {} })

# Called by Update-Widget: shows or hides the row and starts or stops the reader with it.
function Sync-SysLoad {
    if ($script:Cfg.showSystem) {
        $UI.SysPanel.Visibility = 'Visible'
        Start-SysLoad
        Update-SysRow
    } else {
        $UI.SysPanel.Visibility = 'Collapsed'
        Stop-SysLoad
    }
}
