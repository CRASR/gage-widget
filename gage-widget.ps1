# Gage Widget (gage-widget.ps1)
# Desktop widget: latest discharge and stage for selected USGS gages, with a 48-h hydrograph
# (hover over it to read any point).
# Data: USGS Water Data API. Latest readings from latest-continuous; 48-h history from continuous. API key optional.
# Launch: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "<path>\gage-widget.ps1"
# Lives on the desktop layer (stays put through Win+D). Drag to move; drag a row's dotted grip to reorder;
# right-click to manage gages, refresh, or close.

# ---- Settings ---------------------------------------------------------------
# Starting gages (USGS site number = short name), used on first run only.
# After that, add/remove gages from the widget's right-click menu; they're kept in gage-widget-sites.json.
$DefaultSites = [ordered]@{
  '08096500' = 'Brazos at Waco'
  '08095000' = 'N Bosque nr Clifton'
  '08095300' = 'Middle Bosque nr McGregor'
}
$RefreshMinutes = 5       # how often to check for new readings; the history re-downloads only when one arrives
$LogScale       = $false   # $true = log10 discharge axes, $false = linear
$ApiKey         = $env:API_USGS_PAT   # optional USGS API key, read from a Windows environment variable; never paste it here
# -----------------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -Namespace W32 -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@

$C = @{ text = '#EEF3F1'; sub = '#A8BDB9'; dim = '#7E9894'; line = '#E3C38A'; grid = '#1EFFFFFF'; err = '#F0937A' }
$Inv     = [Globalization.CultureInfo]::InvariantCulture
$HistoryHours = 48   # hydrograph length
$NS      = "xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'"
$PosFile   = Join-Path $PSScriptRoot 'gage-widget.pos'
$SitesFile = Join-Path $PSScriptRoot 'gage-widget-sites.json'
$IconFile  = Join-Path $PSScriptRoot 'gage-widget.ico'

$script:Series      = @{}   # key 'USGS-<id>|<pcode>' -> points sorted by time
$script:Latest      = @{}
$script:NextFetch   = Get-Date
$script:Status      = 'Loading...'
$script:StatusColor = $C.dim
$script:OnDesk      = $null
$script:DragId      = $null   # gage being reordered
$script:Plot        = @{}      # gage id -> plotted points (pixel x/y, time, value) for the hover readout
$script:Hover       = $false   # mouse is over a hydrograph
$script:Stale       = $false   # a redraw was put off while hovering

# ---- Gage list --------------------------------------------------------------
# Sites = gages on the widget; Known = every gage ever added (feeds the dropdown)
function Load-Sites {
  $script:Sites = [ordered]@{}; $script:Known = [ordered]@{}
  if (Test-Path $SitesFile) {
    $j = Get-Content $SitesFile -Raw | ConvertFrom-Json
    $j.sites.psobject.Properties | ForEach-Object { $script:Sites[$_.Name] = $_.Value }
    $j.known.psobject.Properties | ForEach-Object { $script:Known[$_.Name] = $_.Value }
  } else {
    foreach ($id in $DefaultSites.Keys) { $script:Sites[$id] = $script:Known[$id] = $DefaultSites[$id] }
  }
}
function Save-Sites { @{ sites = $script:Sites; known = $script:Known } | ConvertTo-Json | Set-Content $SitesFile -Encoding UTF8 }

# ---- Data -------------------------------------------------------------------
function Get-Points($collection, $extra = '') {
  if (-not $script:Sites.Count) { return @{} }
  $ids = ($script:Sites.Keys | ForEach-Object { '"USGS-' + $_ + '"' }) -join ','
  $cql = '{"op":"and","args":[' +
         '{"op":"in","args":[{"property":"monitoring_location_id"},[' + $ids + ']]},' +
         '{"op":"in","args":[{"property":"parameter_code"},["00060","00065"]]}]}'
  $uri = "https://api.waterdata.usgs.gov/ogcapi/v1/collections/$collection/items?f=json&skipGeometry=true" +
         "&limit=10000&properties=monitoring_location_id,parameter_code,time_series_id,time,value$extra"
  $out = @{}
  $hdr = @{}; if ($ApiKey) { $hdr['X-Api-Key'] = $ApiKey }
  (Invoke-RestMethod -Method Post -Uri $uri -Headers $hdr -ContentType 'application/query-cql-json' -Body $cql -TimeoutSec 30 -UseBasicParsing).features.properties |
    Where-Object { "$($_.value)" -ne '' } |
    ForEach-Object { [pscustomobject]@{
      k  = "$($_.monitoring_location_id)|$($_.parameter_code)"
      ts = $_.time_series_id
      t  = ([datetimeoffset]$_.time).LocalDateTime
      v  = [double]$_.value } } |
    Sort-Object t |
    Group-Object k, ts |
    ForEach-Object {   # a gage can carry more than one series per parameter; keep the most current
      $g = @($_.Group); $k = $g[0].k
      if (-not $out[$k] -or $g[-1].t -gt $out[$k][-1].t) { $out[$k] = $g }
    }
  $out
}

