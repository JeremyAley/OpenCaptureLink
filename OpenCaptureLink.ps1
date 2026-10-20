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

  "-Type MediaFoundation" makes a Windows 11 virtual camera instead, for apps that only use
  Media Foundation (such as the Windows Camera app). Windows' camera service loads
  OpenCaptureLinkCamera.dll, which opens the device through DirectShow and passes each frame
  on, so it costs a frame copy. The DLL is copied to Program Files. These links need admin,
  are always for all users, and DirectShow apps see them too. A device has one type of link
  at a time: adding one type removes the other.

.EXAMPLE
  .\OpenCaptureLink.ps1 -List
  .\OpenCaptureLink.ps1 -Add 2,3
  .\OpenCaptureLink.ps1 -Add "Live Gamer"
  .\OpenCaptureLink.ps1 -Add 2 -Type MediaFoundation
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
  # Kind of link to add (replacing the device's other kind). -Remove removes both kinds unless
  # -Type is given.
  [ValidateSet('DirectShow', 'MediaFoundation')][string]$Type = 'DirectShow',
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

# Media Foundation links: a COM class per link (read by OpenCaptureLinkCamera.dll inside
# Windows' camera service), plus an index under our own key so links can be listed.
$CameraDllName   = 'OpenCaptureLinkCamera.dll'
$CameraDir       = Join-Path $env:ProgramFiles 'OpenCaptureLink'
$CameraLogDir    = Join-Path $env:ProgramData 'OpenCaptureLink'
$CameraIndexPath = 'Software\OpenCaptureLink\Cameras'
$ClassesPath     = 'Software\Classes\CLSID'
$LocalServiceSid = 'S-1-5-19'  # Windows' camera service runs as LOCAL SERVICE

# Serialized REGFILTER2: one video output pin, MERIT_DO_NOT_USE so graphs never auto-insert
# the link. The device enumerator will not bind an entry without it.
$FilterData = [byte[]](@(
  0x02,0,0,0, 0x00,0x00,0x20,0x00, 0x01,0,0,0, 0,0,0,0,
  0x30,0x70,0x69,0x33, 0x08,0,0,0, 0,0,0,0, 0x01,0,0,0, 0,0,0,0, 0,0,0,0,
  0x30,0x74,0x79,0x33, 0,0,0,0, 0x38,0,0,0, 0x48,0,0,0) +
  [Guid]::new('73646976-0000-0010-8000-00AA00389B71').ToByteArray() +  # MEDIATYPE_Video
  [Guid]::Empty.ToByteArray())                                           # any subtype

