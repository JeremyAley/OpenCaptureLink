<#
.SYNOPSIS
  Makes capture devices show up in apps that hide them, by giving each one a second
  DirectShow entry under a new name.

.DESCRIPTION
  Some apps skip devices that Windows already lists elsewhere. NVIDIA Broadcast, for
  example, ignores any DirectShow camera whose name is in its Media Foundation list, so a
  capture card that Media Foundation cannot open vanishes from it completely.

  OpenCaptureLink adds a "link": a DirectShow "Video Capture Sources" entry with a new name
  (for example "Live Gamer DUO - 2 (Direct)") that points at the real device through the
  stock Windows capture proxy (ksproxy.ax). Apps that open the link open the device itself.
  Nothing is installed or left running, and no video passes through this script.

  Links are registry entries only, written for both 64-bit and 32-bit apps. "AllUsers"
  (the default) needs an elevated prompt and is what most apps, including NVIDIA Broadcast,
  require. "CurrentUser" needs no admin but some apps ignore it.

.EXAMPLE
  .\OpenCaptureLink.ps1 -List
  .\OpenCaptureLink.ps1 -Add 2,3
  .\OpenCaptureLink.ps1 -Add "Live Gamer"
  .\OpenCaptureLink.ps1 -Remove all
  .\OpenCaptureLink.ps1 -Gui
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
  # Device numbers from -List, parts of device names, or "all".
  [Parameter(ParameterSetName = 'Add', Mandatory, Position = 0)][string[]]$Add,
  [Parameter(ParameterSetName = 'Remove', Mandatory, Position = 0)][string[]]$Remove,
  [Parameter(ParameterSetName = 'List')][switch]$List,
  [Parameter(ParameterSetName = 'Gui', Mandatory)][switch]$Gui,
  [ValidateSet('AllUsers', 'CurrentUser')][string]$Scope = 'AllUsers',
  [string]$Suffix = ' (Direct)',
  # Renders the GUI to a PNG instead of showing it (for docs and tests).
  [Parameter(ParameterSetName = 'Gui', DontShow)][string]$Snapshot
)
$ErrorActionPreference = 'Stop'

$CaptureCategory = '{860BB310-5D01-11D0-BD3B-00A0C911CE86}'  # CLSID_VideoInputDeviceCategory
$KsProxyClsid    = '{17CCA71B-ECD7-11D0-B908-00A0C9223196}'  # Windows WDM capture proxy
$InstancePath    = "Software\Classes\CLSID\$CaptureCategory\Instance"
$Marker          = 'OpenCaptureLink'
$LegacyMarkers   = @('dshow-alias')
$Views           = [Microsoft.Win32.RegistryView[]]('Registry64', 'Registry32')

# Serialized REGFILTER2: one video output pin, MERIT_DO_NOT_USE so graphs never auto-insert
# the link. The device enumerator will not bind an entry without it.
$FilterData = [byte[]](@(
  0x02,0,0,0, 0x00,0x00,0x20,0x00, 0x01,0,0,0, 0,0,0,0,
  0x30,0x70,0x69,0x33, 0x08,0,0,0, 0,0,0,0, 0x01,0,0,0, 0,0,0,0, 0,0,0,0,
  0x30,0x74,0x79,0x33, 0,0,0,0, 0x38,0,0,0, 0x48,0,0,0) +
  [Guid]::new('73646976-0000-0010-8000-00AA00389B71').ToByteArray() +  # MEDIATYPE_Video
  [Guid]::Empty.ToByteArray())                                           # any subtype

