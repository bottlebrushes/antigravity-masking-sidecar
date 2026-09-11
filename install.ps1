#Requires -Version 5.1
<#
.SYNOPSIS
    Windows installer for the Antigravity Masking Sidecar (Oh My Pi / omp).

.DESCRIPTION
    Windows counterpart to install.sh:
      1. Ensures Bun is installed (installs via the official script if missing).
      2. Copies the proxy script to %USERPROFILE%\.omp\sidecar\.
      3. Writes a windowless supervising launcher (sidecar.vbs) that restarts the
         proxy 3s after any exit and logs its output, mirroring the systemd unit's
         Restart=always / RestartSec=3 and launchd's log files.
      4. Registers a hidden at-logon Scheduled Task running that launcher.
      5. Points the google-antigravity provider at the sidecar in
         %USERPROFILE%\.omp\agent\models.yml, adopting the file's existing
         indentation, encoding, line endings and trailing-newline style.
      6. Starts the task and verifies the sidecar's own /health identity.

    Idempotent: safe to re-run. Run from a full clone of the repository:
      powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

$ErrorActionPreference = 'Stop'

$SidecarDir  = Join-Path $env:USERPROFILE '.omp\sidecar'
$AgentDir    = Join-Path $env:USERPROFILE '.omp\agent'
$ProxySrc    = Join-Path $PSScriptRoot 'src\antigravity-masking-proxy.ts'
$ProxyDst    = Join-Path $SidecarDir 'antigravity-masking-proxy.ts'
$VbsPath     = Join-Path $SidecarDir 'sidecar.vbs'
$LogPath     = Join-Path $SidecarDir 'sidecar.log'
$ModelsYml   = Join-Path $AgentDir 'models.yml'
$BackupYml   = "$ModelsYml.pre-sidecar.bak"
$SidecarUrl  = 'http://127.0.0.1:45123'
$HealthUrl   = "$SidecarUrl/health"
$ServiceName = 'omp-antigravity-sidecar'   # identity emitted by the proxy's /health
$TaskName    = 'AntigravitySidecar'

Write-Host "=========================================================="
Write-Host "  Antigravity Masking Sidecar Installer for Oh My Pi (Windows)"
Write-Host "=========================================================="

# --- helpers ----------------------------------------------------------------

# 'ours' | 'foreign' | 'none'. A bare status=ok from port 45123 is not enough:
# only the proxy's own service identity proves the port is ours. Any transport
# error (refused, timeout, non-JSON) is treated as 'none'.
function Get-SidecarHealth {
    try {
        $h = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 2
    } catch {
        return 'none'
    }
    if ($h.status -eq 'ok' -and $h.service -eq $ServiceName) { return 'ours' }
    return 'foreign'
}

function Get-Indent([string]$Line) {
    if ($Line -match '^([ \t]*)') { return $Matches[1] }
    return ''
}

function Test-SkippableLine([string]$Line) {
    return ($Line -match '^[ \t]*$' -or $Line -match '^[ \t]*#')
}

# Escapes a value for embedding in a printed single-quoted PowerShell literal,
# so emitted commands stay pasteable for paths like C:\Users\O'Brien.
function Format-PsLiteral([string]$Value) {
    return $Value.Replace("'", "''")
}

# Splits "  key: rest" into indent/key/rest, decoding quoted key spellings so
# providers:, "providers": and 'providers': are all recognised as one key.
# Returns $null when the line is not a mapping key.
function Get-KeyLine([string]$Line) {
    if ($Line -notmatch '^([ \t]*)(?:"([^"]*)"|''([^'']*)''|([^\s"''#][^:]*?))[ \t]*:(.*)$') { return $null }
    $indent = $Matches[1]
    $rest   = $Matches[5]
    $key = $null
    if ($Matches[2]) { $key = $Matches[2] }
    elseif ($Matches[3]) { $key = $Matches[3] }
    elseif ($Matches[4]) { $key = $Matches[4].Trim() }
    if (-not $key) { return $null }
    [PSCustomObject]@{ Indent = $indent; Key = $key; Rest = $rest }
}

