# dsh-whale-ear 投递器：把麦克风听到的整句自动打进 DSH 输入框并回车。
# 开关在 settings.json 的 autoDeliver；panel.ps1 里那个勾选框写的就是它。
param([Parameter(Mandatory = $true)][string]$WorkDir)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -Namespace Wo -Name Uo -MemberDefinition '[StructLayout(LayoutKind.Sequential)] public struct R { public int L; public int T; public int Rr; public int B; } [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h); [DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out R r); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, System.IntPtr e); [DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();'

$logPath = Join-Path $WorkDir 'deliver.log'
function Write-Log([string]$msg) {
    try {
        Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $msg) -Encoding UTF8
    } catch { }
}

$deliverPath = Join-Path $WorkDir 'deliver.jsonl'
$cfgPath = Join-Path $WorkDir 'settings.json'
$posPath = Join-Path $WorkDir 'deliver.pos'

function Get-Offset {
    try {
        if (Test-Path $posPath) { return [long](Get-Content -LiteralPath $posPath -Raw) }
    } catch { }
    return 0
}

function Save-Offset([long]$v) {
    try { Set-Content -LiteralPath $posPath -Value $v -Encoding ASCII } catch { }
}

function Test-Auto {
    try {
        if (-not (Test-Path $cfgPath)) { return $false }
        $c = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]$c.autoDeliver
    } catch { return $false }
}

# 起点：从文件尾部开始，不要一开就把历史全发出去
if (Test-Path $deliverPath) { Save-Offset (Get-Item $deliverPath).Length }

while ($true) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-Auto)) { continue }
    if (-not (Test-Path $deliverPath)) { continue }

    $len = (Get-Item $deliverPath).Length
    $offset = Get-Offset
    if ($len -lt $offset) { $offset = 0 }          # 文件被重建
    if ($len -eq $offset) { continue }

    try {
        $fs = [System.IO.File]::Open($deliverPath, 'Open', 'Read', 'ReadWrite')
        [void]$fs.Seek($offset, 'Begin')
        $buf = New-Object byte[] ($len - $offset)
        [void]$fs.Read($buf, 0, $buf.Length)
        $fs.Close()
    } catch {
        continue
    }
    Save-Offset $len
    $chunk = [System.Text.Encoding]::UTF8.GetString($buf)

    foreach ($line in ($chunk -split "`n")) {
        $line = $line.Trim()
        if ($line -eq '') { continue }
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        $text = [string]$rec.text
        if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 1) { continue }

        $proc = Get-Process | Where-Object { $_.MainWindowTitle -like '*DeepSeek Harness*' } | Select-Object -First 1
        if (-not $proc) { continue }

        # Windows 不允许后台进程随便抢前台，所以先 ShowWindow，再 AppActivate；还抢不到就按一下 Alt 解锁再抢。
        [Wo.Uo]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null   # SW_RESTORE
        Start-Sleep -Milliseconds 150
        try { [Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id) } catch { }
        Start-Sleep -Milliseconds 300
        if ([Wo.Uo]::GetForegroundWindow() -ne $proc.MainWindowHandle) {
            [System.Windows.Forms.SendKeys]::SendWait('%')
            Start-Sleep -Milliseconds 200
            [Wo.Uo]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 350
        }
        Write-Log ('foreground ok=' + ([Wo.Uo]::GetForegroundWindow() -eq $proc.MainWindowHandle))

        # 光把窗口拉到前台，输入框不一定有焦点；得先点一下输入框（窗口底部往上约 106px 的中间位置）。
        $r = New-Object Wo.Uo+R
        [void][Wo.Uo]::GetWindowRect($proc.MainWindowHandle, [ref]$r)
        $cx = [int](($r.L + $r.Rr) / 2)
        $cy = [int]($r.B - 106)
        [Wo.Uo]::SetCursorPos($cx, $cy) | Out-Null
        Start-Sleep -Milliseconds 150
        [Wo.Uo]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        [Wo.Uo]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 350

        Write-Log ('sending: ' + $text)
        Set-Clipboard -Value $text
        Start-Sleep -Milliseconds 120
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 220
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 700
    }
}
