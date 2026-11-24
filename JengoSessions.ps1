# Jengo Sessions - lijst van alle Jengo-vensters (Windows Terminal) met indicatoren.
# Klik een rij = venster naar voren. Knop "Stash" = vraagt die sessie zichzelf te stashen.
# Indicatoren: A = luistert op agent board (board.py wait), W = pollt WhatsApp, M = pollt meeting.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, int flags, int extra);
}
"@

$collect = {
  if (-not $global:JC) { $global:JC = @{ title = @{}; path = @{}; stamp = @{} } }
  function Get-Tail([string]$p, [int]$bytes) {
    $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
    try {
      $len = $fs.Length; $start = [Math]::Max(0, $len - $bytes); $null = $fs.Seek($start, 'Begin')
      $buf = New-Object byte[] ($len - $start); $null = $fs.Read($buf, 0, $buf.Length)
      return [Text.Encoding]::UTF8.GetString($buf)
    } finally { $fs.Dispose() }
  }
  function Unesc([string]$s) { try { return (('"' + $s + '"') | ConvertFrom-Json) } catch { return $s } }

  $procs = Get-CimInstance Win32_Process
  $byPid = @{}; foreach ($p in $procs) { $byPid[[int]$p.ProcessId] = $p }

  # sessies uit ~/.claude/sessions met levend claude-proces
  $sess = @()
  foreach ($f in Get-ChildItem "$env:USERPROFILE\.claude\sessions\*.json" -ErrorAction SilentlyContinue) {
    try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    $pr = $byPid[[int]$j.pid]
    if (-not $pr -or $pr.Name -ne 'claude.exe') { continue }
    if ($j.kind -ne 'interactive') { continue }
    $sess += $j
  }
  $sessByPid = @{}; foreach ($s in $sess) { $sessByPid[[int]$s.pid] = $s }

  # per sessie: nakomelingen-commandlines + board-wait
  $desc = @{}; foreach ($s in $sess) { $desc[$s.sessionId] = New-Object Collections.Generic.List[string] }
  $waitSid = @{}
  foreach ($p in $procs) {
    $cl = $p.CommandLine; if (-not $cl) { continue }
    if ($cl -match 'board\.py\s+wait\s+([0-9a-f-]{36})') { $waitSid[$Matches[1]] = $true }
    $cur = [int]$p.ParentProcessId; $d = 0
    while ($cur -and $d -lt 10) {
      if ($sessByPid.ContainsKey($cur)) { $desc[$sessByPid[$cur].sessionId].Add($cl); break }
      $nx = $byPid[$cur]; if (-not $nx) { break }; $cur = [int]$nx.ParentProcessId; $d++
    }
  }

  # vensters (Windows Terminal) via UI Automation
  $root = [Windows.Automation.AutomationElement]::RootElement
  $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
  $wins = @()
  foreach ($w in $root.FindAll('Children', $cond)) {
    $t = $w.Current.Name
    $wins += [pscustomobject]@{ hwnd = [int64]$w.Current.NativeWindowHandle; title = $t; clean = ($t -replace '^\S+\s+', '') }
  }

  $now = [DateTime]::UtcNow
  $out = @()
  foreach ($s in $sess) {
    $sid = $s.sessionId
    # transcript + titel (cache)
    if (-not $global:JC.path[$sid]) {
      $g = Get-ChildItem "$env:USERPROFILE\.claude\projects\*\$sid.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($g) { $global:JC.path[$sid] = $g.FullName }
    }
    $tp = $global:JC.path[$sid]
    $tail = ''
    if ($tp) { try { $tail = Get-Tail $tp 400000 } catch {} }
    $title = $null
    if ($tail) {
      $m = [regex]::Matches($tail, '"customTitle":"((?:[^"\\]|\\.)*)"'); if ($m.Count) { $title = Unesc $m[$m.Count - 1].Groups[1].Value }
      if (-not $title) { $m = [regex]::Matches($tail, '"aiTitle":"((?:[^"\\]|\\.)*)"'); if ($m.Count) { $title = Unesc $m[$m.Count - 1].Groups[1].Value } }
    }
    if ($title) { $global:JC.title[$sid] = $title } else { $title = $global:JC.title[$sid] }
    if (-not $title) { $title = $s.name }

    # recente activiteit in transcript: poller-scripts met tijdstempel
    $recent = { param($rx)
      $best = [DateTime]::MinValue
      foreach ($mm in [regex]::Matches($tail, $rx)) {
        $ts = [regex]::Match($tail.Substring($mm.Index, [Math]::Min(6000, $tail.Length - $mm.Index)), '"timestamp":"([^"]+)"')
        if ($ts.Success) { $d = [DateTime]::MinValue; if ([DateTime]::TryParse($ts.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal', [ref]$d) -and $d -gt $best) { $best = $d } }
      }
      return (($now - $best).TotalMinutes -lt 6)
    }
    $dj = ($desc[$sid] -join "`n")
    $wa = ($dj -match 'wa_team_poll|wa-poll|whatsapp_poll') -or ($tail -and (& $recent '"command":"[^"]*wa_team_poll\.py'))
    $me = ($dj -match 'meeting_poll') -or ($tail -and (& $recent '"command":"[^"]*meeting_poll\.py'))
    $ag = [bool]$waitSid[$sid]

    $win = $wins | Where-Object { $_.clean -eq $title } | Select-Object -First 1
    $out += [pscustomobject]@{
      sid = $sid; pid = [int]$s.pid; title = $title; status = $s.status; cwd = $s.cwd
      hwnd = $(if ($win) { $win.hwnd } else { 0 }); winTitle = $(if ($win) { $win.title } else { '' })
      agents = [bool]$ag; wa = [bool]$wa; meet = [bool]$me
    }
  }
  return ($out | Sort-Object title)
}

# ---------------- UI ----------------
$brush = { param($h) (New-Object Windows.Media.BrushConverter).ConvertFromString($h) }
$bg = & $brush '#14171c'; $rowBg = & $brush '#1d222a'; $rowHover = & $brush '#262d38'
$fg = & $brush '#e6e9ef'; $dim = & $brush '#7d8794'; $off = & $brush '#2c333d'
$cA = & $brush '#3fb950'; $cW = & $brush '#25d366'; $cM = & $brush '#58a6ff'; $cBusy = & $brush '#f0b429'; $cIdle = & $brush '#8b949e'

$win = New-Object Windows.Window
$win.Title = 'Jengo sessies'; $win.Width = 520; $win.Height = 560; $win.Background = $bg
$win.FontFamily = 'Segoe UI'; $win.Topmost = $true; $win.WindowStartupLocation = 'Manual'
$win.Left = [Windows.SystemParameters]::WorkArea.Right - 540; $win.Top = 60

$dock = New-Object Windows.Controls.DockPanel
$head = New-Object Windows.Controls.DockPanel; $head.Margin = '12,10,12,6'
[Windows.Controls.DockPanel]::SetDock($head, 'Top')
$hTitle = New-Object Windows.Controls.TextBlock; $hTitle.Text = 'Jengo sessies'; $hTitle.Foreground = $fg; $hTitle.FontSize = 16; $hTitle.FontWeight = 'SemiBold'
$legend = New-Object Windows.Controls.TextBlock; $legend.Foreground = $dim; $legend.FontSize = 11; $legend.Margin = '0,3,0,0'
$legend.Text = 'A = luistert op agent board   W = pollt WhatsApp   M = pollt meeting'
$cnt = New-Object Windows.Controls.TextBlock; $cnt.Foreground = $dim; $cnt.HorizontalAlignment = 'Right'; $cnt.VerticalAlignment = 'Center'
[Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
$head.Children.Add($cnt) | Out-Null; $head.Children.Add($hTitle) | Out-Null
$sub = New-Object Windows.Controls.StackPanel; $sub.Margin = '12,0,12,6'; [Windows.Controls.DockPanel]::SetDock($sub, 'Top')
$sub.Children.Add($legend) | Out-Null
$dock.Children.Add($head) | Out-Null; $dock.Children.Add($sub) | Out-Null
$scroll = New-Object Windows.Controls.ScrollViewer; $scroll.VerticalScrollBarVisibility = 'Auto'
$list = New-Object Windows.Controls.StackPanel; $list.Margin = '8,0,8,8'
$scroll.Content = $list; $dock.Children.Add($scroll) | Out-Null
$win.Content = $dock

function Focus-Window([int64]$h) {
  $p = [IntPtr]$h
  if ([Win32]::IsIconic($p)) { [Win32]::ShowWindow($p, 9) | Out-Null }
  [Win32]::keybd_event(0x12, 0, 0, 0); [Win32]::keybd_event(0x12, 0, 2, 0)   # alt-tik: foreground-lock omzeilen
  [Win32]::SetForegroundWindow($p) | Out-Null
}

function New-Badge($letter, $on, $color) {
  $b = New-Object Windows.Controls.Border; $b.Width = 24; $b.Height = 22; $b.CornerRadius = 4; $b.Margin = '3,0,0,0'
  $t = New-Object Windows.Controls.TextBlock; $t.Text = $letter; $t.FontSize = 12; $t.FontWeight = 'Bold'
  $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
  if ($on) { $b.Background = $color; $t.Foreground = & $brush '#0b0e12' } else { $b.Background = $off; $t.Foreground = & $brush '#4a535f' }
  $b.Child = $t; return $b
}

$stashPrompt = 'Stash deze sessie nu: sla met de stash MCP (stash_save) een handoff op met waar je mee bezig bent, de stand van zaken, wat nog openstaat en hoe iemand verder kan. Meld daarna de stash-id.'
function Send-Stash($item) {
  $r = [Windows.MessageBox]::Show("Sessie '$($item.title)' vragen zichzelf te stashen?", 'Stash sessie', 'YesNo', 'Question')
  if ($r -ne 'Yes') { return }
  Focus-Window $item.hwnd
  Start-Sleep -Milliseconds 400
  $old = $null; try { $old = [Windows.Clipboard]::GetText() } catch {}
  [Windows.Clipboard]::SetText($stashPrompt)
  [Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 250; [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Milliseconds 300
  if ($old) { try { [Windows.Clipboard]::SetText($old) } catch {} }
}

$script:lastSig = ''
function Render($items) {
  $sig = ($items | ForEach-Object { "$($_.sid)|$($_.title)|$($_.status)|$($_.hwnd)|$($_.agents)|$($_.wa)|$($_.meet)" }) -join ';'
  $cnt.Text = "$(@($items).Count) sessies"
  if ($sig -eq $script:lastSig) { return }
  $script:lastSig = $sig
  $list.Children.Clear()
  foreach ($it in $items) {
    $row = New-Object Windows.Controls.Border; $row.Background = $rowBg; $row.CornerRadius = 6; $row.Margin = '0,3,0,3'; $row.Padding = '10,8,8,8'
    $row.Cursor = $(if ($it.hwnd) { 'Hand' } else { 'Arrow' }); $row.Opacity = $(if ($it.hwnd) { 1.0 } else { 0.55 })
    $g = New-Object Windows.Controls.Grid
    foreach ($w in @('Auto', '*', 'Auto', 'Auto')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 10; $dot.Height = 10; $dot.Margin = '0,0,10,0'; $dot.VerticalAlignment = 'Center'
    $dot.Fill = $(if ($it.status -eq 'busy') { $cBusy } else { $cIdle })
    $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'
    $n = New-Object Windows.Controls.TextBlock; $n.Text = $it.title; $n.Foreground = $fg; $n.FontSize = 13.5; $n.TextTrimming = 'CharacterEllipsis'
    $leaf = if ($it.cwd) { Split-Path $it.cwd -Leaf } else { '' }
    $s2 = New-Object Windows.Controls.TextBlock; $s2.Foreground = $dim; $s2.FontSize = 11
    $s2.Text = "$leaf  -  $($it.sid.Substring(0,8))  -  $(if ($it.status -eq 'busy') {'bezig'} else {'wacht'})" + $(if (-not $it.hwnd) { '  -  geen venster' } else { '' })
    $sp.Children.Add($n) | Out-Null; $sp.Children.Add($s2) | Out-Null
    $bp = New-Object Windows.Controls.StackPanel; $bp.Orientation = 'Horizontal'; $bp.VerticalAlignment = 'Center'; $bp.Margin = '8,0,8,0'
    $bp.Children.Add((New-Badge 'A' $it.agents $cA)) | Out-Null
    $bp.Children.Add((New-Badge 'W' $it.wa $cW)) | Out-Null
    $bp.Children.Add((New-Badge 'M' $it.meet $cM)) | Out-Null
    $btn = New-Object Windows.Controls.Button; $btn.Content = 'Stash'; $btn.Padding = '10,3,10,3'; $btn.VerticalAlignment = 'Center'
    $btn.IsEnabled = [bool]$it.hwnd; $btn.ToolTip = 'Vraag deze sessie zichzelf te stashen'
    $btn.Tag = $it
    $btn.Add_Click({ param($s, $e) $e.Handled = $true; Send-Stash $s.Tag })
    [Windows.Controls.Grid]::SetColumn($sp, 1); [Windows.Controls.Grid]::SetColumn($bp, 2); [Windows.Controls.Grid]::SetColumn($btn, 3)
    $g.Children.Add($dot) | Out-Null; $g.Children.Add($sp) | Out-Null; $g.Children.Add($bp) | Out-Null; $g.Children.Add($btn) | Out-Null
    $row.Child = $g; $row.Tag = $it
    $row.Add_MouseEnter({ param($s, $e) $s.Background = $rowHover }); $row.Add_MouseLeave({ param($s, $e) $s.Background = $rowBg })
    $row.Add_MouseLeftButtonUp({ param($s, $e) if ($s.Tag.hwnd) { Focus-Window $s.Tag.hwnd } })
    $list.Children.Add($row) | Out-Null
  }
}

# collectie op achtergrond-runspace zodat de UI niet hapert
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
$script:job = $null
function Start-Collect {
  $ps = [powershell]::Create(); $ps.Runspace = $rs; $null = $ps.AddScript($collect.ToString())
  $script:job = @{ ps = $ps; h = $ps.BeginInvoke() }
}
$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
  if ($script:job -and $script:job.h.IsCompleted) {
    try { $res = $script:job.ps.EndInvoke($script:job.h); Render @($res) } catch {}
    $script:job.ps.Dispose(); $script:job = $null
  }
  if (-not $script:job) { Start-Collect }
})
$win.Add_Closed({ $timer.Stop(); try { $rs.Close() } catch {} })
$cnt.Text = 'laden...'
Start-Collect; $timer.Start()
$win.ShowDialog() | Out-Null