function Update-Data([switch]$Force) {
  $script:NextFetch = (Get-Date).AddMinutes($RefreshMinutes)
  try {
    # latest-continuous carries the newest readings; the continuous history can lag behind it
    $fresh = Get-Points 'latest-continuous'
    $newer  = $fresh.Keys | Where-Object { -not $script:Latest[$_] -or $fresh[$_][-1].t -gt $script:Latest[$_][-1].t }
    if ($Force -or $newer -or -not $script:Series.Count) { $script:Series = Get-Points 'continuous' "&time=PT$($HistoryHours)H" }
    foreach ($k in $fresh.Keys) {   # tack the newest reading onto the history if the history hasn't caught up
      $p = $fresh[$k][-1]; $hist = $script:Series[$k]
      if (-not $hist) { $script:Series[$k] = @($p) } elseif ($p.t -gt $hist[-1].t) { $script:Series[$k] = @($hist) + $p }
    }
    $script:Latest      = $fresh
    $script:Status      = 'Updated {0:h:mm tt}' -f (Get-Date)
    $script:StatusColor = $C.dim
  } catch {
    $why = if ([int]$_.Exception.Response.StatusCode -eq 429) { 'USGS rate limit hit' } else { "Couldn't reach USGS" }
    $script:NextFetch   = (Get-Date).AddMinutes(2)   # retry soon, e.g. network not up at login
    $script:Status      = '{0}. Retrying {1:h:mm tt}.' -f $why, $script:NextFetch
    $script:StatusColor = $C.err
  }
}

# ---- Formatting -------------------------------------------------------------
function Num($x) { [string]::Format($Inv, '{0:0.#}', $x) }
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }

function Format-Value($x) {
  if ($x -ge 100) { '{0:N0}' -f $x } elseif ($x -ge 10) { '{0:N1}' -f $x } else { '{0:N2}' -f $x }
}

function Format-When([datetime]$t) {
  $now = Get-Date; $age = $now - $t
  $abs = if ($t.Date -eq $now.Date) { $t.ToString('h:mm tt') } else { $t.ToString('MMM d, h:mm tt') }
  $rel = if ($age.TotalMinutes -lt 90) { '{0:N0} min ago' -f $age.TotalMinutes } else { '{0:N0} h ago' -f $age.TotalHours }
  "$abs, $rel"
}

# ---- Drawing ----------------------------------------------------------------
$GripDots = (0, 3.6 | ForEach-Object { $x = $_; 0, 4.2, 8.4 | ForEach-Object {
  "<Ellipse Width='2.4' Height='2.4' Fill='$($C.sub)' Canvas.Left='$x' Canvas.Top='$_'/>" } }) -join ''

