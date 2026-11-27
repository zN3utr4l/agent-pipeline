# Colours the Windows Terminal tab that runs the session and shows or withdraws its Windows notification.
#
# Read from the environment, all optional:
#   CC_NOTIFY_RING   OSC 9;4 state for the tab and its taskbar button: '4;100' (yellow), '1;100' (green),
#                    '2;100' (red), '3;0' (spinning), '0;0' (none)
#   CC_NOTIFY_TOAST  'show' or 'remove'
#   CC_NOTIFY_KIND   permission | question | plan | done | error: the icon and the sound
#   CC_NOTIFY_TITLE, CC_NOTIFY_TEXT, CC_NOTIFY_FOLDER, CC_NOTIFY_TAG, CC_NOTIFY_SOUND ('0' mutes)

$ErrorActionPreference = 'Stop'

$Aumid = if ($env:CC_NOTIFY_AUMID) { $env:CC_NOTIFY_AUMID } else { 'ClaudeCode.TurnNotify' }
$Group = if ($env:CC_NOTIFY_GROUP) { $env:CC_NOTIFY_GROUP } else { 'claude-code' }
$AppName = if ($env:CC_NOTIFY_APP) { $env:CC_NOTIFY_APP } else { 'Claude Code' }
$Home_ = if ($env:CC_NOTIFY_CACHE) { $env:CC_NOTIFY_CACHE } else { Join-Path $env:LOCALAPPDATA 'ClaudeCodeMods\turn-notify' }
$Assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'

$Source = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class ClaudeTab {
  [StructLayout(LayoutKind.Sequential)]
  struct Basic {
    public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId;
  }

  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass, ref Basic info, int size, out int length);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetConsoleTitle(StringBuilder title, uint size);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool WriteConsole(IntPtr handle, string text, uint count, out uint written, IntPtr reserved);

  static int ParentOf(int pid) {
    IntPtr process = OpenProcess(0x1000, false, pid);
    if (process == IntPtr.Zero) return 0;
    try {
      Basic info = new Basic();
      int length;
      return NtQueryInformationProcess(process, 0, ref info, Marshal.SizeOf(info), out length) == 0 ? info.InheritedFromUniqueProcessId.ToInt32() : 0;
    } finally {
      CloseHandle(process);
    }
  }

  // The nearest ancestor named claude: the process whose console is the terminal tab.
  public static int FindSession() {
    int pid = Process.GetCurrentProcess().Id;
    for (int depth = 0; depth < 8; depth++) {
      pid = ParentOf(pid);
      if (pid == 0) return 0;
      try {
        using (Process process = Process.GetProcessById(pid)) {
          if (string.Equals(process.ProcessName, "claude", StringComparison.OrdinalIgnoreCase)) return pid;
        }
      } catch (ArgumentException) {
        return 0;
      }
    }
    return 0;
  }

  // Joins the session's console: answers its title, writing the sequence first when there is one.
  public static string Touch(int pid, string sequence) {
    FreeConsole();
    if (!AttachConsole((uint)pid)) return null;
    try {
      if (!string.IsNullOrEmpty(sequence)) {
        IntPtr output = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (output != new IntPtr(-1)) {
          uint written;
          WriteConsole(output, sequence, (uint)sequence.Length, out written, IntPtr.Zero);
          CloseHandle(output);
        }
      }
      StringBuilder title = new StringBuilder(1024);
      GetConsoleTitle(title, 1024);
      return title.ToString();
    } finally {
      FreeConsole();
    }
  }
}
'@

# Compiled once per source version: Add-Type alone runs the C# compiler on every call.
function Import-ClaudeTab {
  $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Source))
  $dll = Join-Path $Home_ ('tab-' + [BitConverter]::ToString($sha).Replace('-', '').Substring(0, 12) + '.dll')

  try {
    if (-not (Test-Path $dll)) {
      New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
      Add-Type -TypeDefinition $Source -OutputAssembly $dll -OutputType Library
    }
    Add-Type -Path $dll
  } catch {
    Add-Type -TypeDefinition $Source
  }
}

# The session's name as Claude Code puts it in the tab title, without the status glyph in front.
function Get-SessionName([string]$title) {
  $name = ([string]$title -replace '^[^\p{L}\p{N}]+', '').Trim()

  if ($name -eq '' -or $name -eq 'Claude Code') { return $null }

  return $name
}