if (-not ('OpenCaptureLink.VirtualCamera' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
namespace OpenCaptureLink {
  public static class Devices {
    [ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid cat, out IEnumMoniker e, int flags); }
    [ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string name, out object v, IntPtr log); void Write(); }

    // {FriendlyName, DevicePath} for each hardware video capture device. DirectShow links are
    // software entries, so they never show up here; Windows virtual cameras (including our
    // Media Foundation links) do, and are skipped.
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
            ((IPropertyBag)bag).Read("DevicePath", out path, IntPtr.Zero) == 0 &&
            !((string)path).StartsWith(@"\\?\swd#vcamdevapi#", StringComparison.OrdinalIgnoreCase))
          result.Add(new[] { ((string)name).Trim(), (string)path });
      }
      return result;
    }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    // Deletes a file or empty folder at the next restart (MOVEFILE_DELAY_UNTIL_REBOOT).
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool MoveFileEx(string from, string to, int flags);
    public static bool DeleteAtRestart(string path) { return MoveFileEx(path, null, 4); }
  }

  // Windows 11 virtual cameras (mfvirtualcamera.h). Lifetime System and access AllUsers: the
  // camera stays registered for everyone until it is removed.
  public static class VirtualCamera {
    [DllImport("mfsensorgroup.dll", CharSet = CharSet.Unicode)]
    static extern int MFCreateVirtualCamera(int type, int lifetime, int access, string name, string sourceId, IntPtr categories, uint count, out IntPtr camera);
    delegate int StartFn(IntPtr self, IntPtr callback);
    delegate int CallFn(IntPtr self);
    // IMFVirtualCamera vtable: IUnknown (0-2), IMFAttributes (3-32), AddDeviceSourceInfo,
    // AddProperty, AddRegistryEntry, Start (36), Stop, Remove (38), GetMediaSource,
    // SendCameraProperty, CreateSyncEvent, CreateSyncSemaphore, Shutdown (43).
    static T Method<T>(IntPtr o, int index) where T : class {
      return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(o), index * IntPtr.Size), typeof(T)) as T;
    }

    public static bool Supported() {
      IntPtr module = LoadLibrary("mfsensorgroup.dll");
      return module != IntPtr.Zero && GetProcAddress(module, "MFCreateVirtualCamera") != IntPtr.Zero;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);

    public static void Add(string name, string classId) { Run(name, classId, false); }
    public static void Remove(string name, string classId) { Run(name, classId, true); }

    // Runs on its own thread with a time limit, so a stuck camera service can't hang us.
    static void Run(string name, string classId, bool remove) {
      int hr = 0; string step = "MFCreateVirtualCamera";
      var thread = new System.Threading.Thread(() => {
        IntPtr camera;
        hr = MFCreateVirtualCamera(0 /* SoftwareCameraSource */, 1 /* System */, 1 /* AllUsers */, name, classId, IntPtr.Zero, 0, out camera);
        if (hr != 0) return;
        try {
          step = remove ? "Remove" : "Start";
          hr = remove ? Method<CallFn>(camera, 38)(camera) : Method<StartFn>(camera, 36)(camera, IntPtr.Zero);
          Method<CallFn>(camera, 43)(camera);
        } finally { Marshal.Release(camera); }
      });
      thread.IsBackground = true;
      thread.SetApartmentState(System.Threading.ApartmentState.MTA);
      thread.Start();
      if (!thread.Join(30000)) throw new TimeoutException("Windows' camera service did not respond. Restart the computer and try again.");
      if (hr != 0) throw new COMException(string.Format("Virtual camera {0} failed (0x{1:X8}).", step, hr), hr);
    }
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

# Stable per-device ID, so apps that remember a selected camera keep it. Media Foundation
# links get a different ID from the same path, for their COM class.
function Get-LinkId([string]$devicePath, [string]$salt = '') {
  $md5 = [Security.Cryptography.MD5]::Create()
  try { $hash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($salt + $devicePath.ToLowerInvariant())) } finally { $md5.Dispose() }
  '{' + [Guid]::new($hash).ToString().ToUpperInvariant() + '}'
}

function Get-CameraId([string]$devicePath) { Get-LinkId $devicePath 'OpenCaptureLink camera:' }

function Get-CaptureDevices {
  $index = 0
  foreach ($device in [OpenCaptureLink.Devices]::Hardware()) {
    $index++
    [pscustomobject]@{ Index = $index; Name = $device[0]; Path = $device[1]; Id = Get-LinkId $device[1] }
  }
}

# Why Media Foundation links can't be made on this PC, or $null if they can.
function Get-MediaFoundationProblem {
  if (-not [OpenCaptureLink.VirtualCamera]::Supported()) { return 'Media Foundation links need Windows 11.' }
  if (-not (Test-Path (Join-Path $PSScriptRoot $CameraDllName))) { return "$CameraDllName is missing. Download the full release and unzip all of it." }
  $null
}