function Chart-Xaml($pts, $id) {
  $W = 230; $H = 62; $now = Get-Date; $t0 = $now.AddHours(-$HistoryHours)
  function PX($t) { ($t - $t0).TotalHours / $HistoryHours * $W }
  function TY($v) { if ($LogScale) { [math]::Log10([math]::Max([double]$v, 0.01)) } else { $v } }   # zero flow sits at 0.01 on log axes
  function UY($a) { if ($LogScale) { [math]::Pow(10, $a) } else { $a } }
  function AY($a) { 3 + (1 - ($a - $lo) / ($hi - $lo)) * ($H - 6) }                         # axis value -> pixel
  function PY($v) { AY (TY $v) }
  $sb = New-Object Text.StringBuilder

  # gridline every 6 h; labels at midnight (day name) and noon
  $tick = $t0.Date.AddHours(6 * [math]::Floor($t0.Hour / 6))
  while ($tick -le $t0) { $tick = $tick.AddHours(6) }
  for (; $tick -lt $now; $tick = $tick.AddHours(6)) {
    $tx = PX $tick; $major = $tick.Hour % 12 -eq 0
    [void]$sb.Append("<Line X1='$(Num $tx)' X2='$(Num $tx)' Y1='0' Y2='$H' Stroke='$(if ($major) { $C.grid } else { '#0EFFFFFF' })'/>")
    if ($major) {
      $lab = if ($tick.Hour) { '12 PM' } else { $tick.ToString('ddd', $Inv) }
      [void]$sb.Append("<TextBlock Canvas.Left='$(Num ($tx - 20))' Canvas.Top='$($H + 4)' Width='40' TextAlignment='Center' Text='$lab' FontSize='9.5' Foreground='$($C.dim)'/>")
    }
  }

  $pts = @($pts | Where-Object { $_.t -ge $t0 })
  if ($pts.Count -lt 2) {
    [void]$sb.Append("<TextBlock Canvas.Top='$($H / 2 - 8)' Width='$W' TextAlignment='Center' Text='No discharge in the last $HistoryHours h' FontSize='10.5' Foreground='$($C.dim)'/>")
  } else {
    $tv = $pts | ForEach-Object { TY $_.v }
    $lo = ($tv | Measure-Object -Minimum).Minimum
    $hi = ($tv | Measure-Object -Maximum).Maximum
    if ($hi -eq $lo) { if ($LogScale) { $hi += 0.1; $lo -= 0.1 } else { $hi += 1; $lo = [math]::Max(0, $lo - 1) } }
    $xy = @($pts | ForEach-Object { [pscustomobject]@{ x = PX $_.t; y = PY $_.v; t = $_.t; v = $_.v } })
    $script:Plot[$id] = $xy
    $line  = ($xy | ForEach-Object { '{0},{1}' -f (Num $_.x), (Num $_.y) }) -join ' '
    $first = $xy[0]; $last = $xy[-1]
    foreach ($a in $hi, $lo) {
      $y = AY $a
      [void]$sb.Append("<Line X1='0' X2='$W' Y1='$(Num $y)' Y2='$(Num $y)' Stroke='$($C.grid)'/>")
      [void]$sb.Append("<TextBlock Canvas.Left='-46' Canvas.Top='$(Num ($y - 7))' Width='40' TextAlignment='Right' Text='$(Format-Value (UY $a))' FontSize='9.5' Foreground='$($C.dim)'/>")
    }
    [void]$sb.Append("<Polygon Points='$line $(Num $last.x),$H $(Num $first.x),$H'><Polygon.Fill><LinearGradientBrush StartPoint='0,0' EndPoint='0,1'><GradientStop Color='#55E3C38A' Offset='0'/><GradientStop Color='#00E3C38A' Offset='1'/></LinearGradientBrush></Polygon.Fill></Polygon>")
    [void]$sb.Append("<Polyline Points='$line' Stroke='$($C.line)' StrokeThickness='1.6' StrokeLineJoin='Round'/>")
    [void]$sb.Append("<Ellipse Width='5' Height='5' Fill='$($C.line)' Canvas.Left='$(Num ($last.x - 2.5))' Canvas.Top='$(Num ($last.y - 2.5))'/>")
    # hover: transparent hit area over the plot; readout pieces stay hidden until the mouse is on it
    [void]$sb.Append("<Rectangle Name='Hit' Width='$W' Height='$H' Fill='Transparent'/>")
    [void]$sb.Append("<Line Name='HoverLine' Y1='0' Y2='$H' Stroke='#66FFFFFF' StrokeThickness='1' Visibility='Collapsed' IsHitTestVisible='False'/>")
    [void]$sb.Append("<Ellipse Name='HoverDot' Width='7' Height='7' Fill='$($C.line)' Stroke='#142B30' StrokeThickness='1.5' Visibility='Collapsed' IsHitTestVisible='False'/>")
    [void]$sb.Append("<Border Name='HoverTip' Visibility='Collapsed' IsHitTestVisible='False' Background='#F5203B41' BorderBrush='#33FFFFFF' BorderThickness='1' CornerRadius='5' Padding='7,2,7,4'><StackPanel><TextBlock Name='TipValue' FontFamily='Bahnschrift, Segoe UI' FontSize='14' Foreground='$($C.text)'/><TextBlock Name='TipTime' FontSize='10' Foreground='$($C.sub)'/></StackPanel></Border>")
  }
  "<Canvas Width='290' Height='$($H + 20)'><Canvas Canvas.Left='46' Canvas.Top='6'>$sb</Canvas></Canvas>"
}

