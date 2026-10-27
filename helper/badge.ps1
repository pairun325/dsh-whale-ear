# dsh-whale-ear badge —— 屏幕右下角「肥鱼正在偷听」小窗。
# 参数：-StateFile <state.json 路径>
param(
    [Parameter(Mandatory = $true)][string]$StateFile
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ShowActivated="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight">
  <Border Background="#E6101728" BorderBrush="#66FFD166" BorderThickness="1" CornerRadius="12" Padding="14,10">
    <StackPanel>
      <TextBlock Name="Head" Text="👂 肥鱼正在偷听" Foreground="#FFFFD166" FontFamily="Microsoft YaHei" FontSize="20" FontWeight="Bold" />
      <TextBlock Name="Body" Text="…" Foreground="#FFD8E2F2" FontFamily="Microsoft YaHei" FontSize="15" Margin="0,4,0,0" MaxWidth="520" TextWrapping="Wrap" />
    </StackPanel>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$head = $win.FindName('Head')
$body = $win.FindName('Body')

$wa = [System.Windows.SystemParameters]::WorkArea
$win.Left = $wa.Right - 600
$win.Top = $wa.Bottom - 150

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)

$lastSeen = ''
$timer.Add_Tick({
    try {
        if (-not (Test-Path $StateFile)) {
            $body.Text = '（状态文件不见了）'
            return
        }
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 -ErrorAction Stop
        $st = $raw | ConvertFrom-Json
        if (-not $st.running) {
            $head.Text = '👂 耳朵已关闭'
            $head.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF8FA3BF')
            $body.Text = ''
            return
        }
        $head.Text = '👂 肥鱼正在偷听'
        $head.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFD166')
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $age = $now - [double]$st.last_t
        $text = [string]$st.last
        if ([string]::IsNullOrWhiteSpace($text)) {
            $body.Text = '… 还没听到东西'
        } elseif ($age -gt 25) {
            $body.Text = '（安静 ' + [int]$age + ' 秒）'
        } else {
            if ($text.Length -gt 60) { $text = $text.Substring(0, 60) + '…' }
            $body.Text = $text
        }
    } catch {
        $body.Text = '…'
    }
})
$timer.Start()

$win.Add_Closed({ $timer.Stop() })
[void]$win.ShowDialog()
