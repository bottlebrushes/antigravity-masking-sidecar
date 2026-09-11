' Startup launcher for the Antigravity Masking Sidecar on Windows.
'
' install.ps1 drops a copy of this file into the per-user Startup folder. It
' probes the sidecar health endpoint first, so repeated logons never spawn a
' duplicate listener, and then starts Bun with no console window.
'
' Placeholders substituted by install.ps1:
'   __BUN__    -> absolute path to bun.exe
'   __SCRIPT__ -> absolute path to antigravity-masking-proxy.ts

Option Explicit

Dim http, shell, bun, script
bun = "__BUN__"
script = "__SCRIPT__"

On Error Resume Next
Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
http.Open "GET", "http://127.0.0.1:45123/health", False
http.Send
If Err.Number = 0 Then
  If http.Status = 200 Then WScript.Quit 0
End If
On Error GoTo 0

Set shell = CreateObject("WScript.Shell")
shell.Run """" & bun & """ """ & script & """", 0, False