if (-not ('OpenCaptureLink.Devices' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
namespace OpenCaptureLink {
  public static class Devices {
    [ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid cat, out IEnumMoniker e, int flags); }
    [ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string name, out object v, IntPtr log); void Write(); }

    // {FriendlyName, DevicePath} for each hardware video capture device. Links are software
    // entries, so they never show up here.
    public static List<string[]> Hardware() {
      var result = new List<string[]>();
      var devEnum = (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11d0-BD3B-00A0C911CE86")));
      Guid cat = new Guid("860BB310-5D01-11d0-BD3B-00A0C911CE86"); IEnumMoniker e;
      if (devEnum.CreateClassEnumerator(ref cat, out e, 0x40 /* CDEF_DEVMON_PNP_DEVICE */) != 0) return result;
      var m = new IMoniker[1];
      while (e.Next(1, m, IntPtr.Zero) == 0) {
        object bag; Guid iid = typeof(IPropertyBag).GUID;
        m[0].BindToStorage(null, null, ref iid, out bag);
        object name, path;
        if (((IPropertyBag)bag).Read("FriendlyName", out name, IntPtr.Zero) == 0 &&
            ((IPropertyBag)bag).Read("DevicePath", out path, IntPtr.Zero) == 0)
          result.Add(new[] { ((string)name).Trim(), (string)path });
      }
      return result;
    }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  }
}
'@
}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
}

function Open-Root([string]$scope, [Microsoft.Win32.RegistryView]$view) {
  $hive = if ($scope -eq 'AllUsers') { 'LocalMachine' } else { 'CurrentUser' }
  [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
}

function Assert-CanWrite([string]$scope) {
  if ($scope -eq 'AllUsers' -and -not (Test-Admin)) {
    throw 'Changing links for all users needs PowerShell running as administrator (or use -Scope CurrentUser).'
  }
}

# Stable per-device ID, so apps that remember a selected camera keep it.
function Get-LinkId([string]$devicePath) {
  $md5 = [Security.Cryptography.MD5]::Create()
  try { $hash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($devicePath.ToLowerInvariant())) } finally { $md5.Dispose() }
  '{' + [Guid]::new($hash).ToString().ToUpperInvariant() + '}'
}

function Get-CaptureDevices {
  $index = 0
  foreach ($device in [OpenCaptureLink.Devices]::Hardware()) {
    $index++
    [pscustomobject]@{ Index = $index; Name = $device[0]; Path = $device[1]; Id = Get-LinkId $device[1] }
  }
}

function Get-Links([string]$scope) {
  $root = Open-Root $scope 'Registry64'
  $instances = $root.OpenSubKey($InstancePath)
  try {
    if (-not $instances) { return }
    foreach ($id in $instances.GetSubKeyNames()) {
      $key = $instances.OpenSubKey($id)
      if (-not $key) { continue }
      $createdBy = $key.GetValue('CreatedBy')
      if ($createdBy -eq $Marker -or $LegacyMarkers -contains $createdBy) {
        [pscustomobject]@{ Id = $id; Name = $key.GetValue('FriendlyName'); Path = $key.GetValue('DevicePath'); Scope = $scope }
      }
      $key.Close()
    }
  } finally {
    if ($instances) { $instances.Close() }
    $root.Close()
  }
}

function Set-Link($device, [string]$scope) {
  foreach ($view in $Views) {
    $root = Open-Root $scope $view
    $key = $root.CreateSubKey("$InstancePath\$($device.Id)")
    try {
      $key.SetValue('FriendlyName', $device.Name + $Suffix)
      $key.SetValue('CLSID', $KsProxyClsid)
      $key.SetValue('DevicePath', $device.Path)
      $key.SetValue('FilterData', $FilterData, 'Binary')
      $key.SetValue('CreatedBy', $Marker)
    } finally {
      $key.Close()
      $root.Close()
    }
  }
}

function Remove-Link([string]$id, [string]$scope) {
  foreach ($view in $Views) {
    $root = Open-Root $scope $view
    $instances = $root.OpenSubKey($InstancePath, $true)
    try {
      if ($instances) { $instances.DeleteSubKeyTree($id, $false) }
    } finally {
      if ($instances) { $instances.Close() }
      $root.Close()
    }
  }
}