# Extracts a YAML scalar, dropping surrounding quotes and any trailing comment.
function Get-ScalarValue([string]$Text) {
    $v = $Text.Trim()
    if ($v -match "^'([^']*)'") { return $Matches[1] }
    if ($v -match '^"([^"]*)"')  { return $Matches[1] }
    $v = ($v -split '\s+#', 2)[0]
    return $v.Trim()
}

function Test-IsSidecarUrl([string]$Value) {
    if (-not $Value) { return $false }
    return ($Value.TrimEnd('/') -eq $SidecarUrl.TrimEnd('/'))
}

# True only when a line is unambiguously a plain top-level block mapping key,
# i.e. safe to append a sibling `providers:` key after, and safe to treat as a
# top-level key rather than something else. Rejects flow roots ("{...}",
# "[...]"), sequence entries, node properties (!!tag, &anchor, *alias,
# %directive, "? complex"), and plain scalars whose colon has no following
# space ("https://example.com" lexes a key of "https" but is not a mapping).
# Unusual but legitimate key spellings (a!b, 'a,b') are accepted: the leading
# character check already excludes the node-property forms that matter.
function Test-RootBlockKey([string]$Line) {
    $kl = Get-KeyLine $Line
    if (-not $kl -or $kl.Indent.Length -ne 0) { return $false }
    if ($Line.Trim() -match '^[\{\[\-!&\*%\?>\|]') { return $false }
    # A block mapping needs a space after the colon. YAML forbids a tab there
    # ("key:<tab>value" is rejected by parsers), so do not accept one.
    if (-not (Test-EmptyRest $kl.Rest) -and $kl.Rest -notmatch '^ ') { return $false }
    return $true
}

# True when the remainder after "key:" carries no value. A comment only counts
# when a space separates it from the colon: "key:#c" is the plain scalar
# "key:#c", not a mapping key with a comment, so it must NOT look empty.
function Test-EmptyRest([string]$Rest) {
    if ($Rest -match '^[ \t]*$') { return $true }
    return ($Rest -match '^ +#')
}

# Scan state carried across lines: open flow-collection depth, the quote
# character of a quoted scalar left open at end of line, whether the next line
# may begin a value (bare "key:", or a dangling anchor/tag awaiting its node),
# and the indent of a block scalar whose body is still open (BlockIndent, -1
# when none). YAML lets a quoted scalar span lines, and its continuation lines
# may sit at column 0 ("note: `"hello" / "providers:" / "end: x`""), where they
# would otherwise look like top-level keys. Deliberately conservative rather
# than a YAML lexer:
#  - depth never goes below zero, so an unmatched "}" in a plain scalar
#    ("note: x}") cannot offset a later genuine "{";
#  - a quote opens a scalar ONLY where a value or flow item can begin: right
#    after "key:", "{", "[", a flow comma, "- ", or an anchor/tag token
#    ("key: &a `"..."", "key: !!str `"...""). Anywhere else it is literal
#    text, so plain scalars ("note: say `"hello", "note: user's text") do not
#    desync quote tracking. A BLOCK-context comma is plain text too.
#  - a block scalar header (|" >" with chomping/indent indicators) starts a
#    literal body whose lines are pure text: the CLASSIFIER loop skips them
#    entirely, so a quote or "key:" inside a body can never poison the scan.
function Get-ScanStateAfter([string]$Line, $State) {
    $depth   = $State.Depth
    $quote   = $State.Quote
    $block   = $State.BlockIndent
    $canOpen = ($depth -gt 0) -or $State.CanOpenNext
    $seen    = $false
    $token   = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote) {
            if ($quote -eq '"' -and $c -eq '\') { $i++; continue }
            if ($quote -eq "'" -and $c -eq "'" -and ($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq "'") { $i++; continue }
            if ($c -eq $quote) { $quote = $null; $canOpen = $false }
            continue
        }
        if ($token) {
            # Absorb an anchor/tag name; the node it labels may still follow.
            if ($c -eq ' ' -or $c -eq "`t") { $token = $false }
            continue
        }
        if ($c -eq ' ' -or $c -eq "`t") { continue }                  # keeps $canOpen
        if ($c -eq '#' -and ($i -eq 0 -or $Line[$i - 1] -eq ' ' -or $Line[$i - 1] -eq "`t")) { break }
        $next = if (($i + 1) -lt $Line.Length) { $Line[$i + 1] } else { ' ' }
        if (($c -eq '"' -or $c -eq "'") -and $canOpen) { $quote = $c; $seen = $true; continue }
        if (($c -eq '&' -or $c -eq '!') -and $canOpen) { $token = $true; $seen = $true; continue }
        if ($depth -eq 0 -and $canOpen -and ($c -eq '|' -or $c -eq '>') -and
            ($Line.Substring($i) -match '^[|>][-+0-9]*([ \t]+#.*)?[ \t]*$')) {
            # Block scalar header (a separated trailing comment is legal).
            # Body lines (indent > this line's indent) are pure text; the
            # classifier loop skips them.
            $block = (Get-Indent $Line).Length
            break
        }
        if ($c -eq '{' -or $c -eq '[') { $depth++; $canOpen = $true; $seen = $true; continue }
        if ($c -eq '}' -or $c -eq ']') { if ($depth -gt 0) { $depth-- }; $canOpen = $false; $seen = $true; continue }
        if ($c -eq ',' -and $depth -gt 0) { $canOpen = $true; $seen = $true; continue }
        if ($c -eq ':' -and ($next -eq ' ' -or $next -eq "`t")) { $canOpen = $true; $seen = $true; continue }
        if ($c -eq '-' -and -not $seen -and ($next -eq ' ' -or $next -eq "`t")) { $canOpen = $true; $seen = $true; continue }
        $canOpen = $false
        $seen = $true
    }
    [PSCustomObject]@{ Depth = $depth; Quote = $quote; BlockIndent = $block
                       CanOpenNext = ($canOpen -and -not $quote) }
}