# readout for the reading nearest the cursor's time; box sits beside the cursor, flipping left near the edge
function Show-Hover($hv, $m) {
  $script:Hover = $true
  $p = $hv.pts[0]
  foreach ($pt in $hv.pts) { if ([math]::Abs($pt.x - $m.X) -lt [math]::Abs($p.x - $m.X)) { $p = $pt } }
  $hv.line.X1 = $p.x; $hv.line.X2 = $p.x
  [Windows.Controls.Canvas]::SetLeft($hv.dot, $p.x - 3.5); [Windows.Controls.Canvas]::SetTop($hv.dot, $p.y - 3.5)
  $hv.val.Text  = '{0} cfs' -f (Format-Value $p.v)
  $hv.when.Text = $p.t.ToString('ddd h:mm tt')
  foreach ($el in $hv.line, $hv.dot, $hv.tip) { $el.Visibility = 'Visible' }
  $hv.tip.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
  $tw = $hv.tip.DesiredSize.Width; $th = $hv.tip.DesiredSize.Height
  $left = if ($m.X + 14 + $tw -le $hv.w + 12) { $m.X + 14 } else { $m.X - 14 - $tw }
  $top  = [math]::Min([math]::Max($m.Y - $th / 2, -4), $hv.h + 14 - $th)
  [Windows.Controls.Canvas]::SetLeft($hv.tip, $left); [Windows.Controls.Canvas]::SetTop($hv.tip, $top)
}

function Hide-Hover($hv) {
  foreach ($el in $hv.line, $hv.dot, $hv.tip) { $el.Visibility = 'Collapsed' }
  $script:Hover = $false
  if ($script:Stale) { Show-Rows }
}

function Row-Xaml($id, $name) {
  $q = $script:Series["USGS-$id|00060"]
  $hs = $script:Series["USGS-$id|00065"]
  $qTxt  = if ($q) { Format-Value $q[-1].v } else { '--' }
  $stage = if ($hs) { "<Run Text='     '/><Run Text='$('{0:N2}' -f $hs[-1].v)' FontFamily='Bahnschrift, Segoe UI' FontSize='17' Foreground='$($C.sub)'/><Run Text=' ft' FontSize='11' Foreground='$($C.dim)'/>" }
  $when  = if ($q) { Format-When $q[-1].t } elseif ($hs) { Format-When $hs[-1].t } else { 'No recent data' }
@"
<Grid $NS Tag='$id' Background='Transparent'>
  <Grid.ColumnDefinitions><ColumnDefinition Width='200'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
  <Canvas Width='0' HorizontalAlignment='Left' VerticalAlignment='Center'>
    <Grid Name='Grip' Tag='$id' Canvas.Left='-18' Canvas.Top='-20' Width='14' Height='40' Background='Transparent' Cursor='SizeNS' ToolTip='Drag to reorder'>
      <Grid.Style><Style TargetType='Grid'><Setter Property='Opacity' Value='0'/><Style.Triggers>
        <DataTrigger Binding='{Binding IsMouseOver, RelativeSource={RelativeSource AncestorType=Grid}}' Value='True'><Setter Property='Opacity' Value='1'/></DataTrigger>
      </Style.Triggers></Style></Grid.Style>
      <Canvas Width='6' Height='11' HorizontalAlignment='Center' VerticalAlignment='Center'>$GripDots</Canvas>
    </Grid>
  </Canvas>
  <StackPanel VerticalAlignment='Center'>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <TextBlock Text='$(Esc $name)' FontFamily='Segoe UI Semibold' FontSize='13' Foreground='$($C.text)' TextTrimming='CharacterEllipsis'/>
      <TextBlock Grid.Column='1' Text='$id' FontSize='10.5' Foreground='$($C.dim)' Margin='8,0,0,1' VerticalAlignment='Bottom'/>
    </Grid>
    <TextBlock><Run Text='$qTxt' FontFamily='Bahnschrift Light, Bahnschrift, Segoe UI' FontSize='30' Foreground='$($C.text)'/><Run Text=' cfs' FontSize='11' Foreground='$($C.dim)'/>$stage</TextBlock>
    <TextBlock Text='$(Esc $when)' FontSize='10.5' Foreground='$($C.dim)'/>
  </StackPanel>
  <Border Grid.Column='1' Margin='14,0,0,0'>$(Chart-Xaml $q $id)</Border>
</Grid>
"@
}

