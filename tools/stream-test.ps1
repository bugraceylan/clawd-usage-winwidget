#requires -version 5
<#
  Checks the live feed reader (lib\sessions.ps1: Get-StreamUrl, Start-FeedStream) against
  a stand-in for Firebase's REST streaming on localhost: a full put, a second put, a
  patch (which makes the reader fetch the whole feed), keep-alives, a dropped
  connection (it must reconnect) and stopping. No network beyond localhost, no Firebase.

    powershell -ExecutionPolicy Bypass -File tools\stream-test.ps1     exit code 0 - all passed
#>
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$script:Checked = 0
function Check([string]$name, [bool]$ok) {
    $script:Checked++
    if (-not $ok) { throw "FAIL: $name" }
}
function Wait-Until([scriptblock]$cond, [int]$seconds = 10) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 100 }
    return $false
}

# The reader redraws the window through a WPF timer, as in the widget.
Add-Type -AssemblyName WindowsBase
# sessions.ps1 asks for Claude Code's folder when it loads; the rest is used as is.
function Get-ClaudeConfigDir { return $env:TEMP }
. (Join-Path $Repo 'lib\sessions.ps1')

# --- addresses ---------------------------------------------------------------
Check 'firebaseio.com address' ((Get-StreamUrl 'https://x-default-rtdb.firebaseio.com/feeds/abc') -eq 'https://x-default-rtdb.firebaseio.com/feeds/abc.json')
Check 'regional address' ((Get-StreamUrl 'https://x-default-rtdb.europe-west1.firebasedatabase.app/feeds/abc/') -eq 'https://x-default-rtdb.europe-west1.firebasedatabase.app/feeds/abc.json')
Check '.json kept once' ((Get-StreamUrl 'https://x.firebaseio.com/feeds/abc.json') -eq 'https://x.firebaseio.com/feeds/abc.json')
Check 'query after .json' ((Get-StreamUrl 'https://x.firebaseio.com/feeds/abc?auth=s') -eq 'https://x.firebaseio.com/feeds/abc.json?auth=s')
Check 'firebase: prefix' ((Get-StreamUrl 'firebase:http://localhost:1/feeds/k') -eq 'http://localhost:1/feeds/k.json')
Check 'gist is not a stream' ($null -eq (Get-StreamUrl 'gist:b9535c61f6f97a4f95e5423cd9de0063'))
Check 'plain URL is not a stream' ($null -eq (Get-StreamUrl 'https://example.com/sessions.json'))
Check 'file path is not a stream' ($null -eq (Get-StreamUrl 'C:\feeds\sessions.json'))
'PASS  stream addresses'

# --- a stand-in Firebase ---------------------------------------------------------
$port = Get-Random -Minimum 20000 -Maximum 40000
$srv = [hashtable]::Synchronized(@{ feed = $null; queue = New-Object System.Collections.Queue; streams = 0
                                    gets = 0; drop = $false; stop = $false })
# Two workers on one listener, like a real server: one can hold a stream open while the
# other answers the reader's plain GET after a patch.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
$serverScript = {
    param($l, $srv)
    while (-not $srv.stop) {
        $t = $l.GetContextAsync()
        while (-not $t.Wait(100)) { if ($srv.stop) { break } }
        if ($srv.stop) { break }
        $c = $t.Result
        if ($c.Request.Headers['Accept'] -eq 'text/event-stream') {
            $srv.streams++
            $c.Response.ContentType = 'text/event-stream'
            $c.Response.SendChunked = $true
            $w = New-Object System.IO.StreamWriter($c.Response.OutputStream, (New-Object System.Text.UTF8Encoding $false))
            $w.NewLine = "`n"
            try {
                $w.WriteLine('event: keep-alive'); $w.WriteLine('data: null'); $w.WriteLine(''); $w.Flush()
                while (-not $srv.stop -and -not $srv.drop) {
                    $e = $null
                    [System.Threading.Monitor]::Enter($srv.queue.SyncRoot)
                    try { if ($srv.queue.Count) { $e = $srv.queue.Dequeue() } } finally { [System.Threading.Monitor]::Exit($srv.queue.SyncRoot) }
                    if ($e) { $w.WriteLine("event: $($e.event)"); $w.WriteLine("data: $($e.data)"); $w.WriteLine(''); $w.Flush() }
                    else { Start-Sleep -Milliseconds 50 }
                }
            } catch {}
            $srv.drop = $false
            try { $c.Response.Abort() } catch {}
        } else {
            $srv.gets++
            $b = [System.Text.Encoding]::UTF8.GetBytes([string]$srv.feed)
            $c.Response.ContentType = 'application/json'
            $c.Response.OutputStream.Write($b, 0, $b.Length)
            $c.Response.Close()
        }
    }
}
$servers = @(1, 2) | ForEach-Object {
    $p = [powershell]::Create()
    [void]$p.AddScript($serverScript).AddArgument($listener).AddArgument($srv)
    @{ ps = $p; handle = $p.BeginInvoke() }
}