# Scans flow text, tracking quote state with YAML escaping: a backslash escapes
# the next character inside double quotes, and '' is a literal quote inside
# single quotes. Returns the index of the first unquoted char satisfying
# $StopOn at depth 0, or the index of the closing brace when $StopOn is $null.
function Find-FlowIndex([string]$Text, [int]$Start, [char[]]$StopOn, [bool]$StopAtClose) {
    $depth = 0; $quote = $null
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($quote) {
            if ($quote -eq '"' -and $c -eq '\') { $i++; continue }              # \" escape
            if ($quote -eq "'" -and $c -eq "'" -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
            if ($c -eq $quote) { $quote = $null }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c; continue }
        if ($c -eq '{' -or $c -eq '[') { $depth++; continue }
        if ($c -eq '}' -or $c -eq ']') {
            $depth--
            if ($StopAtClose -and $depth -eq 0) { return $i }
            continue
        }
        if ($depth -eq 0 -and $StopOn -and $StopOn -contains $c) { return $i }
    }
    return -1
}

# Reads a DIRECT member out of a YAML flow mapping, e.g. "{ baseUrl: 'x' }".
# Nesting- and quote-aware, so a baseUrl buried in a nested mapping does not
# count as the provider's own route. Parsable=$false for anything else.
function Get-FlowMappingMember([string]$Text, [string]$WantKey) {
    $t = $Text.Trim()
    $miss = [PSCustomObject]@{ Parsable = $false; Found = $false; Value = $null }
    if (-not $t.StartsWith('{')) { return $miss }

    $end = Find-FlowIndex $t 0 $null $true
    if ($end -lt 0) { return $miss }
    $trailing = $t.Substring($end + 1).Trim()
    if ($trailing -ne '' -and -not $trailing.StartsWith('#')) { return $miss }

    $inner = $t.Substring(1, $end - 1)
    # split on depth-0 commas
    $parts = @(); $from = 0
    while ($true) {
        $ci = Find-FlowIndex $inner $from ([char[]]@(',')) $false
        if ($ci -lt 0) { $parts += $inner.Substring($from); break }
        $parts += $inner.Substring($from, $ci - $from)
        $from = $ci + 1
    }

    foreach ($part in $parts) {
        if (-not $part.Trim()) { continue }
        $ci = Find-FlowIndex $part 0 ([char[]]@(':')) $false
        if ($ci -lt 0) { continue }
        $k = (Get-ScalarValue $part.Substring(0, $ci))
        if ($k -ceq $WantKey) {
            return [PSCustomObject]@{ Parsable = $true; Found = $true; Value = (Get-ScalarValue $part.Substring($ci + 1)) }
        }
    }
    return [PSCustomObject]@{ Parsable = $true; Found = $false; Value = $null }
}

# --- 1. Bun -----------------------------------------------------------------
# Resolve to a full path: the launcher runs from a logon task whose PATH may
# not contain bun, so a bare command name is not good enough.
$bunExe = (Get-Command bun.exe -ErrorAction SilentlyContinue).Source
if (-not $bunExe) {
    $bunRoot   = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $env:USERPROFILE '.bun' }
    $candidate = Join-Path $bunRoot 'bin\bun.exe'
    if (Test-Path $candidate) {
        $bunExe = $candidate
    } else {
        Write-Host "--> Bun not found. Installing Bun for Windows..."
        Invoke-RestMethod https://bun.sh/install.ps1 | Invoke-Expression
        foreach ($root in @($env:BUN_INSTALL, (Join-Path $HOME '.bun'), (Join-Path $env:USERPROFILE '.bun'))) {
            if (-not $root) { continue }
            $probe = Join-Path $root 'bin\bun.exe'
            if (Test-Path $probe) { $bunExe = $probe; break }
        }
        if (-not $bunExe) {
            throw "Bun installation failed: bun.exe not found under BUN_INSTALL, $HOME\.bun or $env:USERPROFILE\.bun. Install manually from https://bun.sh and re-run."
        }
    }
    $bunDir = Split-Path $bunExe
    if (($env:Path -split ';') -notcontains $bunDir) { $env:Path += ";$bunDir" }
}
$bunVersion = (& $bunExe --version 2>&1 | Select-Object -First 1)
Write-Host "--> Using Bun: $bunExe (v$bunVersion)"