function Show-Rows {
  $script:Hover = $false; $script:Stale = $false
  $rows.Children.Clear()
  $i = 0
  foreach ($id in $script:Sites.Keys) {
    if ($i++) { [void]$rows.Children.Add([Windows.Markup.XamlReader]::Parse("<Rectangle $NS Height='1' Fill='$($C.grid)' Margin='0,10,0,10'/>")) }
    $row = [Windows.Markup.XamlReader]::Parse((Row-Xaml $id $script:Sites[$id]))
    if ($id -eq $script:DragId) { $row.Opacity = 0.55 }
    $row.FindName('Grip').Add_MouseLeftButtonDown({
      param($s, $e)
      $script:DragId = $s.Tag
      foreach ($el in $rows.Children) { if ($el.Tag -eq $s.Tag) { $el.Opacity = 0.55 } }
      [void]$rows.CaptureMouse()
      $e.Handled = $true   # don't start a window move
    })
    $hit = $row.FindName('Hit')
    if ($hit) {
      $hit.Tag = @{ pts = $script:Plot[$id]; w = $hit.Width; h = $hit.Height
                    line = $row.FindName('HoverLine'); dot = $row.FindName('HoverDot'); tip = $row.FindName('HoverTip')
                    val = $row.FindName('TipValue'); when = $row.FindName('TipTime') }
      $hit.Add_MouseMove({ param($s, $e) Show-Hover $s.Tag ($e.GetPosition($s)) })
      $hit.Add_MouseLeave({ param($s, $e) Hide-Hover $s.Tag })
    }
    [void]$rows.Children.Add($row)
  }
  if (-not $i) { [void]$rows.Children.Add([Windows.Markup.XamlReader]::Parse("<TextBlock $NS Text='No gages yet. Right-click to add one.' FontSize='12' Foreground='$($C.sub)' Margin='0,4,40,0'/>")) }
  $footer.Text       = $script:Status
  $footer.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($script:StatusColor)
}

