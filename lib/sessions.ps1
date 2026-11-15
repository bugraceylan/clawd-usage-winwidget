# ----------------------------------------------------------- sessions ----
# Claude Code keeps its own registry of running sessions: sessions\<pid>.json in its
# folder (Get-ClaudeConfigDir, ~/.claude by default), with name, folder and busy/idle
# status. A file can outlive its process, so check the process is alive and is the
# same process (procStart - start FILETIME).

$SessionsDir = [System.IO.Path]::Combine((Get-ClaudeConfigDir), 'sessions')

function Get-Sessions {
    $own = @()
    foreach ($p in @($script:UsageProc, $script:AuthProc)) { if ($p) { $own += $p.Id } }
    if ($script:ChatProc) { $own += $script:ChatProc.proc.Id }
    $list = @()
    foreach ($f in @(Get-ChildItem $SessionsDir -Filter *.json -ErrorAction SilentlyContinue)) {
        try { $j = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not $j.pid -or $own -contains $j.pid) { continue }
        $proc = Get-Process -Id $j.pid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        try {
            if ($j.procStart -and
                [math]::Abs($proc.StartTime.ToFileTimeUtc() - [int64]$j.procStart) -gt 50000000) { continue }
        } catch {}
        $name = [string]$j.name
        if (-not $name -and $j.cwd) { $name = Split-Path -Leaf $j.cwd }
        # waiting - the session waits for the user: permission, question, dialog (see waitingFor).
        $list += @{ name = $name; cwd = [string]$j.cwd; busy = ($j.status -eq 'busy')
                    waiting = ($j.status -eq 'waiting'); waitingFor = [string]$j.waitingFor
                    kind = [string]$j.kind; sessionId = [string]$j.sessionId; pid = [int]$j.pid
                    started = $proc.StartTime }
    }
    return ,$list
}

# Sessions published by other machines (remoteSessions in config.json): URLs or file
# paths, each returning { generatedAt, host, sessions = [ <session json> ] }, already
# filtered to live sessions by the publisher, so there is no process check here.
# Each source is fetched in the background; a failed, hung or stale source simply
# contributes no sessions.

$RemoteStaleSeconds = 120   # a feed (or our last good fetch of it) older than this is ignored
$RemoteHungSeconds  = 30    # a fetch still running after this is cancelled

$script:RemoteSess = @{}    # source -> @{ wc; task; try; at; list }

function ConvertTo-RemoteSessions($text) {
    $j = $text | ConvertFrom-Json
    if ($j.generatedAt) {
        $age = ([datetimeoffset]::UtcNow - [datetimeoffset]::Parse([string]$j.generatedAt)).TotalSeconds
        if ($age -gt $RemoteStaleSeconds) { return ,@() }
    }
    $host_ = [string]$j.host
    $items = $(if ($null -ne $j.sessions) { $j.sessions } else { $j })
    $list = @()
    foreach ($s in @($items)) {
        if (-not $s -or $s -is [string]) { continue }
        $name = [string]$s.name
        if (-not $name -and $s.cwd) { $name = Split-Path -Leaf ([string]$s.cwd) }
        if (-not $name -and $s.sessionId) { $name = ([string]$s.sessionId).Substring(0, [math]::Min(8, ([string]$s.sessionId).Length)) }
        $list += @{ name = $name; cwd = [string]$s.cwd; busy = ($s.status -eq 'busy')
                    waiting = ($s.status -eq 'waiting'); waitingFor = [string]$s.waitingFor
                    kind = [string]$s.kind; sessionId = [string]$s.sessionId; pid = 0; host = $host_ }
    }
    return ,$list
}

# A source can also be a GitHub gist - "gist:<id>" or the gist's page address - written
# by remote\clawd-sessions-publish.sh on a machine on another network. It is read
# through GitHub's API: the gist's raw address is cached for minutes, the API is not.
# Without a token GitHub allows 60 reads an hour, so the gist is read every
# $GistAnonSeconds; with one (githubToken in config.json, or the gh CLI's login) as
# often as the local sessions. A failed read keeps the last list until it goes stale.

$GistAnonSeconds = 75
$script:GistToken = $null   # $null - not looked up yet; '' - none