if (-not (Test-Path $ProxySrc)) {
    throw "Proxy source not found at $ProxySrc - run install.ps1 from a full clone of the repository."
}

# --- 2. models.yml planning -------------------------------------------------

function Read-YamlDoc([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Preserve the file's original encoding rather than forcing UTF-8.
    if     ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($true) }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = New-Object System.Text.UnicodeEncoding($false, $true) }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = New-Object System.Text.UnicodeEncoding($true, $true) }
    else { $enc = New-Object System.Text.UTF8Encoding($false) }

    $raw = $enc.GetString($bytes)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }   # strip decoded BOM
    if ($raw.Length -eq 0) {
        return [PSCustomObject]@{ Lines = @(); Newline = "`r`n"; TrailingNewline = $true; Encoding = $enc; Raw = '' }
    }
    $crlf = ([regex]::Matches($raw, "`r`n")).Count
    $lf   = ([regex]::Matches($raw, "(?<!`r)`n")).Count
    $cr   = ([regex]::Matches($raw, "`r(?!`n)")).Count
    $nl   = if ($crlf -ge $lf -and $crlf -ge $cr -and $crlf -gt 0) { "`r`n" }
            elseif ($cr -gt $lf) { "`r" }
            else { "`n" }
    $endsWithNewline = $raw -match "(`r`n|`n|`r)$"
    $lines = @($raw -split "`r`n|`n|`r")
    if ($endsWithNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') {
        $lines = @($lines[0..($lines.Count - 2)])
    }
    [PSCustomObject]@{ Lines = $lines; Newline = $nl; TrailingNewline = $endsWithNewline; Encoding = $enc; Raw = $raw }
}

function Write-YamlDoc([string]$Path, $Doc, [string[]]$Lines) {
    $text = ($Lines -join $Doc.Newline)
    if ($Doc.TrailingNewline) { $text += $Doc.Newline }
    [System.IO.File]::WriteAllText($Path, $text, $Doc.Encoding)
}

