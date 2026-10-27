# dsh-whale-ear 控制面板
param([Parameter(Mandatory = $true)][string]$WorkDir)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$cfgPath = Join-Path $WorkDir 'settings.json'
$statePath = Join-Path $WorkDir 'state.json'
$cmdPath = Join-Path $WorkDir 'cmd.json'

function Send-Cmd {
    param([hashtable]$Payload)
    $seq = 0
    try {
        if (Test-Path $cmdPath) {
            $old = Get-Content -LiteralPath $cmdPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old -and $old.seq) { $seq = [int]$old.seq }
        }
    } catch { }
    $Payload['seq'] = $seq + 1
    $json = $Payload | ConvertTo-Json -Compress
    Set-Content -LiteralPath $cmdPath -Value $json -Encoding UTF8
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鲸鱼耳朵" Width="380" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" Topmost="True"
        Background="#FF101828" FontFamily="Microsoft YaHei">
  <StackPanel Margin="16">
    <TextBlock Text="👂 鲸鱼耳朵" Foreground="#FFFFD166" FontSize="20" FontWeight="Bold"/>
    <TextBlock Name="Status" Text="…" Foreground="#FF9FE8B0" FontSize="14" Margin="0,8,0,0"/>
    <TextBlock Name="LastLine" Text="" Foreground="#FFD8E2F2" FontSize="13" TextWrapping="Wrap" Margin="0,4,0,10"/>

    <Grid Margin="0,4,0,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="90"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="34"/><RowDefinition Height="34"/><RowDefinition Height="34"/><RowDefinition Height="34"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Grid.Column="0" Text="听哪一路" Foreground="#FFB9C7DC" VerticalAlignment="Center"/>
      <ComboBox Name="Source" Grid.Row="0" Grid.Column="1" Height="26">
        <ComboBoxItem Content="both（麦+系统音）" Tag="both"/>
        <ComboBoxItem Content="mic（只听麦克风）" Tag="mic"/>
        <ComboBoxItem Content="loopback（只听系统音）" Tag="loopback"/>
      </ComboBox>
      <TextBlock Grid.Row="1" Grid.Column="0" Text="模型" Foreground="#FFB9C7DC" VerticalAlignment="Center"/>
      <ComboBox Name="Model" Grid.Row="1" Grid.Column="1" Height="26">
        <ComboBoxItem Content="tiny" Tag="tiny"/>
        <ComboBoxItem Content="base" Tag="base"/>
        <ComboBoxItem Content="small" Tag="small"/>
        <ComboBoxItem Content="medium" Tag="medium"/>
      </ComboBox>
      <TextBlock Grid.Row="2" Grid.Column="0" Text="静音门槛" Foreground="#FFB9C7DC" VerticalAlignment="Center"/>
      <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal">
        <TextBox Name="Silence" Width="80" Height="26" VerticalContentAlignment="Center"/>
        <TextBlock Text="ms（停顿多久算说完）" Foreground="#FF8FA3BF" VerticalAlignment="Center" Margin="8,0,0,0"/>
      </StackPanel>
      <TextBlock Grid.Row="3" Grid.Column="0" Text="单句上限" Foreground="#FFB9C7DC" VerticalAlignment="Center"/>
      <StackPanel Grid.Row="3" Grid.Column="1" Orientation="Horizontal">
        <TextBox Name="MaxSec" Width="80" Height="26" VerticalContentAlignment="Center"/>
        <TextBlock Text="秒（太长的强制切）" Foreground="#FF8FA3BF" VerticalAlignment="Center" Margin="8,0,0,0"/>
      </StackPanel>
    </Grid>

    <CheckBox Name="AutoSend" Content="停顿 5 秒后自动发给我（打进 DSH 输入框并回车）" Foreground="#FFD8E2F2" Margin="90,6,0,0" FontSize="12"/>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button Name="StopBtn" Content="停止" Width="80" Height="30" Margin="0,0,8,0"/>
      <Button Name="StartBtn" Content="开始听" Width="90" Height="30"/>
    </StackPanel>
    <TextBlock Name="Hint" Text="改完点「开始听」就生效；停止不影响已保存的设置。" Foreground="#FF6F809B" FontSize="11" Margin="0,10,0,0" TextWrapping="Wrap"/>
  </StackPanel>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)
$status = $win.FindName('Status')
$lastLine = $win.FindName('LastLine')
$cbSource = $win.FindName('Source')
$cbModel = $win.FindName('Model')
$tbSilence = $win.FindName('Silence')
$tbMaxSec = $win.FindName('MaxSec')
$btnStart = $win.FindName('StartBtn')
$btnStop = $win.FindName('StopBtn')

# 初始值：读 settings.json
$silence = 5000
$maxSec = 20
$src = 'both'
$model = 'small'
try {
    if (Test-Path $cfgPath) {
        $c = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.silenceMs) { $silence = [int]$c.silenceMs }
        if ($c.maxSec) { $maxSec = [int]$c.maxSec }
        if ($c.source) { $src = [string]$c.source }
        if ($c.model) { $model = [string]$c.model }
    }
} catch { }
$chkAuto = $win.FindName('AutoSend')
$autoDeliver = $false
try {
    if (Test-Path $cfgPath) {
        $c2 = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c2.autoDeliver) { $autoDeliver = [bool]$c2.autoDeliver }
    }
} catch { }
$chkAuto.IsChecked = $autoDeliver

$tbSilence.Text = [string]$silence
$tbMaxSec.Text = [string]$maxSec
foreach ($item in $cbSource.Items) { if ($item.Tag -eq $src) { $cbSource.SelectedItem = $item } }
if (-not $cbSource.SelectedItem) { $cbSource.SelectedIndex = 0 }
foreach ($item in $cbModel.Items) { if ($item.Tag -eq $model) { $cbModel.SelectedItem = $item } }
if (-not $cbModel.SelectedItem) { $cbModel.SelectedIndex = 2 }

$btnStart.Add_Click({
    $s = 5000
    [void][int]::TryParse($tbSilence.Text, [ref]$s)
    $m = 20
    [void][int]::TryParse($tbMaxSec.Text, [ref]$m)
    $srcSel = 'both'
    if ($cbSource.SelectedItem) { $srcSel = [string]$cbSource.SelectedItem.Tag }
    $modelSel = 'small'
    if ($cbModel.SelectedItem) { $modelSel = [string]$cbModel.SelectedItem.Tag }
    Send-Cmd @{ cmd = 'start'; silenceMs = $s; maxSec = $m; source = $srcSel; model = $modelSel }
    $status.Text = '正在启动…'
})
$chkAuto.Add_Click({
    Send-Cmd @{ cmd = 'config'; autoDeliver = [bool]$chkAuto.IsChecked }
})

$btnStop.Add_Click({
    Send-Cmd @{ cmd = 'stop' }
    $status.Text = '已停止'
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
    try {
        if (-not (Test-Path $statePath)) { $status.Text = '还没启动过'; return }
        $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.running) {
            $status.Text = '在听 · ' + [string]$st.source
            $status.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF9FE8B0')
        } else {
            $status.Text = '已停止'
            $status.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF8FA3BF')
        }
        $t = [string]$st.last
        if ([string]::IsNullOrWhiteSpace($t)) { $lastLine.Text = '（还没听到东西）' } else { $lastLine.Text = $t }
    } catch { }
})
$timer.Start()

$win.Add_Closed({ $timer.Stop() })
[void]$win.ShowDialog()