# Links of both types. DeviceId matches the device's Id, also for Media Foundation links.
function Get-Links([string]$scope) {
  $root = Open-Root $scope 'Registry64'
  $instances = $root.OpenSubKey($InstancePath)
  try {
    if ($instances) {
      foreach ($id in $instances.GetSubKeyNames()) {
        $key = $instances.OpenSubKey($id)
        if (-not $key) { continue }
        $createdBy = $key.GetValue('CreatedBy')
        if ($createdBy -eq $Marker -or $LegacyMarkers -contains $createdBy) {
          [pscustomobject]@{ Id = $id; DeviceId = $id; Name = $key.GetValue('FriendlyName'); Path = $key.GetValue('DevicePath'); Scope = $scope; Type = 'DirectShow' }
        }
        $key.Close()
      }
    }
  } finally {
    if ($instances) { $instances.Close() }
    $root.Close()
  }
  if ($scope -eq 'AllUsers') {
    $root = Open-Root 'AllUsers' 'Registry64'
    $cameras = $root.OpenSubKey($CameraIndexPath)
    try {
      if ($cameras) {
        foreach ($id in $cameras.GetSubKeyNames()) {
          $key = $cameras.OpenSubKey($id)
          if (-not $key) { continue }
          $path = $key.GetValue('DevicePath')
          [pscustomobject]@{ Id = $id; DeviceId = Get-LinkId $path; Name = $key.GetValue('FriendlyName'); Path = $path; Scope = 'AllUsers'; Type = 'MediaFoundation' }
          $key.Close()
        }
      }
    } finally {
      if ($cameras) { $cameras.Close() }
      $root.Close()
    }
  }
}

# Copies the camera DLL where Windows' camera service can load it, and lets the service write
# its log. The DLL may be loaded; Windows allows renaming a loaded file, so move it aside.
function Install-CameraDll {
  $source = Join-Path $PSScriptRoot $CameraDllName
  $target = Join-Path $CameraDir $CameraDllName
  [void](New-Item -ItemType Directory -Force $CameraDir)
  foreach ($old in @(Get-ChildItem $CameraDir -Filter '*.old' -ErrorAction SilentlyContinue)) {
    try { Remove-Item $old.FullName -Force } catch { [void][OpenCaptureLink.Devices]::DeleteAtRestart($old.FullName) }
  }
  if (-not (Test-Path $target) -or (Get-FileHash $source).Hash -ne (Get-FileHash $target).Hash) {
    if (Test-Path $target) {
      try { Remove-Item $target -Force }
      catch {
        $aside = "$target.$([DateTime]::Now.Ticks).old"
        Move-Item $target $aside -Force
        [void][OpenCaptureLink.Devices]::DeleteAtRestart($aside)
      }
    }
    Copy-Item $source $target
  }

  # Any user can create folders in ProgramData, so don't trust one that is already there: drop
  # a junction, then take ownership and set the permissions outright.
  $existing = Get-Item $CameraLogDir -Force -ErrorAction SilentlyContinue
  if ($existing -and ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($CameraLogDir) }
  [void](New-Item -ItemType Directory -Force $CameraLogDir)
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))  # Administrators
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'), @($LocalServiceSid, 'Modify'))) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
      (New-Object System.Security.Principal.SecurityIdentifier($rule[0])), $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
  }
  Set-Acl $CameraLogDir $acl
  Get-ChildItem $CameraLogDir -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint -or $_.LinkType -eq 'HardLink' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
  $target
}

# Removes the DLL once no Media Foundation link needs it. A process may still have it loaded
# (Windows' camera service, or any app that listed DirectShow cameras, this script included,
# since DirectShow lists virtual cameras by loading them). Then it is moved aside, so a new
# link can install a fresh copy, and deleted at the next restart.
function Uninstall-CameraDll {
  if (@(Get-Links 'AllUsers' | Where-Object Type -eq 'MediaFoundation').Count) { return }
  foreach ($file in @(Get-ChildItem $CameraDir -File -ErrorAction SilentlyContinue)) {
    try { Remove-Item $file.FullName -Force }
    catch {
      $aside = $file.FullName
      if ($file.Extension -ne '.old') {
        $aside = "$($file.FullName).$([DateTime]::Now.Ticks).old"
        try { Move-Item $file.FullName $aside -Force } catch { $aside = $file.FullName }
      }
      [void][OpenCaptureLink.Devices]::DeleteAtRestart($aside)
    }
  }
  try { [IO.Directory]::Delete($CameraDir) } catch { [void][OpenCaptureLink.Devices]::DeleteAtRestart($CameraDir) }
}