# Decides what to do with models.yml without writing anything.
# Plan: Create | Insert | AlreadyRouted | Conflict. Throws on shapes this
# installer will not edit safely, so refusals can precede any teardown.
function Get-YamlPlan {
    $handEdit = "Add the override by hand:`n  providers:`n    google-antigravity:`n      baseUrl: `"$SidecarUrl`""
    if (-not (Test-Path $ModelsYml)) {
        return [PSCustomObject]@{ Plan = 'Create' }
    }
    $doc   = Read-YamlDoc $ModelsYml
    $lines = $doc.Lines

    # Classify each line before interpreting any of it: a line that begins
    # inside a multiline quoted scalar is scalar CONTENT, even at column 0
    # ("note: `"hello" / "providers:" / "end: x`""), and must never be read as
    # a key. A line that begins inside a flow collection is refused outright,
    # because its members look unindented and we cannot rewrite flow style.
    $isContent = New-Object 'bool[]' $lines.Count
    $state = [PSCustomObject]@{ Depth = 0; Quote = $null; CanOpenNext = $false; BlockIndent = -1 }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($state.Depth -gt 0) {
            throw "models.yml contains a flow collection spanning multiple lines, which this installer cannot edit safely. $handEdit"
        }
        $line = $lines[$i]
        if ($state.BlockIndent -ge 0) {
            if ($line -match '^[ \t]*$') { continue }                    # blank inside a body
            if ((Get-Indent $line).Length -gt $state.BlockIndent) {
                $isContent[$i] = $true                                  # block-scalar body: pure text
                continue
            }
            # Block ended: this line is real structure; scan it normally.
            $state = [PSCustomObject]@{ Depth = $state.Depth; Quote = $state.Quote
                                        CanOpenNext = $state.CanOpenNext; BlockIndent = -1 }
        }
        $isContent[$i] = ($null -ne $state.Quote)
        $state = Get-ScanStateAfter $line $state
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($isContent[$i]) { continue }
        if ($line -match '^(---|\.\.\.)([ \t].*)?$') {
            throw "models.yml contains a YAML document marker, which this installer cannot edit safely. $handEdit"
        }
        # Escaped key spellings ("pro\u0076iders":) denote the same YAML key but
        # are not decoded here. Refuse rather than insert a duplicate key.
        if ($line -match '^[ \t]*"[^"]*\\[^"]*"[ \t]*:') {
            throw "models.yml uses an escaped quoted key this installer cannot compare safely. $handEdit"
        }
        # Every column-0 line must be a block mapping key. A stray closer ("}")
        # or other top-level content means this is not a shape we can edit.
        if (-not (Test-SkippableLine $line) -and (Get-Indent $line).Length -eq 0 -and -not (Test-RootBlockKey $line)) {
            throw "models.yml has a top-level line this installer cannot classify safely. $handEdit"
        }
    }

    # Validate the root before looking for providers, so an apparently
    # unindented providers line can never be trusted on its own.
    $firstSignificant = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($isContent[$i] -or (Test-SkippableLine $lines[$i])) { continue }
        $firstSignificant = $lines[$i]; break
    }
    if ($null -ne $firstSignificant -and -not (Test-RootBlockKey $firstSignificant)) {
        throw "models.yml does not start with a plain top-level block mapping, so this installer cannot edit it safely. $handEdit"
    }

    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($isContent[$i]) { continue }
        $kl = Get-KeyLine $lines[$i]
        if (-not $kl -or $kl.Indent.Length -ne 0 -or $kl.Key -cne 'providers') { continue }
        if (-not (Test-EmptyRest $kl.Rest)) {
            throw "models.yml line $($i + 1) uses an inline 'providers:' mapping, which this installer cannot edit safely. $handEdit"
        }
        $idx = $i; break
    }
    if ($idx -lt 0) {
        # Root already validated above, so appending a providers: key is safe.
        return [PSCustomObject]@{ Plan = 'Insert'; Doc = $doc; Idx = -1; ChildIndent = '  ' }
    }

    # Direct children of providers: share the indentation of its first child.
    $childIndent = $null
    $keyIdx = -1
    $keyLine = $null
    for ($i = $idx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($isContent[$i]) { continue }               # multiline scalar content
        if (Test-SkippableLine $line) { continue }     # checked BEFORE the boundary
        if ($line -match '^\S') { break }              # left the providers block
        $indent = Get-Indent $line
        if ($null -eq $childIndent) { $childIndent = $indent }
        if ($indent.Length -ne $childIndent.Length) { continue }   # deeper descendant
        $kl = Get-KeyLine $line
        if ($kl -and $kl.Key -ceq 'google-antigravity') { $keyIdx = $i; $keyLine = $kl; break }
    }
    if ($null -eq $childIndent) { $childIndent = '  ' }

    if ($keyIdx -lt 0) {
        return [PSCustomObject]@{ Plan = 'Insert'; Doc = $doc; Idx = $idx; ChildIndent = $childIndent }
    }

    # Inline flow mapping on the key line (a comment-only remainder is block form).
    if (-not (Test-EmptyRest $keyLine.Rest)) {
        $member = Get-FlowMappingMember $keyLine.Rest 'baseUrl'
        if ($member.Parsable -and $member.Found -and (Test-IsSidecarUrl $member.Value)) {
            return [PSCustomObject]@{ Plan = 'AlreadyRouted'; KeyIdx = $keyIdx }
        }
        $why = if (-not $member.Parsable) { "an inline value this installer could not parse - its route was not verified" }
               elseif (-not $member.Found) { "an inline mapping with no baseUrl of its own" }
               else { "an inline baseUrl of $($member.Value)" }
        return [PSCustomObject]@{ Plan = 'Conflict'; KeyIdx = $keyIdx
                                  Reason = "line $($keyIdx + 1) declares google-antigravity with $why" }
    }

    # Block form: only DIRECT properties of google-antigravity count. A baseUrl
    # nested deeper (e.g. under headers:) is not the provider's own route.
    $keyIndent  = $keyLine.Indent.Length
    $propIndent = $null
    for ($i = $keyIdx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($isContent[$i]) { continue }               # multiline scalar content
        if (Test-SkippableLine $line) { continue }
        $indent = (Get-Indent $line).Length
        if ($indent -le $keyIndent) { break }          # left this provider
        if ($null -eq $propIndent) { $propIndent = $indent }
        if ($indent -ne $propIndent) { continue }      # deeper descendant
        $kl = Get-KeyLine $line
        if ($kl -and $kl.Key -ceq 'baseUrl') {
            $value = Get-ScalarValue $kl.Rest
            if (Test-IsSidecarUrl $value) {
                return [PSCustomObject]@{ Plan = 'AlreadyRouted'; KeyIdx = $keyIdx }
            }
            return [PSCustomObject]@{ Plan = 'Conflict'; KeyIdx = $keyIdx
                                      Reason = "line $($i + 1) points google-antigravity at $value" }
        }
    }
    return [PSCustomObject]@{ Plan = 'Conflict'; KeyIdx = $keyIdx
                              Reason = "line $($keyIdx + 1) declares google-antigravity with no baseUrl of its own" }
}