# ---- Window -----------------------------------------------------------------
$win = [Windows.Markup.XamlReader]::Parse(@"
<Window $NS Title='Gage Widget' WindowStyle='None' AllowsTransparency='True' Background='Transparent'
        ShowInTaskbar='False' ResizeMode='NoResize' SizeToContent='WidthAndHeight'
        FontFamily='Segoe UI' UseLayoutRounding='True'>
  <Window.ContextMenu>
    <ContextMenu>
      <MenuItem Header='Manage gages...'/>
      <MenuItem Header='Refresh now'/>
      <MenuItem Header='Close'/>
    </ContextMenu>
  </Window.ContextMenu>
  <Border Background='#E8142B30' BorderBrush='#24FFFFFF' BorderThickness='1' CornerRadius='10' Padding='18,14,18,10'>
    <StackPanel>
      <StackPanel Name='Rows'/>
      <TextBlock Name='Status' Text='Loading...' FontSize='10' Foreground='$($C.dim)' Margin='0,10,0,0' HorizontalAlignment='Right'/>
    </StackPanel>
  </Border>
</Window>
"@)
$rows   = $win.FindName('Rows')
$footer = $win.FindName('Status')

if (Test-Path $PosFile) {
  $xy = (Get-Content $PosFile) -split ','
  $win.Left = [double]$xy[0]; $win.Top = [double]$xy[1]
} else {
  $area = [Windows.SystemParameters]::WorkArea
  $win.Left = $area.Right - 600; $win.Top = $area.Top + 40
}

$win.Add_MouseLeftButtonDown({
  $win.DragMove()
  '{0},{1}' -f [int]$win.Left, [int]$win.Top | Set-Content $PosFile
})
$win.ContextMenu.Items[0].Add_Click({ Show-Manage })
$win.ContextMenu.Items[1].Add_Click({ Update-Data -Force; Show-Rows })
$win.ContextMenu.Items[2].Add_Click({ $win.Close() })

# ---- Reorder by dragging a row's grip ---------------------------------------
$rows.Add_MouseMove({
  param($s, $e)
  if (-not $script:DragId) { return }
  $y = $e.GetPosition($rows).Y; $to = 0
  foreach ($el in $rows.Children) {   # new position = other rows whose midpoint is above the cursor
    if (-not $el.Tag -or $el.Tag -eq $script:DragId) { continue }
    if ($y -gt $el.TranslatePoint([Windows.Point]::new(0, 0), $rows).Y + $el.ActualHeight / 2) { $to++ }
  }
  if (@($script:Sites.Keys).IndexOf($script:DragId) -ne $to) {
    $name = $script:Sites[$script:DragId]
    $script:Sites.Remove($script:DragId); $script:Sites.Insert($to, $script:DragId, $name)
    Show-Rows; $rows.UpdateLayout()
  }
})
$rows.Add_MouseLeftButtonUp({ if ($script:DragId) { $rows.ReleaseMouseCapture() } })
$rows.Add_LostMouseCapture({ if ($script:DragId) { $script:DragId = $null; Save-Sites; Show-Rows } })

# ---- Manage gages dialog ----------------------------------------------------
function Fill-Manage {
  $d = $script:Dlg
  $d.Current.Children.Clear()
  foreach ($id in @($script:Sites.Keys)) {
    $g = [Windows.Markup.XamlReader]::Parse(@"
<Grid $NS Margin='0,2,0,2'>
  <Grid.ColumnDefinitions><ColumnDefinition Width='86'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
  <TextBlock Text='$id' Foreground='#5F6B6A' VerticalAlignment='Center'/>
  <TextBlock Grid.Column='1' Text='$(Esc $script:Sites[$id])' VerticalAlignment='Center' TextTrimming='CharacterEllipsis'/>
  <Button Grid.Column='2' Content='Remove' Padding='10,1' Tag='$id'/>
</Grid>
"@)
    $g.Children[2].Add_Click({ $script:Sites.Remove($this.Tag); Save-Sites; Fill-Manage })
    [void]$d.Current.Children.Add($g)
  }
  if (-not $script:Sites.Count) { [void]$d.Current.Children.Add([Windows.Markup.XamlReader]::Parse("<TextBlock $NS Text='None' Foreground='#5F6B6A'/>")) }

  # dropdown = saved gages not currently shown; picking one fills in its short name
  $d.Id.Items.Clear()
  foreach ($id in $script:Known.Keys) {
    if ($script:Sites.Contains($id)) { continue }
    $it = New-Object Windows.Controls.ComboBoxItem
    $it.Content = "$id   $($script:Known[$id])"; $it.Tag = $id
    [Windows.Controls.TextSearch]::SetText($it, $id)
    [void]$d.Id.Items.Add($it)
  }
  $d.Id.Text = ''; $d.Short.Text = ''; $d.Msg.Text = ''
}

function Show-Manage {
  $before = @($script:Sites.Keys) -join ','
  $dw = [Windows.Markup.XamlReader]::Parse(@"
<Window $NS Title='Gage Widget' SizeToContent='Height' Width='420' ResizeMode='NoResize'
        WindowStartupLocation='CenterScreen' FontFamily='Segoe UI' FontSize='12.5'>
  <StackPanel Margin='18,14,18,16'>
    <TextBlock Text='On the widget' FontFamily='Segoe UI Semibold' FontSize='13' Margin='0,0,0,6'/>
    <StackPanel Name='Current'/>
    <TextBlock Text='Add a gage' FontFamily='Segoe UI Semibold' FontSize='13' Margin='0,18,0,6'/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='150'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text='Gage ID (pick or type)' FontSize='11' Foreground='#5F6B6A' Margin='0,0,0,3'/>
      <TextBlock Grid.Column='1' Text='Short name' FontSize='11' Foreground='#5F6B6A' Margin='0,0,0,3'/>
      <ComboBox Name='Id' Grid.Row='1' IsEditable='True' Margin='0,0,8,0' Padding='4,3'/>
      <TextBox Name='Short' Grid.Row='1' Grid.Column='1' Margin='0,0,8,0' Padding='4,3' VerticalContentAlignment='Center'/>
      <Button Name='Add' Grid.Row='1' Grid.Column='2' Content='Add' Padding='14,3' IsDefault='True'/>
    </Grid>
    <TextBlock Name='Msg' Foreground='#B3402A' FontSize='11' Margin='0,6,0,0'/>
    <Button Content='Done' IsCancel='True' HorizontalAlignment='Right' Padding='18,3' Margin='0,10,0,0'/>
  </StackPanel>
</Window>
"@)
  if (Test-Path $IconFile) { $dw.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconFile) }
  $script:Dlg = @{}
  foreach ($n in 'Current', 'Id', 'Short', 'Msg', 'Add') { $script:Dlg[$n] = $dw.FindName($n) }

  $script:Dlg.Id.Add_SelectionChanged({
    $it = $script:Dlg.Id.SelectedItem
    if ($it) { $script:Dlg.Short.Text = $script:Known[$it.Tag] }
  })
  $script:Dlg.Add.Add_Click({
    $d = $script:Dlg; $id = $d.Id.Text.Trim(); $name = $d.Short.Text.Trim()
    if ($id -notmatch '^\d{8,15}$')  { $d.Msg.Text = 'Gage IDs are 8 to 15 digits.'; return }
    if ($script:Sites.Contains($id)) { $d.Msg.Text = "$id is already on the widget."; return }
    if (-not $name) { $name = if ($script:Known[$id]) { $script:Known[$id] } else { $id } }
    $script:Known.Remove($id)                      # re-adding moves it to the end
    $script:Sites[$id] = $script:Known[$id] = $name
    Save-Sites; Fill-Manage
  })

  Fill-Manage
  [void]$dw.ShowDialog()
  if ((@($script:Sites.Keys) -join ',') -ne $before) { Update-Data; Show-Rows }
}

# ---- Desktop layer ----------------------------------------------------------
# Owned by the desktop (Progman) so it always sits just above the wallpaper.
# Like Rainmeter: drop to the bottom while apps are in front; float on top while
# the desktop itself is in front (Win+D), so Show Desktop doesn't cover it.
$helper = New-Object Windows.Interop.WindowInteropHelper $win
$helper.Owner = [W32.U]::FindWindow('Progman', [NullString]::Value)

function Set-Layer([bool]$top) {
  $hw = $helper.Handle   # flags 0x13 = no size, no move, no activate
  if ($top) { [void][W32.U]::SetWindowPos($hw, [IntPtr]::new(-1), 0, 0, 0, 0, 0x13) }   # topmost
  else {
    [void][W32.U]::SetWindowPos($hw, [IntPtr]::new(-2), 0, 0, 0, 0, 0x13)              # not topmost
    [void][W32.U]::SetWindowPos($hw, [IntPtr]::new(1), 0, 0, 0, 0, 0x13)               # bottom
  }
}

$layerTimer = New-Object Windows.Threading.DispatcherTimer
$layerTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$layerTimer.Add_Tick({
  $fg = [W32.U]::GetForegroundWindow()
  if ($fg -eq $helper.Handle) { $script:OnDesk = $null; return }
  $cls = New-Object Text.StringBuilder 32
  [void][W32.U]::GetClassName($fg, $cls, 32)
  $desk = $cls.ToString() -in 'Progman', 'WorkerW'
  if ($desk -ne $script:OnDesk) { $script:OnDesk = $desk; Set-Layer $desk }
})

# one-minute tick keeps the time axis and "min ago" current; fetches only when due
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes(1)
$timer.Add_Tick({
  if ((Get-Date) -ge $script:NextFetch) { Update-Data }
  if ($script:Hover) { $script:Stale = $true } else { Show-Rows }   # don't yank a readout out from under the mouse
})

Load-Sites
$win.Add_ContentRendered({ Update-Data; Show-Rows; $timer.Start(); $layerTimer.Start() })
[void]$win.ShowDialog()
