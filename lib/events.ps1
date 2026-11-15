# ---------------------------------------------------------------- events ----

$border = $win.Content
$border.add_MouseLeftButtonDown({
    try {
        $win.DragMove()
        # Save the position right after dragging: if the process is killed hard,
        # the coordinates are still not lost.
        $script:Cfg.left = [math]::Round($win.Left)
        $script:Cfg.top  = [math]::Round($win.Top)
        Save-Config $script:Cfg
    } catch {}
})

# The bottom edge: drag down for a taller session list, up for a shorter one; pulled
# past the last row or double-clicked - all the rows again, growing with new sessions.
# Measured against the sessions block, whose top stays put: its units are the
# window's before scaling, so the drag follows the mouse at any scale.
$UI.ResizeGrip.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true   # not a window drag
    if ($e.ClickCount -ge 2) { $script:GripDrag = $null; Set-Setting 'sessionListHeight' $null; return }
    $script:GripDrag = @{ y = $e.GetPosition($UI.SessionsPanel).Y; h = $UI.SessionScroll.ActualHeight }
    [void]$UI.ResizeGrip.CaptureMouse()
})
$UI.ResizeGrip.add_MouseMove({
    param($s, $e)
    $d = $script:GripDrag
    if (-not $d) { return }
    $UI.SessionScroll.MaxHeight = [math]::Max($SessionListMinHeight, $d.h + $e.GetPosition($UI.SessionsPanel).Y - $d.y)
})
$UI.ResizeGrip.add_MouseLeftButtonUp({
    param($s, $e)
    if (-not $script:GripDrag) { return }
    $e.Handled = $true
    $script:GripDrag = $null
    $UI.ResizeGrip.ReleaseMouseCapture()
    $h = [math]::Round($UI.SessionScroll.MaxHeight)
    Set-Setting 'sessionListHeight' $(if ($h -ge $UI.SessionRows.ActualHeight) { $null } else { $h })
})
# Capture taken away (another window, Esc): back to the saved height.
$UI.ResizeGrip.add_LostMouseCapture({
    if ($script:GripDrag) { $script:GripDrag = $null; Update-Widget }
})
$UI.ResizeGrip.add_MouseEnter({ $UI.ResizeMark.Background = New-Brush '#FF6B7280' })
$UI.ResizeGrip.add_MouseLeave({ $UI.ResizeMark.Background = New-Brush '#FF3F3F46' })

function Set-Details([bool]$open) {
    if ($open) {
        $UI.Details.Visibility = 'Visible'
        $UI.BtnToggle.Text     = [char]0x25B4
    } else {
        $UI.Details.Visibility = 'Collapsed'
        $UI.BtnToggle.Text     = [char]0x25BE
    }
    $script:Cfg.expanded = $open
    Save-Config $script:Cfg
}

$UI.BtnToggle.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Set-Details ($UI.Details.Visibility -ne 'Visible')
})
# Opened on button up, as the panel: on button down the widget itself takes focus.
$UI.BtnSettings.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$UI.BtnSettings.add_MouseLeftButtonUp({
    param($s, $e)
    $e.Handled = $true
    if ($setWin.IsVisible) { $setWin.Hide() } else { Show-Settings }
})
$UI.BtnHide.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $win.Hide()
})
# Claude Code's version: with an update out - update, otherwise its changelog.
$UI.LineVersion.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    if (Test-UpdateAvailable) {
        Start-ClaudeUpdate
        Update-Widget
    } else {
        Start-Process $ChangelogPage
    }
})
$UI.LineClawdVer.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    # A new release out - update to it; otherwise the changelog.
    if (Test-ClawdUpdate) { Start-ClawdUpdate; $script:ClawdVerKey = $null; Update-Widget }
    else                  { Open-ClawdChangelog }
})
$UI.Mascot.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:Mz.idleSince = Get-Date
    Start-MascotClick
})
# The panel opens on button up: on button down the widget itself takes focus,
# which would hide a panel opened at that moment.
$UI.TipBadge.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$UI.TipBadge.add_MouseLeftButtonUp({
    param($s, $e)
    $e.Handled = $true
    Show-Panel
})
# A reminder's Windows notification clicked - straight to the chat.
$notify.add_BalloonTipClicked({ if (-not $advWin.IsVisible) { Show-Panel } })
$UI.StatusRow.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Start-Process $StatusUrl
})
$UI.BtnExit.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Stop-Widget
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([double]$script:Cfg.refreshSeconds)
$timer.add_Tick({
    try { Update-Widget } catch {
        $UI.LineStamp.Text = T 'error'
        try {
            "$(Get-Date -Format s)`t$($_.Exception.Message)`t$($_.InvocationInfo.PositionMessage)" |
                Out-File (Join-Path $script:Root 'widget-error.log') -Append -Encoding utf8
        } catch {}
    }
})
$timer.Start()

# The /usage reply arrives in a couple of seconds - after start and a manual refresh
# pick it up before the full tick.
$kick = New-Object System.Windows.Threading.DispatcherTimer
$kick.Interval = [TimeSpan]::FromSeconds(1)
$kick.add_Tick({
    Collect-UsageProbe
    if (-not $script:UsageProc) {
        $kick.Stop()
        try { Update-Widget } catch {}
    }
})