# Preflight: refuse unsupported shapes while the existing sidecar is still up,
# so a refusal never becomes an outage. The plan is recomputed before writing.
Get-YamlPlan | Out-Null

# --- 3. Proxy script --------------------------------------------------------
Write-Host "--> Deploying proxy script to $SidecarDir"
New-Item -ItemType Directory -Force -Path $SidecarDir | Out-Null
Copy-Item -Force $ProxySrc $ProxyDst

# --- 4. Windowless supervising launcher -------------------------------------
# Blocks on bun and restarts it after 3s, mirroring Restart=always/RestartSec=3.
# A task-level RestartCount was tried first and did not restart this action on
# this machine, so supervision is kept in one explicit place: the launcher.
# On Error keeps a failed spawn from killing the loop.
# Output is redirected to sidecar.log; the size check runs between restarts.
Write-Host "--> Writing windowless supervising launcher (sidecar.vbs)"
$vbs = @'
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
q = Chr(34)
bunExe = "__BUN__"
proxy  = "__PROXY__"
logf   = "__LOG__"
Do
  On Error Resume Next
  If fso.FileExists(logf) Then
    If fso.GetFile(logf).Size > 5242880 Then fso.DeleteFile logf, True
  End If
  sh.Run "cmd /c " & q & q & bunExe & q & " " & q & proxy & q & " >> " & q & logf & q & " 2>&1" & q, 0, True
  On Error Goto 0
  WScript.Sleep 3000
Loop
'@
$vbs = $vbs.Replace('__BUN__', $bunExe).Replace('__PROXY__', $ProxyDst).Replace('__LOG__', $LogPath)
Set-Content -Path $VbsPath -Value $vbs -Encoding Unicode

