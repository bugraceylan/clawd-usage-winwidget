#requires -version 5
<#
  Combined PR regressions on fixed data: translations, cultures, main-limit
  mapping and mascot state transitions. No CLI, network, window or user data.
#>
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$script:Cfg = @{ language = 'en'; mainLimit = 'session' }
$script:Checked = 0

function Check([string]$name, [bool]$ok) {
    $script:Checked++
    if (-not $ok) { throw "FAIL: $name" }
}

# Load the production functions without evaluating files that initialize WPF
# or discover the CLI at file scope.
function Read-Function([string]$file, [string]$name) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $Repo $file), [ref]$null, [ref]$errors)
    if ($errors) { throw "$file has parse errors: $errors" }
    $fn = $ast.Find({ param($a)
        $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name
    }, $true)
    if (-not $fn) { throw "Function $name is missing from $file" }
    return [scriptblock]::Create($fn.Extent.Text)
}

. (Join-Path $Repo 'lib\i18n.ps1')
. (Read-Function 'lib\usage.ps1' 'Get-Limits')
. (Read-Function 'lib\usage.ps1' 'Parse-Period')
. (Read-Function 'lib\usage.ps1' 'Parse-ResetStamp')
. (Read-Function 'lib\usage.ps1' 'Collect-UsageProbe')
. (Read-Function 'lib\format.ps1' 'Get-Level')
. (Read-Function 'lib\mascot.ps1' 'Set-MascotMood')

$cultures = @{ en = 'en-US'; ru = 'ru-RU'; fr = 'fr-FR'; 'pt-BR' = 'pt-BR'; es = 'es-ES' }
foreach ($lang in $cultures.Keys) {
    Check "$lang is registered" $Languages.Contains($lang)
    Check "$lang has a translation table" $Strings.ContainsKey($lang)
    $script:Cfg.language = $lang
    Check "$lang culture" ((Get-LangCulture).Name -eq $cultures[$lang])
    foreach ($key in $Strings.en.Keys) {
        Check "$lang has $key" $Strings[$lang].ContainsKey($key)
        $english = @($Strings.en[$key])
        $local = @($Strings[$lang][$key])
        # Russian plural forms intentionally use three entries, while the
        # other languages use two. The new tables must match English arrays.
        if ($lang -in @('pt-BR', 'es')) {
            Check "$lang array length for $key" ($local.Count -eq $english.Count)
        }
        $a = @([regex]::Matches(($english -join ' '), '\{\d+(?:[^}]*)\}') |
            ForEach-Object { $_.Value } | Sort-Object -Unique) -join '|'
        $b = @([regex]::Matches(($local -join ' '), '\{\d+(?:[^}]*)\}') |
            ForEach-Object { $_.Value } | Sort-Object -Unique) -join '|'
        Check "$lang placeholders for $key" ($a -eq $b)
    }
}
'PASS  five language tables, placeholders and cultures'

# The same response as mock-claude.cs, passed through the real asynchronous
# collector after a fake completed process. Freeze only the parser's clock.
$script:FixedNow = [datetime]'2026-10-27T12:00:00'
function Get-Date { return $script:FixedNow }
$script:Samples = New-Object System.Collections.ArrayList
function Add-UsageSample($u) { [void]$script:Samples.Add($u) }
$script:UsageFile = [System.IO.Path]::GetTempFileName()
try {
    $fixture = @'
Current session: 37% resets Oct 28, 7:30am
Current week (all models): 68% resets Oct 31, 6am
Current week (Fable): 12% resets Oct 31, 6am
Last 24h: 24 requests, 3 sessions
  12% of your usage came from subagent-heavy sessions
'@
    [System.IO.File]::WriteAllText($script:UsageFile, $fixture,
        (New-Object System.Text.UTF8Encoding $false))
    $script:Usage = $null
    $script:UsageProc = [pscustomobject]@{ HasExited = $true }
    Collect-UsageProbe
    Check 'completed usage probe is consumed' ($null -eq $script:UsageProc)
    Check 'fixture session percentage' ($script:Usage.session -eq 37)
    Check 'fixture weekly percentage' ($script:Usage.week -eq 68)
    Check 'fixture Fable percentage' ($script:Usage.fable -eq 12)
    Check 'fixture session reset' ($script:Usage.sessionReset -eq [datetime]'2026-10-28T07:30:00')
    Check 'fixture weekly reset' ($script:Usage.weekReset -eq [datetime]'2026-10-31T06:00:00')
    Check 'fixture Fable reset' ($script:Usage.fableReset -eq [datetime]'2026-10-31T06:00:00')
    Check 'fixture daily request/session counts' ($script:Usage.day.requests -eq 24 -and $script:Usage.day.sessions -eq 3)
    Check 'fixture daily stat line' ($script:Usage.day.lines.Count -eq 1 -and
        $script:Usage.day.lines[0] -eq '12% of your usage came from subagent-heavy sessions')
    Check 'absent seven-day stats stay absent' ($null -eq $script:Usage.week7)
    Check 'usage sample is saved once' ($script:Samples.Count -eq 1 -and $script:Samples[0] -eq $script:Usage)
    Check 'usage timestamp records completion' ($script:UsageAt -eq $script:FixedNow)
    Collect-UsageProbe
    Check 'completed response is not processed twice' ($script:Samples.Count -eq 1)
    $singular = Parse-Period "Last 7d: 1 request, 1 session`r`n  one detail`r`n" 'Last 7d'
    Check 'singular seven-day counts parse' ($singular.requests -eq 1 -and $singular.sessions -eq 1 -and
        $singular.lines[0] -eq 'one detail')
    Check 'reset stamp with at and pm' ((Parse-ResetStamp 'Oct 28 at 2:29pm') -eq [datetime]'2026-10-28T14:29:00')
    Check 'invalid reset stamp stays absent' ($null -eq (Parse-ResetStamp 'unknown'))
} finally {
    Remove-Item -LiteralPath $script:UsageFile -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-Date
}
'PASS  mock CLI response, reset stamps and daily/seven-day stats'