function Register-App {
  $key = "HKCU:\Software\Classes\AppUserModelId\$Aumid"
  $icon = Join-Path $Home_ 'claude.png'

  if (-not (Test-Path $icon)) {
    New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
    Copy-Item (Join-Path $Assets 'claude.png') $icon
  }

  $current = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue

  if ($null -eq $current -or $current.IconUri -ne $icon) {
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayName -Value $AppName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name IconUri -Value $icon -PropertyType String -Force | Out-Null
  }
}

function Escape([string]$text) { [Security.SecurityElement]::Escape([string]$text) }

function Get-ToastXml([string]$attribution) {
  $kind = if ($env:CC_NOTIFY_KIND) { $env:CC_NOTIFY_KIND } else { 'done' }
  $isWaiting = $kind -in 'permission', 'question', 'plan'
  $logo = ([Uri](Join-Path $Assets "$kind.png")).AbsoluteUri
  $folder = if ($env:CC_NOTIFY_FOLDER) { $env:CC_NOTIFY_FOLDER } else { $AppName }
  $audio = if ($env:CC_NOTIFY_SOUND -eq '0') {
    '<audio silent="true"/>'
  } elseif ($isWaiting) {
    '<audio src="ms-winsoundevent:Notification.Reminder"/>'
  } else {
    '<audio src="ms-winsoundevent:Notification.Default"/>'
  }
  $duration = if ($isWaiting) { ' duration="long"' } else { '' }
  $credit = if ($attribution) { "<text placement=`"attribution`">$(Escape $attribution)</text>" } else { '' }
  $body = if ($env:CC_NOTIFY_TEXT) { "<text>$(Escape $env:CC_NOTIFY_TEXT)</text>" } else { '' }

  $xml = @"
<toast$duration>
  <header id="$(Escape $folder.ToLowerInvariant())" title="$(Escape $folder)" arguments=""/>
  <visual>
    <binding template="ToastGeneric">
      <text hint-maxLines="1">$(Escape $env:CC_NOTIFY_TITLE)</text>
      $body
      $credit
      <image placement="appLogoOverride" hint-crop="circle" src="$(Escape $logo)"/>
    </binding>
  </visual>
  $audio
</toast>
"@
  return $xml
}

function Show-Toast([string]$attribution) {
  $xml = Get-ToastXml $attribution
  $isWaiting = $env:CC_NOTIFY_KIND -in 'permission', 'question', 'plan'
  Register-App
  $document = New-Object Windows.Data.Xml.Dom.XmlDocument
  $document.LoadXml($xml)
  $toast = New-Object Windows.UI.Notifications.ToastNotification $document
  $toast.Tag = $env:CC_NOTIFY_TAG
  $toast.Group = $Group
  $toast.ExpirationTime = [DateTimeOffset]::Now.AddHours($(if ($isWaiting) { 4 } else { 12 }))
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid).Show($toast)
}

$ring = $env:CC_NOTIFY_RING
$action = $env:CC_NOTIFY_TOAST
$title = $null

function Get-NotifySession {
  if ($env:CC_NOTIFY_OWNER_PID) {
    $session = 0
    try {
      $owner = Get-Process -Id ([int]$env:CC_NOTIFY_OWNER_PID) -ErrorAction Stop
      if ($env:CC_NOTIFY_OWNER_START -and $owner.StartTime.ToUniversalTime() -eq ([datetime]$env:CC_NOTIFY_OWNER_START).ToUniversalTime()) { $session = $owner.Id }
    } catch { }
    return $session
  }
  return [ClaudeTab]::FindSession()
}

if ($ring -or $action -eq 'show') {
  Import-ClaudeTab
  $session = Get-NotifySession

  if ($session -ne 0) {
    $sequence = if ($ring) { "$([char]27)]9;4;$ring$([char]27)\" } else { '' }
    $title = [ClaudeTab]::Touch($session, $sequence)
  }
}

if ($action) {
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

  if ($action -eq 'show') {
    Show-Toast (Get-SessionName $title)
  } elseif ($action -eq 'remove' -and $env:CC_NOTIFY_TAG) {
    [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($env:CC_NOTIFY_TAG, $Group, $Aumid)
  }
}