# Resolves "all", device numbers and name fragments to devices.
function Select-Devices([string[]]$selectors, $devices) {
  $picked = foreach ($selector in $selectors) {
    $number = 0
    $hits = if ($selector -eq 'all') { $devices }
            elseif ([int]::TryParse($selector, [ref]$number)) { $devices | Where-Object Index -eq $number }
            else { $devices | Where-Object { $_.Name -like "*$selector*" } }
    if (-not $hits) { throw "No capture device matches '$selector'. Run with -List to see devices." }
    $hits
  }
  $picked | Sort-Object Index -Unique
}

function Show-List {
  $devices = @(Get-CaptureDevices)
  $links = @(Get-Links 'AllUsers') + @(Get-Links 'CurrentUser')
  $rows = foreach ($device in $devices) {
    $scopes = ($links | Where-Object Id -eq $device.Id | ForEach-Object { if ($_.Scope -eq 'AllUsers') { 'all users' } else { 'this user' } }) -join ', '
    [pscustomobject]@{ '#' = $device.Index; Device = $device.Name; Linked = if ($scopes) { "yes ($scopes)" } else { '' } }
  }
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Stream | Where-Object { $_ } } else { 'No video capture devices found.' }

  $orphans = $links | Where-Object { $_.Id -notin $devices.Id }
  if ($orphans) {
    ''
    'Links to devices that are not connected:'
    $orphans | ForEach-Object { "  $($_.Name)" }
  }
  ''
  'Link devices with -Add <number or name>, remove links with -Remove <number, name or all>.'
}