$script:Cfg.language = 'unknown'
Check 'unknown language falls back to English' ((Get-Lang) -eq 'en')
$usage = @{ session = 37; week = 82; sessionReset = [datetime]'2026-10-27T18:00:00'
            weekReset = [datetime]'2026-11-01T10:00:00' }
foreach ($mode in @('session', 'week')) {
    $script:Cfg.mainLimit = $mode
    $limits = Get-Limits $usage
    $side = $(if ($mode -eq 'session') { 'week' } else { 'session' })
    Check "$mode main mapping" ($limits.main.key -eq $mode -and $limits.main.pct -eq $usage[$mode])
    Check "$mode main reset" ($limits.main.reset -eq $usage["${mode}Reset"])
    Check "$mode side mapping" ($limits.side.key -eq $side -and $limits.side.pct -eq $usage[$side])
    $empty = Get-Limits $null
    Check "$mode empty data" ($null -eq $empty.main.pct -and $null -eq $empty.side.pct)
    $partial = Get-Limits @{ session = 0 }
    Check "$mode preserves zero session and missing week" (
        $(if ($mode -eq 'session') { $partial.main.pct -eq 0 -and $null -eq $partial.side.pct }
          else { $partial.side.pct -eq 0 -and $null -eq $partial.main.pct }))
}
'PASS  both main-limit modes, resets and missing data'

$script:Acts = @()
function Start-MascotAct([string]$name) { $script:Acts += $name }
$script:Mz = @{ busy = 0; waiting = 0; limit = $null; lastReset = $null
                lastPct = $null; halves = 5; mood = 'sleep'; act = $null }
$script:Cfg.mainLimit = 'session'
Set-MascotMood @() $usage
Check 'initial state does not celebrate' ($script:Acts.Count -eq 0)
$script:Mz.halves = 5
$script:Cfg.mainLimit = 'week'
Set-MascotMood @() $usage
Check 'switching does not celebrate' ($script:Acts.Count -eq 0)
Check 'switching resets heart baseline' ($null -eq $script:Mz.halves)
Check 'weekly state uses weekly percentage' ($script:Mz.pct -eq 82 -and $script:Mz.limit -eq 'week')
$usage.week = 100
Set-MascotMood @() $usage
Check 'exhausted weekly limit makes mascot dead' ($script:Mz.mood -eq 'dead')
$usage.week = 0
$usage.weekReset = $usage.weekReset.AddDays(7)
Set-MascotMood @() $usage
Check 'real weekly reset celebrates once' ($script:Acts.Count -eq 1 -and $script:Acts[0] -eq 'celebrate')
Set-MascotMood @() $usage
Check 'unchanged data does not celebrate again' ($script:Acts.Count -eq 1)
Set-MascotMood @() $null
Check 'missing usage clears percentage' ($null -eq $script:Mz.pct -and -not $script:Mz.crit)
'PASS  switching, heart baseline, exhausted limit and weekly reset'