# --- 5. Scheduled task ------------------------------------------------------

# The supervisor spawns bun outside the task's job object, so stopping the task
# alone leaves the proxy holding the port. Kill the supervisor BEFORE its child,
# and match only the processes belonging to THIS installation.
function Stop-Sidecar {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    $vbsKey   = ([System.IO.Path]::GetFullPath($VbsPath)).ToLowerInvariant()
    $proxyKey = ([System.IO.Path]::GetFullPath($ProxyDst)).ToLowerInvariant()
    $ours = @(Get-CimInstance Win32_Process -Filter "Name='wscript.exe' OR Name='bun.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.CommandLine -and (
                     $_.CommandLine.ToLowerInvariant().Contains($vbsKey) -or
                     $_.CommandLine.ToLowerInvariant().Contains($proxyKey))
             } |
             Sort-Object { if ($_.Name -eq 'wscript.exe') { 0 } elseif ($_.Name -eq 'cmd.exe') { 1 } else { 2 } })
    foreach ($p in $ours) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }

    foreach ($i in 1..15) {
        switch (Get-SidecarHealth) {
            'none'    { return }
            'foreign' { throw "Port 45123 is held by another service (its /health does not identify as $ServiceName). Free the port and re-run; this installer will not kill an unrelated process." }
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Could not stop the existing sidecar on $SidecarUrl. Stop it manually (see the uninstall steps in README.md) and re-run."
}

Write-Host "--> Registering scheduled task '$TaskName' (at logon, hidden)"
Stop-Sidecar
$logonUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $VbsPath + '"')
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $logonUser
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "omp Antigravity masking sidecar proxy ($SidecarUrl) - supervised, windowless via wscript" `
    -RunLevel Limited -Force | Out-Null

# --- 6. Apply the models.yml plan -------------------------------------------
# The plan is recomputed here, immediately before writing: anything that edited
# models.yml since preflight (an editor, `umans omp --setup`) must not be
# silently reverted. The sidecar is already stopped at this point, so EVERY
# failure in this region - refusal, unreadable file, read-only target, denied
# backup - must still bring the replacement service back up before reporting.
function Restore-SidecarAfterFailure([string]$Headline, [string]$Detail) {
    Write-Warning $Headline
    if ($Detail) { Write-Warning "  $Detail" }
    Write-Host "--> Starting the sidecar anyway so it is not left stopped..."
    $started = $false
    try {
        Start-ScheduledTask -TaskName $TaskName
        foreach ($i in 1..15) {
            Start-Sleep -Seconds 1
            if ((Get-SidecarHealth) -eq 'ours') { $started = $true; break }
        }
    } catch {
        Write-Warning "  Could not start the task: $($_.Exception.Message.Split([char]10)[0])"
    }
    if ($started) {
        Write-Warning "The sidecar is RUNNING on $SidecarUrl, but models.yml may not have been"
        Write-Warning "updated, so its routing could not be verified. Check it and re-run this installer."
    } else {
        Write-Warning "The sidecar did NOT come back up. Start it with:"
        Write-Warning "  Start-ScheduledTask -TaskName $TaskName"
    }
    exit 2
}

$routed = $false
try {
    $plan = Get-YamlPlan
} catch {
    Restore-SidecarAfterFailure "Could not read or safely plan models.yml:" $_.Exception.Message.Split([char]10)[0]
}
try {
    switch ($plan.Plan) {
        'AlreadyRouted' {
            Write-Host "--> models.yml already routes google-antigravity through the sidecar; skipping."
            $routed = $true
        }
        'Conflict' {
            Write-Warning "models.yml $($plan.Reason)."
            Write-Warning "Leaving it untouched - set that provider's baseUrl to $SidecarUrl by hand to use the sidecar."
        }
        'Create' {
            Write-Host "--> models.yml not found; creating it with the sidecar override."
            New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
            $text = (@('providers:', '  google-antigravity:', "    baseUrl: `"$SidecarUrl`"")) -join "`r`n"
            [System.IO.File]::WriteAllText($ModelsYml, "$text`r`n", (New-Object System.Text.UTF8Encoding($false)))
            $routed = $true
        }
        'Insert' {
            if (-not (Test-Path $BackupYml)) {
                Write-Host "--> Backing up models.yml -> $(Split-Path $BackupYml -Leaf)"
                Copy-Item $ModelsYml $BackupYml
            }
            $doc   = $plan.Doc
            $lines = $doc.Lines
            $ci    = $plan.ChildIndent
            if ($plan.Idx -ge 0) {
                $block  = @("${ci}google-antigravity:", "${ci}${ci}baseUrl: `"$SidecarUrl`"")
                $head   = $lines[0..$plan.Idx]
                $tail   = if ($plan.Idx -lt ($lines.Count - 1)) { $lines[($plan.Idx + 1)..($lines.Count - 1)] } else { @() }
                $merged = @($head) + $block + @($tail)
            } else {
                $merged = @($lines) + @('providers:', '  google-antigravity:', "    baseUrl: `"$SidecarUrl`"")
            }
            Write-YamlDoc $ModelsYml $doc $merged
            Write-Host "--> Added google-antigravity -> $SidecarUrl override to models.yml"
            $routed = $true
        }
    }
} catch {
    Restore-SidecarAfterFailure "Could not apply the models.yml change:" $_.Exception.Message.Split([char]10)[0]
}