function Show-Gui([string]$snapshot) {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  [void][OpenCaptureLink.Devices]::SetProcessDPIAware()
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $isAdmin = Test-Admin

  $form = New-Object System.Windows.Forms.Form -Property @{
    Text = 'OpenCaptureLink'; StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false; MinimizeBox = $false; AutoScaleMode = 'Font'
    Font = New-Object System.Drawing.Font('Segoe UI', 9); ClientSize = New-Object System.Drawing.Size(460, 400)
    Padding = New-Object System.Windows.Forms.Padding(12)
  }
  $layout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 5 }
  foreach ($style in 'AutoSize', 'Percent', 'AutoSize', 'AutoSize', 'AutoSize') {
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($style, 100)))
  }

  $intro = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $true; MaximumSize = New-Object System.Drawing.Size(430, 0); Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    Text = "Check a device to add a `"$($Suffix.Trim())`" copy of it that apps can see, even ones that hide the original (like NVIDIA Broadcast with some capture cards). The copy opens the real device directly, so there is no extra delay."
  }
  $list = New-Object System.Windows.Forms.CheckedListBox -Property @{ Dock = 'Fill'; CheckOnClick = $true; IntegralHeight = $false }

  $scopeRow = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0) }
  $allUsers = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'All users (recommended)'; AutoSize = $true; Checked = ($Scope -eq 'AllUsers') }
  $justMe = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Just me'; AutoSize = $true; Checked = ($Scope -eq 'CurrentUser') }
  $scopeRow.Controls.AddRange(@($allUsers, $justMe))

  $status = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $true; MaximumSize = New-Object System.Drawing.Size(430, 0); ForeColor = [System.Drawing.SystemColors]::GrayText
    Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
  }
  $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; Dock = 'Fill'; FlowDirection = 'RightToLeft' }
  $close = New-Object System.Windows.Forms.Button -Property @{ Text = 'Close'; AutoSize = $true; DialogResult = 'Cancel' }
  $apply = New-Object System.Windows.Forms.Button -Property @{ Text = 'Apply'; AutoSize = $true }
  $buttons.Controls.AddRange(@($close, $apply))
  $form.AcceptButton = $apply
  $form.CancelButton = $close

  $layout.Controls.AddRange(@($intro, $list, $scopeRow, $status, $buttons))
  $form.Controls.Add($layout)

  # Each list item is a device, or a link whose device is no longer connected.
  $state = @{ Rows = @() }
  $currentScope = { if ($allUsers.Checked) { 'AllUsers' } else { 'CurrentUser' } }
  $load = {
    $scope = & $currentScope
    $devices = @(Get-CaptureDevices)
    $links = @(Get-Links $scope)
    $state.Rows = @($devices | ForEach-Object { [pscustomobject]@{ Device = $_; Id = $_.Id; Linked = $_.Id -in $links.Id; Text = $_.Name } }) +
                  @($links | Where-Object { $_.Id -notin $devices.Id } | ForEach-Object { [pscustomobject]@{ Device = $null; Id = $_.Id; Linked = $true; Text = "$($_.Name) - not connected" } })
    $list.Items.Clear()
    foreach ($row in $state.Rows) { [void]$list.Items.Add($row.Text, $row.Linked) }

    $canWrite = $isAdmin -or $scope -eq 'CurrentUser'
    $apply.Enabled = $canWrite
    $list.Enabled = $canWrite
    $status.Text = if (-not $state.Rows) { 'No video capture devices found.' }
                   elseif (-not $canWrite) { 'Run OpenCaptureLink as administrator to change links for all users.' }
                   else { 'Restart your apps after applying. Fully quit NVIDIA Broadcast from the system tray.' }
  }

  $apply.Add_Click({
    $scope = & $currentScope
    try {
      for ($i = 0; $i -lt $state.Rows.Count; $i++) {
        $row = $state.Rows[$i]
        $checked = $list.GetItemChecked($i)
        if ($checked -and $row.Device) { Set-Link $row.Device $scope }
        elseif (-not $checked -and $row.Linked) { Remove-Link $row.Id $scope }
      }
      & $load
      $status.Text = 'Saved. Restart your apps to see the changes. Fully quit NVIDIA Broadcast from the system tray.'
    } catch {
      [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'OpenCaptureLink', 'OK', 'Error')
    }
  })
  $allUsers.Add_CheckedChanged({ if ($allUsers.Checked) { & $load } })
  $justMe.Add_CheckedChanged({ if ($justMe.Checked) { & $load } })

  & $load
  if ($snapshot) {
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bitmap.Save($snapshot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Close()
    return
  }
  [void]$form.ShowDialog()
}

switch ($PSCmdlet.ParameterSetName) {
  'Gui' {
    # Elevate for all-users changes; if the prompt is declined, open with "Just me" instead.
    # PowerShell hides its own console via its -WindowStyle argument. Passing -WindowStyle to
    # Start-Process instead would hide the first window the new process shows: ours.
    if (-not $Snapshot -and -not (Test-Admin) -and $Scope -eq 'AllUsers') {
      try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-Gui')
        return
      } catch {
        $Scope = 'CurrentUser'
      }
    }
    try {
      Show-Gui $Snapshot
    } catch {
      Add-Type -AssemblyName System.Windows.Forms
      [void][System.Windows.Forms.MessageBox]::Show("OpenCaptureLink could not start:`n`n$($_.Exception.Message)", 'OpenCaptureLink', 'OK', 'Error')
    }
  }
  'Add' {
    Assert-CanWrite $Scope
    foreach ($device in Select-Devices $Add @(Get-CaptureDevices)) {
      Set-Link $device $Scope
      "Linked: $($device.Name)$Suffix"
    }
    'Restart your apps to see the changes. Fully quit NVIDIA Broadcast from the system tray.'
  }
  'Remove' {
    Assert-CanWrite $Scope
    $links = @(Get-Links $Scope)
    $devices = @(Get-CaptureDevices)
    $targets = foreach ($selector in $Remove) {
      $number = 0
      $hits = if ($selector -eq 'all') { $links }
              elseif ([int]::TryParse($selector, [ref]$number)) { $links | Where-Object Id -in @($devices | Where-Object Index -eq $number).Id }
              else { $links | Where-Object { $_.Name -like "*$selector*" } }
      if (-not $hits -and $selector -ne 'all') { throw "No link matches '$selector'. Run with -List to see links." }
      $hits
    }
    $targets = @($targets | Sort-Object Id -Unique)
    foreach ($link in $targets) {
      Remove-Link $link.Id $Scope
      "Removed: $($link.Name)"
    }
    if (-not $targets) { 'No links to remove.' }
  }
  default { Show-List }
}