. (Read-Function 'lib\sessions.ps1' 'Get-SessionState')
. (Read-Function 'lib\sessions.ps1' 'Format-Elapsed')
. (Read-Function 'lib\sessions.ps1' 'Get-SessionRowModels')
$script:Cfg.language = 'en'
$script:SessSince = @{}
$t0 = [datetime]'2026-11-15 12:00'
$ss = @(
    @{ name = 'api'; cwd = 'C:\src\api'; busy = $false; waiting = $false; sessionId = 'a' }
    @{ name = 'web'; cwd = 'C:\src\web'; busy = $true;  waiting = $false; sessionId = 'b' }
    @{ name = 'ops'; cwd = 'C:\src\ops'; busy = $false; waiting = $true; waitingFor = 'permission'; sessionId = 'c' }
    @{ name = 'nas'; cwd = '/srv'; busy = $true; waiting = $false; sessionId = 'd'; host = 'unraid' }
)
$rows = Get-SessionRowModels $ss $t0
Check 'one row per session' ($rows.Count -eq 4)
Check 'waiting first, idle last' ($rows[0].name -eq 'ops' -and $rows[3].name -eq 'api')
Check 'waiting shows what for' ($rows[0].text -eq 'permission')
Check 'fresh state has no duration' ($rows[1].text -eq 'working')
Check 'remote row names its host' (@($rows | Where-Object { $_.name -eq 'nas @unraid' }).Count -eq 1)
Check 'remote tooltip has host and folder' (@($rows | Where-Object { $_.tip -eq 'unraid: /srv' }).Count -eq 1)
$rows = Get-SessionRowModels $ss $t0.AddMinutes(75)
Check 'duration in the same state' ((@($rows | Where-Object { $_.name -eq 'web' })[0].text) -eq 'working · 1h 15m')
$ss[1].busy = $false
$rows = Get-SessionRowModels $ss $t0.AddMinutes(80)
Check 'state change restarts the clock' ((@($rows | Where-Object { $_.name -eq 'web' })[0].text) -eq 'idle')
$rows = Get-SessionRowModels @($ss[0]) $t0.AddMinutes(81)
Check 'ended sessions are forgotten' ($script:SessSince.Count -eq 1 -and $rows.Count -eq 1)
$script:SessSince = @{}
# What the readers make of "shell" (a background task): busy, like the converters do.
$odd = @(
    @{ name = 'demos'; busy = $true;  waiting = $false; status = 'shell';  sessionId = 's1' }
    @{ name = 'core';  busy = $true;  waiting = $false; status = 'busy';   sessionId = 's2' }
    @{ name = 'web';   busy = $false; waiting = $false; status = 'idle';   sessionId = 's3' }
    @{ name = 'odd';   busy = $false; waiting = $false; status = 'paused'; sessionId = 's4' }
)
$rows = Get-SessionRowModels $odd $t0
$sh = @($rows | Where-Object { $_.name -eq 'demos' })[0]
Check 'shell reads as a background task' ($sh.text -eq 'background task')
Check 'shell has the working dot' ($sh.state -eq 'busy')
Check 'shell sorts with working, before idle' (@($rows[0].name, $rows[1].name) -contains 'demos')
$un = @($rows | Where-Object { $_.name -eq 'odd' })[0]
Check 'unknown status is shown as it is' ($un.text -eq 'paused')
Check 'unknown status has the idle dot' ($un.state -eq 'idle')
$tones = @{}; foreach ($x in $rows) { $tones[$x.name] = $x.tone }
Check 'tones: shell, busy, idle, other' ($tones.demos -eq 'shell' -and $tones.core -eq 'busy' -and $tones.web -eq 'idle' -and $tones.odd -eq 'other')
$w = Get-SessionRowModels @(@{ name = 'ask'; busy = $false; waiting = $true; status = 'waiting'; waitingFor = 'input needed'; sessionId = 's9' }) $t0
Check 'tone: waiting' ($w[0].tone -eq 'waiting')
$script:SessSince = @{}
$rows = Get-SessionRowModels $odd $t0
$rows = Get-SessionRowModels $odd $t0.AddMinutes(3)
Check 'shell keeps its own clock' ((@($rows | Where-Object { $_.name -eq 'demos' })[0].text) -eq 'background task · 3m')
$odd[0].status = 'busy'
$rows = Get-SessionRowModels $odd $t0.AddMinutes(4)
Check 'shell -> busy restarts the clock' ((@($rows | Where-Object { $_.name -eq 'demos' })[0].text) -eq 'working')
'PASS  session rows: order, states, durations and remote hosts'