function Send([string]$event, [string]$data) {
    [System.Threading.Monitor]::Enter($srv.queue.SyncRoot)
    try { $srv.queue.Enqueue(@{ event = $event; data = $data }) } finally { [System.Threading.Monitor]::Exit($srv.queue.SyncRoot) }
}
function Feed([string[]]$names, [string]$status = 'busy') {
    $at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $ss = @($names | ForEach-Object { "{""name"":""$_"",""status"":""$status"",""sessionId"":""$_""}" }) -join ','
    return "{""generatedAt"":""$at"",""host"":""hq2"",""heartbeat"":60,""sessions"":[$ss]}"
}
$WorkingStatuses = @('busy', 'shell')

try {
    $st = Start-FeedStream "http://localhost:$port/feeds/k.json"
    Check 'connects' (Wait-Until { $st.connected -and $srv.streams -eq 1 })
    Check 'a keep-alive is not a feed' ($null -eq $st.text -and $st.at -gt [datetime]::MinValue)

    Send 'put' "{""path"":""/"",""data"":$(Feed @('lima'))}"
    Check 'a put arrives' (Wait-Until { $st.version -ge 1 })
    $list = ConvertTo-RemoteSessions $st.text
    Check 'put: one session from hq2' ($list.Count -eq 1 -and $list[0].name -eq 'lima' -and $list[0].host -eq 'hq2' -and $list[0].busy)

    Send 'put' "{""path"":""/"",""data"":$(Feed @('lima', 'saga') 'waiting')}"
    Check 'a second put arrives' (Wait-Until { $st.version -ge 2 })
    $list = ConvertTo-RemoteSessions $st.text
    Check 'second put replaces the first' ($list.Count -eq 2 -and $list[1].waiting)

    $srv.feed = Feed @('lima', 'saga', 'vako') 'shell'
    Send 'patch' '{"path":"/sessions/2","data":{"name":"vako","status":"shell"}}'
    Check 'a patch reads the whole feed' (Wait-Until { $st.version -ge 3 -and $srv.gets -ge 1 })
    $list = ConvertTo-RemoteSessions $st.text
    Check 'patch: three sessions, shell is working' ($list.Count -eq 3 -and $list[2].busy)

    $empty = "{""generatedAt"":""$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"",""host"":""hq2"",""heartbeat"":60}"
    Send 'put' "{""path"":""/"",""data"":$empty}"
    Check 'feed without sessions key arrives' (Wait-Until { $st.version -ge 4 })
    Check 'no sessions key means none (Firebase drops empty arrays)' ((ConvertTo-RemoteSessions $st.text).Count -eq 0)

    Send 'put' '{"path":"/","data":null}'
    Check 'a deleted feed arrives' (Wait-Until { $st.version -ge 5 })
    Check 'deleted feed reads as empty' ($st.text -eq '')
    'PASS  live feed: put, patch, empty and deleted feeds'

    $srv.drop = $true
    Check 'notices the drop' (Wait-Until { -not $st.connected } 5)
    Check 'reconnects by itself' (Wait-Until { $st.connected -and $srv.streams -eq 2 } 10)
    Send 'put' "{""path"":""/"",""data"":$(Feed @('core'))}"
    Check 'feed flows again after reconnecting' (Wait-Until { $st.version -ge 6 })
    Check 'the new feed' ((ConvertTo-RemoteSessions $st.text)[0].name -eq 'core')
    'PASS  live feed: drop and reconnect'

    Stop-FeedStream $st
    Check 'stops' (Wait-Until { $st.handle.IsCompleted } 5)
    'PASS  live feed: stop'
} finally {
    if ($st) { Stop-FeedStream $st }
    $srv.stop = $true
    foreach ($s in $servers) { [void]$s.handle.AsyncWaitHandle.WaitOne(3000); $s.ps.Dispose() }
    $listener.Stop()
}
"all passed ($script:Checked checks)"