function Get-GistId([string]$src) {
    $m = [regex]::Match($src, '^(?:gist:|https?://gist\.github\.com/(?:[^/]+/)?)([0-9a-fA-F]{20,})/?$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-GistToken {
    if ($null -ne $script:GistToken) { return $script:GistToken }
    $script:GistToken = ([string]$script:Cfg.githubToken).Trim()
    if (-not $script:GistToken) {
        try {
            $gh = (Get-Command gh -ErrorAction Stop).Source
            $t = & $gh auth token 2>$null
            if ($LASTEXITCODE -eq 0 -and $t) { $script:GistToken = ([string]$t).Trim() }
        } catch {}
    }
    return $script:GistToken
}

# GitHub's answer about a gist -> the feed inside it (sessions.json, or its only file).
function Get-GistFeedText([string]$text) {
    $g = $text | ConvertFrom-Json
    $files = @($g.files.PSObject.Properties | ForEach-Object { $_.Value })
    $f = @($files | Where-Object { $_.filename -eq 'sessions.json' })[0]
    if (-not $f) { $f = $files[0] }
    if (-not $f -or $f.truncated) { throw 'no feed in the gist' }
    return [string]$f.content
}

# Collects finished fetches, starts the due ones and returns the sessions from all
# sources that answered recently. $local - the local sessions, to drop duplicates.
function Get-RemoteSessions($local) {
    $sources = @($script:Cfg.remoteSessions | Where-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($k in @($script:RemoteSess.Keys)) {
        if ($sources -notcontains $k) {
            try { $script:RemoteSess[$k].wc.CancelAsync() } catch {}
            $script:RemoteSess.Remove($k)
        }
    }
    $now = Get-Date
    $out = @()
    foreach ($src in $sources) {
        $r = $script:RemoteSess[$src]
        if (-not $r) { $r = @{ wc = $null; task = $null; try = [datetime]::MinValue; at = [datetime]::MinValue; list = @() }; $script:RemoteSess[$src] = $r }
        $gist = Get-GistId $src
        if ($r.task -and $r.task.IsCompleted) {
            if ($r.task.Status -eq 'RanToCompletion') {
                try {
                    $text = $(if ($gist) { Get-GistFeedText $r.task.Result } else { $r.task.Result })
                    $r.list = ConvertTo-RemoteSessions $text; $r.at = $now
                } catch { if (-not $gist) { $r.list = @() } }
            } elseif (-not $gist) { $r.list = @() }
            $r.task = $null
        } elseif ($r.task -and ($now - $r.try).TotalSeconds -gt $RemoteHungSeconds) {
            try { $r.wc.CancelAsync() } catch {}
            $r.task = $null
        }
        $every = [double]$script:Cfg.refreshSeconds - 1
        if ($gist -and -not (Get-GistToken)) { $every = [math]::Max($every, $GistAnonSeconds) }
        if (-not $r.task -and ($now - $r.try).TotalSeconds -ge $every) {
            $r.try = $now
            try {
                # WebClient reads file paths too (as file:// URIs), so both go the same way.
                $uri = $(if ($gist) { New-Object Uri "https://api.github.com/gists/$gist" }
                         elseif ($src -match '^[a-z][a-z0-9+.-]+://') { New-Object Uri $src }
                         else { New-Object Uri ([System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($src))) })
                $wc = New-Object System.Net.WebClient
                $wc.Encoding = [System.Text.Encoding]::UTF8
                $wc.Headers['Cache-Control'] = 'no-cache'
                if ($gist) {
                    # GitHub's API turns away requests without a User-Agent.
                    $wc.Headers['User-Agent'] = 'clawd-usage-winwidget'
                    $wc.Headers['Accept'] = 'application/vnd.github+json'
                    $tok = Get-GistToken
                    if ($tok) { $wc.Headers['Authorization'] = "Bearer $tok" }
                }
                $r.wc = $wc
                $r.task = $wc.DownloadStringTaskAsync($uri)
            } catch { $r.task = $null }
        }
        if (($now - $r.at).TotalSeconds -le $RemoteStaleSeconds) { $out += $r.list }
    }
    $ids = @($local | ForEach-Object { $_.sessionId } | Where-Object { $_ })
    return ,@($out | Where-Object { -not $_.sessionId -or $ids -notcontains $_.sessionId })
}

# ------------------------------------------------------- the session rows ----
# One row per running session at the bottom of the window (showSessionList): a dot -
# green working, yellow waiting for you, grey idle - the name, the state and how long
# the session has been in it. Claude Code's registry keeps no "since", so the widget
# notes when it first saw each state: a session already running at start counts from then.
# Waiting first, then working, then idle; the longest in its state first.

$SessionRowsMax     = 8
$script:SessSince   = @{}   # session key -> @{ state; at }
$script:SessRowsKey = $null

function Get-SessionState($s) {
    if ($s.waiting) { return 'waiting' }
    if ($s.busy) { return 'busy' }
    return 'idle'
}

function Format-Elapsed([timespan]$t) {
    if ($t.TotalMinutes -lt 1) { return '' }
    if ($t.TotalHours -ge 24) { return ((T 'span.d') -f $t.Days, $t.Hours) }
    if ($t.TotalHours -ge 1)  { return ((T 'span.h') -f [math]::Floor($t.TotalHours), $t.Minutes) }
    return ((T 'span.m') -f $t.Minutes)
}

# What each row shows, worked out apart from WPF so tools\integration-test.ps1 can check it.
function Get-SessionRowModels($ss, [datetime]$now = (Get-Date)) {
    $seen = @{}
    $rows = @()
    foreach ($s in @($ss)) {
        if (-not $s) { continue }
        $key = $(if ($s.sessionId) { [string]$s.sessionId } elseif ($s.pid) { "pid:$($s.pid)" } else { "$($s.host)/$($s.name)" })
        $state = Get-SessionState $s
        $since = $script:SessSince[$key]
        if (-not $since -or $since.state -ne $state) {
            $since = @{ state = $state; at = $now }
            $script:SessSince[$key] = $since
        }
        $seen[$key] = $true
        $rows += @{ s = $s; state = $state; at = $since.at }
    }
    foreach ($k in @($script:SessSince.Keys)) { if (-not $seen[$k]) { $script:SessSince.Remove($k) } }

    $rank = @{ waiting = 0; busy = 1; idle = 2 }
    $out = @()
    foreach ($r in @($rows | Sort-Object { $rank[$_.state] }, { $_.at })) {
        $s = $r.s
        $word = $(switch ($r.state) {
            'waiting' { if ($s.waitingFor) { [string]$s.waitingFor } else { T 'sess.rowWait' } }
            'busy'    { T 'sess.rowBusy' }
            default   { T 'sess.rowIdle' }
        })
        $for = Format-Elapsed ($now - $r.at)
        $name = [string]$s.name
        if (-not $name) { $name = '?' }
        if ($s.host) { $name += " @$($s.host)" }
        $where = $(if ($s.host -and $s.cwd) { "$($s.host): $($s.cwd)" } elseif ($s.host) { [string]$s.host } else { [string]$s.cwd })
        $out += @{
            state = $r.state
            name  = $name
            text  = $(if ($for) { "$word · $for" } else { $word })
            tip   = $where
        }
    }
    return ,$out
}

function New-SessionRow($m) {
    $dot  = $(switch ($m.state) { 'waiting' { $Palette.warn.Wpf } 'busy' { $Palette.ok.Wpf } default { '#FF52525B' } })
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness 0, 1.5, 0, 1.5
    $g.Background = [System.Windows.Media.Brushes]::Transparent
    foreach ($w in @([System.Windows.GridLength]::Auto, (New-Object System.Windows.GridLength 1, 'Star'), [System.Windows.GridLength]::Auto)) {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = $w
        $g.ColumnDefinitions.Add($c)
    }
    $e = New-Object System.Windows.Shapes.Ellipse
    $e.Width = 6; $e.Height = 6
    $e.Fill = New-Brush $dot
    $e.VerticalAlignment = 'Center'
    $e.Margin = New-Object System.Windows.Thickness 1, 0, 7, 0
    [void]$g.Children.Add($e)

    $n = New-Object System.Windows.Controls.TextBlock
    $n.Text = $m.name
    $n.FontFamily = 'Segoe UI'; $n.FontSize = 10
    $n.Foreground = New-Brush $(if ($m.state -eq 'idle') { '#FF8B8B94' } else { '#FFD4D4D8' })
    $n.TextTrimming = 'CharacterEllipsis'
    $n.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($n, 1)
    [void]$g.Children.Add($n)

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $m.text
    $t.FontFamily = 'Segoe UI'; $t.FontSize = 9.5
    $t.Foreground = New-Brush $(if ($m.state -eq 'waiting') { $Palette.warn.Wpf } else { '#FF6B7280' })
    $t.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
    $t.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($t, 2)
    [void]$g.Children.Add($t)

    if ($m.tip) {
        $g.ToolTip = $m.tip
        [System.Windows.Controls.ToolTipService]::SetShowDuration($g, 60000)
    }
    return $g
}

# Rebuilt only when something on it changed - a tooltip being read stays open.
function Update-SessionRows($ss) {
    $models = Get-SessionRowModels $ss
    $shown  = @($models | Select-Object -First $SessionRowsMax)
    $more   = $models.Count - $shown.Count
    $key = (@($shown | ForEach-Object { "$($_.state)|$($_.name)|$($_.text)|$($_.tip)" }) + "+$more") -join "`n"
    if ($key -eq $script:SessRowsKey) { return }
    $script:SessRowsKey = $key
    $UI.SessionRows.Children.Clear()
    foreach ($m in $shown) { [void]$UI.SessionRows.Children.Add((New-SessionRow $m)) }
    if ($more -gt 0) {
        $x = New-Object System.Windows.Controls.TextBlock
        $x.Text = (T 'sess.more') -f $more
        $x.FontFamily = 'Segoe UI'; $x.FontSize = 9.5
        $x.Foreground = New-Brush '#FF6B7280'
        $x.Margin = New-Object System.Windows.Thickness 14, 1, 0, 0
        [void]$UI.SessionRows.Children.Add($x)
    }
    $UI.SessionRows.Visibility = $(if ($shown.Count) { 'Visible' } else { 'Collapsed' })
}