# --- 7. Start + verify ------------------------------------------------------
Write-Host "--> Starting sidecar via scheduled task..."
Start-ScheduledTask -TaskName $TaskName
$state = 'none'
foreach ($i in 1..15) {
    Start-Sleep -Seconds 1
    $state = Get-SidecarHealth
    if ($state -ne 'none') { break }
}

if ($state -eq 'foreign') {
    Write-Warning "Something is answering on $SidecarUrl but does not identify as $ServiceName."
    Write-Warning "The sidecar is NOT the service on that port. Free port 45123 and re-run."
    exit 1
}
if ($state -ne 'ours') {
    Write-Warning "Sidecar health check failed. Inspect with:"
    Write-Warning "  Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State"
    Write-Warning "  Get-Content '$(Format-PsLiteral $LogPath)' -Tail 40"
    Write-Warning "  & '$(Format-PsLiteral $bunExe)' '$(Format-PsLiteral $ProxyDst)'   # run in the foreground to see errors"
    exit 1
}

$restoreHint = if (Test-Path $BackupYml) {
    "  Copy-Item '$(Format-PsLiteral $BackupYml)' '$(Format-PsLiteral $ModelsYml)' -Force   # first-modification snapshot: discards later edits"
} else {
    "  Remove the 'google-antigravity' block from '$(Format-PsLiteral $ModelsYml)'"
}

if (-not $routed) {
    Write-Host "=========================================================="
    Write-Warning "ACTION REQUIRED: the sidecar is running on $SidecarUrl, but models.yml was"
    Write-Warning "left untouched, so its google-antigravity routing is not confirmed:"
    Write-Warning "  $($plan.Reason)"
    Write-Warning "Point that provider's baseUrl at $SidecarUrl and re-run (exit code 2)."
    Write-Host "=========================================================="
    exit 2
}

Write-Host "=========================================================="
Write-Host "  Sidecar is active and healthy on $SidecarUrl"
Write-Host "  Google Antigravity fake 429 WAF error is now bypassed!"
Write-Host "=========================================================="
Write-Host "Logs:      Get-Content '$(Format-PsLiteral $LogPath)' -Tail 40 -Wait"
Write-Host "Uninstall (stop the supervisor BEFORE its child, or it respawns):"
Write-Host "  Stop-ScheduledTask -TaskName $TaskName"
Write-Host "  Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
Write-Host "  `$dir = '$(Format-PsLiteral $SidecarDir)'"
Write-Host "  Get-CimInstance Win32_Process -Filter `"Name='wscript.exe' OR Name='cmd.exe' OR Name='bun.exe'`" |"
Write-Host "    Where-Object { `$_.CommandLine -and `$_.CommandLine.ToLower().Contains(`$dir.ToLower()) } |"
Write-Host "    ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }"
Write-Host $restoreHint
Write-Host "  Remove-Item '$(Format-PsLiteral $SidecarDir)' -Recurse -Force"