function Set-Link($device, [string]$scope, [string]$type) {
  $name = $device.Name + $Suffix
  if ($type -eq 'MediaFoundation') {
    $problem = Get-MediaFoundationProblem
    if ($problem) { throw $problem }
    $id = Get-CameraId $device.Path
    $old = Get-Links 'AllUsers' | Where-Object Id -eq $id
    if ($old -and $old.Name -ne $name) { Remove-Link $old }  # renamed: the old camera would stay
    $dll = Install-CameraDll
    $root = Open-Root 'AllUsers' 'Registry64'
    try {
      $key = $root.CreateSubKey("$ClassesPath\$id")
      $key.SetValue('', $name)
      $key.SetValue('DevicePath', $device.Path)
      $key.SetValue('CreatedBy', $Marker)
      $server = $key.CreateSubKey('InprocServer32')
      $server.SetValue('', $dll)
      $server.SetValue('ThreadingModel', 'Both')
      $server.Close()
      $key.Close()
      $key = $root.CreateSubKey("$CameraIndexPath\$id")
      $key.SetValue('FriendlyName', $name)
      $key.SetValue('DevicePath', $device.Path)
      $key.Close()
    } finally { $root.Close() }
    try { [OpenCaptureLink.VirtualCamera]::Add($name, $id) }
    catch { Remove-Link ([pscustomobject]@{ Id = $id; Name = $name; Scope = 'AllUsers'; Type = $type }); throw }
    return
  }
  foreach ($view in $Views) {
    $root = Open-Root $scope $view
    $key = $root.CreateSubKey("$InstancePath\$($device.Id)")
    try {
      $key.SetValue('FriendlyName', $name)
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

# Gives a device a link of one type, then removes its links of the other type (DirectShow in
# either scope, or Media Foundation): a Media Foundation link already shows up in DirectShow
# apps, so both would list the device twice there. Returns the removed links.
function Set-DeviceLink($device, [string]$scope, [string]$type) {
  $others = @(@(Get-Links 'AllUsers') + @(Get-Links 'CurrentUser') |
              Where-Object { $_.DeviceId -eq $device.Id -and $_.Type -ne $type })
  if (-not (Test-Admin) -and ($others | Where-Object Scope -eq 'AllUsers')) {
    throw "$($device.Name) has a $(Get-LinkLabel ($others | Where-Object Scope -eq 'AllUsers' | Select-Object -First 1)) link. Switching it needs PowerShell running as administrator."
  }
  Set-Link $device $scope $type
  foreach ($link in $others) { Remove-Link $link; $link }
}

function Remove-Link($link) {
  if ($link.Type -eq 'MediaFoundation') {
    try { [OpenCaptureLink.VirtualCamera]::Remove($link.Name, $link.Id) }
    catch {
      # No answer: the camera may still exist, so keep what is needed to remove it later. Any
      # other failure means Windows has no such camera (any more); finish cleaning up.
      if ($_.Exception.GetBaseException() -is [TimeoutException]) { throw }
      Write-Warning "$($link.Name): $($_.Exception.GetBaseException().Message)"
    }
    $root = Open-Root 'AllUsers' 'Registry64'
    try {
      $root.DeleteSubKeyTree("$ClassesPath\$($link.Id)", $false)
      $root.DeleteSubKeyTree("$CameraIndexPath\$($link.Id)", $false)
    } finally { $root.Close() }
    Uninstall-CameraDll
    return
  }
  foreach ($view in $Views) {
    $root = Open-Root $link.Scope $view
    $instances = $root.OpenSubKey($InstancePath, $true)
    try {
      if ($instances) { $instances.DeleteSubKeyTree($link.Id, $false) }
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

function Get-LinkLabel($link) {
  if ($link.Type -eq 'MediaFoundation') { 'Media Foundation' }
  elseif ($link.Scope -eq 'AllUsers') { 'DirectShow, all users' }
  else { 'DirectShow, this user' }
}

function Show-List {
  $devices = @(Get-CaptureDevices)
  $links = @(Get-Links 'AllUsers') + @(Get-Links 'CurrentUser')
  $rows = foreach ($device in $devices) {
    $labels = ($links | Where-Object DeviceId -eq $device.Id | ForEach-Object { Get-LinkLabel $_ }) -join '; '
    [pscustomobject]@{ '#' = $device.Index; Device = $device.Name; Linked = $labels }
  }
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Stream | Where-Object { $_ } } else { 'No video capture devices found.' }

  $orphans = $links | Where-Object { $_.DeviceId -notin $devices.Id }
  if ($orphans) {
    ''
    'Links to devices that are not connected:'
    $orphans | ForEach-Object { "  $($_.Name) ($(Get-LinkLabel $_))" }
  }
  ''
  'Link devices with -Add <number or name> [-Type MediaFoundation], remove links with -Remove <number, name or all>.'
}

function Show-Gui([string]$snapshot) {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  [void][OpenCaptureLink.Devices]::SetProcessDPIAware()
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $isAdmin = Test-Admin

  $form = New-Object System.Windows.Forms.Form -Property @{
    Text = 'OpenCaptureLink'; StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false; MinimizeBox = $false; AutoScaleMode = 'Font'
    Font = New-Object System.Drawing.Font('Segoe UI', 9); ClientSize = New-Object System.Drawing.Size(540, 470)
    Padding = New-Object System.Windows.Forms.Padding(12)
  }
  $layout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 6 }
  foreach ($style in 'AutoSize', 'Percent', 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize') {
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($style, 100)))
  }

  $intro = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $true; MaximumSize = New-Object System.Drawing.Size(510, 0); Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    Text = "Pick a link for a device to add a `"$($Suffix.Trim())`" copy of it that apps can see, even ones that hide the original (like NVIDIA Broadcast with some capture cards)."
  }

  # One row per device, with a dropdown for its link. A device has one link type at a time.
  $labels = [ordered]@{ Off = 'Off'; DirectShow = 'DirectShow (Recommended)'; MediaFoundation = 'Media Foundation' }
  $grid = New-Object System.Windows.Forms.DataGridView -Property @{
    Dock = 'Fill'; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; AllowUserToResizeRows = $false
    AllowUserToResizeColumns = $false; RowHeadersVisible = $false; MultiSelect = $false; EditMode = 'EditOnEnter'
    AutoSizeColumnsMode = 'Fill'; BackgroundColor = [System.Drawing.SystemColors]::Window; BorderStyle = 'FixedSingle'
    ColumnHeadersHeightSizeMode = 'AutoSize'
  }
  $deviceColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{ HeaderText = 'Device'; ReadOnly = $true; FillWeight = 58; SortMode = 'NotSortable' }
  $linkColumn = New-Object System.Windows.Forms.DataGridViewComboBoxColumn -Property @{ HeaderText = 'Link'; FillWeight = 42; DisplayStyle = 'DropDownButton'; FlatStyle = 'Flat' }
  $linkColumn.Items.AddRange([object[]]@($labels.Values))
  $grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($deviceColumn, $linkColumn))
  # Commit dropdown picks right away, and never show WinForms' data error dialog.
  $grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit('CurrentCellChange') } })
  $grid.Add_DataError({ $_.ThrowException = $false })
  $deviceColumn.DefaultCellStyle.SelectionBackColor = [System.Drawing.SystemColors]::Window
  $deviceColumn.DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::WindowText

  $legend = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $true; MaximumSize = New-Object System.Drawing.Size(510, 0); Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    Text = "DirectShow (Recommended) opens the real device directly, so there is no extra delay.`nMedia Foundation: only use if DirectShow does not work in your program - adds overhead. Windows 11 only; apps list it as `"<device>$Suffix (Windows Virtual Camera)`"."
  }

  $scopeRow = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0) }
  $scopeLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'DirectShow links for:'; AutoSize = $true; Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 0) }
  $allUsers = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'All users (recommended)'; AutoSize = $true; Checked = ($Scope -eq 'AllUsers') }
  $justMe = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Just me'; AutoSize = $true; Checked = ($Scope -eq 'CurrentUser') }
  $scopeRow.Controls.AddRange(@($scopeLabel, $allUsers, $justMe))

  $status = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $true; MaximumSize = New-Object System.Drawing.Size(510, 0); ForeColor = [System.Drawing.SystemColors]::GrayText
    Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
  }
  $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; Dock = 'Fill'; FlowDirection = 'RightToLeft' }
  $close = New-Object System.Windows.Forms.Button -Property @{ Text = 'Close'; AutoSize = $true; DialogResult = 'Cancel' }
  $apply = New-Object System.Windows.Forms.Button -Property @{ Text = 'Apply'; AutoSize = $true }
  $buttons.Controls.AddRange(@($close, $apply))
  $form.AcceptButton = $apply
  $form.CancelButton = $close

  $layout.Controls.AddRange(@($intro, $grid, $legend, $scopeRow, $status, $buttons))
  $form.Controls.Add($layout)

  # Each row is a device, or links whose device is no longer connected (those can only be
  # turned off). DirectShow links follow the scope; Media Foundation links are for all users.
  $state = @{ Rows = @() }
  $currentScope = { if ($allUsers.Checked) { 'AllUsers' } else { 'CurrentUser' } }
  $load = {
    $scope = & $currentScope
    $devices = @(Get-CaptureDevices)
    $links = @(Get-Links $scope | Where-Object Type -eq 'DirectShow') + @(Get-Links 'AllUsers' | Where-Object Type -eq 'MediaFoundation')
    $makeRow = {
      param($device, $deviceId, $text)
      $own = @($links | Where-Object DeviceId -eq $deviceId)
      $current = if ($own.Type -contains 'MediaFoundation') { 'MediaFoundation' } elseif ($own) { 'DirectShow' } else { 'Off' }
      [pscustomobject]@{ Device = $device; Links = $own; Current = $current; Text = $text }
    }
    $state.Rows = @($devices | ForEach-Object { & $makeRow $_ $_.Id $_.Name }) +
                  @($links | Where-Object { $_.DeviceId -notin $devices.Id } | Group-Object DeviceId | ForEach-Object {
                      & $makeRow $null $_.Name "$($_.Group[0].Name) - not connected" })

    $problem = Get-MediaFoundationProblem
    $canWrite = $isAdmin -or $scope -eq 'CurrentUser'
    $mediaFoundationOk = $isAdmin -and -not $problem
    $grid.Rows.Clear()
    foreach ($row in $state.Rows) {
      $index = $grid.Rows.Add($row.Text, $labels[$row.Current])
      $cell = $grid.Rows[$index].Cells[1]
      $choices = if (-not $row.Device) { @('Off', $row.Current) | Select-Object -Unique }
                 elseif ($mediaFoundationOk -or $row.Current -eq 'MediaFoundation') { 'Off', 'DirectShow', 'MediaFoundation' }
                 else { 'Off', 'DirectShow' }
      $cell.Items.Clear()
      foreach ($choice in $choices) { [void]$cell.Items.Add($labels[$choice]) }
      # Changing a Media Foundation link always needs administrator rights.
      $cell.ReadOnly = -not $canWrite -or ($row.Current -eq 'MediaFoundation' -and -not $isAdmin)
    }
    $grid.ClearSelection()
    $apply.Enabled = $canWrite
    $status.Text = if (-not $state.Rows) { 'No video capture devices found.' }
                   elseif (-not $canWrite) { 'Run OpenCaptureLink as administrator to change links for all users.' }
                   elseif (-not $isAdmin) { 'Run OpenCaptureLink as administrator for Media Foundation links. Restart your apps after applying.' }
                   elseif ($problem) { "$problem Restart your apps after applying." }
                   else { 'Restart your apps after applying. Fully quit NVIDIA Broadcast from the system tray.' }
  }

  $apply.Add_Click({
    $scope = & $currentScope
    $form.UseWaitCursor = $true
    try {
      [void]$grid.EndEdit()
      for ($i = 0; $i -lt $state.Rows.Count; $i++) {
        $row = $state.Rows[$i]
        $label = $grid.Rows[$i].Cells[1].Value
        $wanted = @($labels.Keys | Where-Object { $labels[$_] -eq $label })[0]
        if (-not $wanted -or $wanted -eq $row.Current) { continue }
        if ($wanted -eq 'Off') { foreach ($link in $row.Links) { Remove-Link $link } }
        elseif ($row.Device) { Set-DeviceLink $row.Device $scope $wanted }
      }
      & $load
      $status.Text = 'Saved. Restart your apps to see the changes. Fully quit NVIDIA Broadcast from the system tray.'
    } catch {
      [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'OpenCaptureLink', 'OK', 'Error')
      & $load
    } finally { $form.UseWaitCursor = $false }
  })
  foreach ($radio in $allUsers, $justMe) {
    $radio.Add_CheckedChanged({ if ($this.Checked) { & $load } })
  }

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
      if ($Snapshot) { throw }  # tests: fail instead of waiting on a dialog
      Add-Type -AssemblyName System.Windows.Forms
      [void][System.Windows.Forms.MessageBox]::Show("OpenCaptureLink could not start:`n`n$($_.Exception.Message)", 'OpenCaptureLink', 'OK', 'Error')
    }
  }
  'Add' {
    Assert-CanWrite $Scope
    if ($Type -eq 'MediaFoundation') {
      if (-not (Test-Admin)) { throw 'Media Foundation links need PowerShell running as administrator.' }
      $problem = Get-MediaFoundationProblem
      if ($problem) { throw $problem }
    }
    foreach ($device in Select-Devices $Add @(Get-CaptureDevices)) {
      foreach ($replaced in Set-DeviceLink $device $Scope $Type) { "Removed: $($replaced.Name) ($(Get-LinkLabel $replaced))" }
      if ($Type -eq 'MediaFoundation') { "Linked: $($device.Name)$Suffix (Windows Virtual Camera)" } else { "Linked: $($device.Name)$Suffix" }
    }
    'Restart your apps to see the changes. Fully quit NVIDIA Broadcast from the system tray.'
  }
  'Remove' {
    Assert-CanWrite $Scope
    $typeGiven = $PSBoundParameters.ContainsKey('Type')
    $links = @(Get-Links $Scope | Where-Object { -not $typeGiven -or $_.Type -eq $Type })
    $devices = @(Get-CaptureDevices)
    $targets = foreach ($selector in $Remove) {
      $number = 0
      $hits = if ($selector -eq 'all') { $links }
              elseif ([int]::TryParse($selector, [ref]$number)) { $links | Where-Object DeviceId -in @($devices | Where-Object Index -eq $number).Id }
              else { $links | Where-Object { $_.Name -like "*$selector*" } }
      if (-not $hits -and $selector -ne 'all') { throw "No link matches '$selector'. Run with -List to see links." }
      $hits
    }
    $targets = @($targets | Sort-Object Id -Unique)
    foreach ($link in $targets) {
      Remove-Link $link
      "Removed: $($link.Name) ($(Get-LinkLabel $link))"
    }
    if (-not $targets) { 'No links to remove.' }
  }
  default { Show-List }
}