. (Read-Function 'lib\sessions.ps1' 'Get-GistId')
. (Read-Function 'lib\sessions.ps1' 'Get-GistFeedText')
. (Read-Function 'lib\sessions.ps1' 'ConvertTo-RemoteSessions')
$RemoteStaleSeconds = 120
$WorkingStatuses = @('busy', 'shell')
$shellFeed = "{""generatedAt"":""$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"",""sessions"":[{""name"":""vako"",""status"":""shell""}]}"
$shellList = ConvertTo-RemoteSessions $shellFeed
Check 'remote shell counts as working' ($shellList[0].busy -and $shellList[0].status -eq 'shell')
$id = 'b9535c61f6f97a4f95e5423cd9de0063'
Check 'gist: form' ((Get-GistId "gist:$id") -eq $id)
Check 'gist page with user' ((Get-GistId "https://gist.github.com/someone/$id") -eq $id)
Check 'gist page without user' ((Get-GistId "https://gist.github.com/$id/") -eq $id)
Check 'plain URL is not a gist' ($null -eq (Get-GistId 'http://nas:8787/sessions.json'))
Check 'file path is not a gist' ($null -eq (Get-GistId 'C:\feeds\sessions.json'))
$fresh = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$feed = "{""generatedAt"":""$fresh"",""host"":""hq2"",""sessions"":[{""name"":""lima"",""status"":""waiting"",""waitingFor"":""permission"",""sessionId"":""x""}]}"
$api = @{ id = $id; files = [ordered]@{ 'notes.md' = @{ filename = 'notes.md'; content = 'hi'; truncated = $false }
                                        'sessions.json' = @{ filename = 'sessions.json'; content = $feed; truncated = $false } } } |
       ConvertTo-Json -Depth 5
Check 'gist picks sessions.json among files' ((Get-GistFeedText $api) -eq $feed)
$list = ConvertTo-RemoteSessions (Get-GistFeedText $api)
Check 'gist feed becomes a remote session' ($list.Count -eq 1 -and $list[0].host -eq 'hq2' -and $list[0].waiting -and $list[0].waitingFor -eq 'permission')
$cut = @{ files = @{ 'sessions.json' = @{ filename = 'sessions.json'; content = '{'; truncated = $true } } } | ConvertTo-Json -Depth 5
$threw = $false; try { Get-GistFeedText $cut | Out-Null } catch { $threw = $true }
Check 'truncated gist file is refused' $threw
$old = $feed -replace [regex]::Escape($fresh), [DateTime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
Check 'stale feed adds nothing' ((ConvertTo-RemoteSessions $old).Count -eq 0)
$five = [DateTime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
$twelve = [DateTime]::UtcNow.AddMinutes(-12).ToString('yyyy-MM-ddTHH:mm:ssZ')
Check 'a 5-minute heartbeat keeps a 5-minute-old feed' ((ConvertTo-RemoteSessions "{""generatedAt"":""$five"",""heartbeat"":300,""sessions"":[{""name"":""a""}]}").Count -eq 1)
Check 'two missed heartbeats make it stale' ((ConvertTo-RemoteSessions "{""generatedAt"":""$twelve"",""heartbeat"":300,""sessions"":[{""name"":""a""}]}").Count -eq 0)
Check 'a short heartbeat never shortens the 2 minutes' ((ConvertTo-RemoteSessions "{""generatedAt"":""$([DateTime]::UtcNow.AddSeconds(-100).ToString('yyyy-MM-ddTHH:mm:ssZ'))"",""heartbeat"":5,""sessions"":[{""name"":""a""}]}").Count -eq 1)
'PASS  remote sessions from a gist: addresses, file pick, staleness'

. (Read-Function 'lib\sysload.ps1' 'Select-SysGpu')
$nv  = @{ name = 'NVIDIA GeForce RTX 5070'; total = 12GB; used = 1GB }
$amd = @{ name = 'AMD Radeon(TM) Graphics'; total = 512MB; used = 0 }
Check 'the card with the most memory of its own' ((Select-SysGpu @($amd, $nv) '').name -eq $nv.name)
Check 'sysGpu picks by part of the name' ((Select-SysGpu @($nv, $amd) 'radeon').name -eq $amd.name)
Check 'an unknown sysGpu falls back to the biggest' ((Select-SysGpu @($amd, $nv) 'intel').name -eq $nv.name)
Check 'a card without memory of its own is skipped' ((Select-SysGpu @(@{ name = 'Basic'; total = 0; used = 0 }, $amd) '').name -eq $amd.name)
Check 'no cards - nothing' ($null -eq (Select-SysGpu @() ''))
'PASS  system load: which graphics card is shown'
"all passed ($script:Checked checks)"
