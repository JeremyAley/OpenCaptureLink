# OpenCaptureLink

Make capture cards and other video devices show up in apps that hide them, such as
**NVIDIA Broadcast**, without a virtual camera in between.

OpenCaptureLink gives a device a second entry, like `Live Gamer DUO - 2 (Direct)`. Apps
that open that entry open the real device directly: no OBS, no extra copy of the video, no
added latency, and nothing left running in the background.

## The problem

Windows has two camera systems, DirectShow (older) and Media Foundation (newer). Some
capture card drivers only work properly through DirectShow. Apps like Discord and OBS use
DirectShow and see the card fine.

NVIDIA Broadcast checks Media Foundation first. If a device is in the Media Foundation list
but fails to open, Broadcast marks it unsupported. It also skips the device's DirectShow
entry, because the name matches the one it already rejected. The card disappears from
Broadcast completely. The usual workaround is an OBS virtual camera, which adds a whole app
to the chain.

OpenCaptureLink adds a DirectShow entry with a different name that points at the same
device, so Broadcast's DirectShow path picks it up.

For apps that only use Media Foundation, such as the Windows Camera app, it can instead add
a Windows 11 virtual camera that feeds frames from the same device. That costs one copy of
each frame, so use it only when the DirectShow link doesn't work in your app.

## Install and use

Download the latest release and unzip it anywhere.

### Window

Double-click **`OpenCaptureLink.cmd`** and accept the administrator prompt. Pick a link for
each device you want and click **Apply**:

- **DirectShow (Recommended):** opens the real device directly, with no extra delay. Use this
  unless the app you want still can't see the device.
- **Media Foundation:** a virtual camera, for apps that only use Media Foundation (see
  below). Apps list it as `<device> (Direct) (Windows Virtual Camera)`.
- **Off:** no link.

Each device has one link at a time, so you can give one capture card a DirectShow link and
another a Media Foundation link, for example to use them in different apps.

Then restart the app that should see them. For NVIDIA Broadcast, fully quit it from the
system tray; closing the window only hides it. Pick the `(Direct)` device as your camera.

### Command line

From an administrator PowerShell, in the unzipped folder:

```powershell
.\OpenCaptureLink.ps1 -List                  # devices and their links
.\OpenCaptureLink.ps1 -Add 2,3               # link devices by number from -List
.\OpenCaptureLink.ps1 -Add "Live Gamer"      # or by part of the name
.\OpenCaptureLink.ps1 -Remove all            # remove links (number, name or all)
.\OpenCaptureLink.ps1 -Add 2 -Type MediaFoundation   # Media Foundation link instead
```

Adding one type of link replaces the device's other type. `-Remove` removes both types
unless you add `-Type`.

Add `-Scope CurrentUser` to work without administrator rights. Links are then only for your
account, and some apps, including NVIDIA Broadcast, don't see them.

If PowerShell refuses to run the script, start it with
`powershell -ExecutionPolicy Bypass -File .\OpenCaptureLink.ps1 ...`, or right-click the
downloaded zip, choose **Properties**, and tick **Unblock** before unzipping.

## How it works

### DirectShow links

A DirectShow link is a few registry values, and nothing else is installed:

- An entry under the DirectShow *Video Capture Sources* category
  (`HKLM\Software\Classes\CLSID\{860BB310-5D01-11D0-BD3B-00A0C911CE86}\Instance`), written
  for both 64-bit and 32-bit apps.
- Its class is Windows' own capture proxy (`ksproxy.ax`), and its `DevicePath` is the real
  device's. When an app opens the link, Windows builds exactly the same object it would for
  the original device.
- The entry ID is derived from the device path, so it stays the same across re-runs, and
  apps that remember your selected camera keep it.
- Each entry is tagged `CreatedBy = OpenCaptureLink`. Removing links only touches entries
  with that tag.

### Media Foundation links

Some drivers describe their formats in a way Media Foundation rejects (the Live Gamer DUO
fails with `MF_E_INVALIDMEDIATYPE`), so Media Foundation apps can't open the device even
though DirectShow can. A Media Foundation link works around that:

- `OpenCaptureLinkCamera.dll` is copied to `C:\Program Files\OpenCaptureLink`. It is a
  Media Foundation media source that opens the device through DirectShow and `ksproxy.ax`,
  then hands each frame to Media Foundation. That one frame copy is the overhead. On the
  Live Gamer DUO it runs at the full 1080p60 with no dropped frames.
- Each link is a Windows 11 virtual camera (`MFCreateVirtualCamera`), registered for all
  users, plus a COM class (`HKLM\Software\Classes\CLSID\{id}`) whose `DevicePath` tells the
  DLL which device to open. `HKLM\Software\OpenCaptureLink\Cameras` lists the links.
- Windows' camera service (Frame Server) loads the DLL when an app opens the camera, and
  shares the frames with every app using it. DirectShow apps see the virtual camera too.
- The DLL logs to `C:\ProgramData\OpenCaptureLink\camera.log`, which is useful to attach to
  bug reports.

Media Foundation links need Windows 11 and administrator rights, and are always for all
users.

They work with any device that works in DirectShow apps, with these limits:

- Only uncompressed **NV12 and YUY2** formats are offered. Many USB capture sticks and
  webcams offer their higher resolutions only as MJPEG; those modes don't appear yet.
- Older analog or TV capture cards that need an input chosen (composite, S-Video) aren't
  supported. HDMI capture cards and webcams don't need that.
- Most devices don't need a Media Foundation link at all: if a device already opens in
  Media Foundation apps, a DirectShow link (or no link) is enough.

## Compatibility

- **Works with** apps that list DirectShow cameras. NVIDIA Broadcast is tested; most
  streaming, recording and calling apps (OBS, Discord and others) also list DirectShow
  cameras, so they should see links too.
- **Media Foundation-only apps**, such as the Windows Camera app, never look at DirectShow
  entries. Use a Media Foundation link for those (Windows 11 only).
- **Devices:** any video capture device with a standard Windows driver, such as capture
  cards, USB capture sticks and webcams. Audio inputs aren't covered.

Tested on Windows 11 with:

| Device | App | Result |
| --- | --- | --- |
| AVerMedia Live Gamer DUO (GC570D), both inputs | NVIDIA Broadcast (DirectShow link) | Works |
| AVerMedia Live Gamer DUO (GC570D), input with a signal | Media Foundation test reader (Media Foundation link) | 1080p60, no dropped frames, also with the other input streaming |

Tried it with other hardware? Open an issue or pull request to add it to the table.

## Uninstall

Run `.\OpenCaptureLink.ps1 -Remove all` from an administrator PowerShell, or set every
device to **Off** in the window and click **Apply**. Then delete the folder.

Removing the last Media Foundation link also deletes `C:\Program Files\OpenCaptureLink`. If
an app still has the DLL loaded, Windows deletes it at the next restart. The log folder,
`C:\ProgramData\OpenCaptureLink`, stays; delete it if you like.

## Building the camera DLL

The release zip includes `OpenCaptureLinkCamera.dll`. To build it from source, install the
Visual Studio C++ build tools and a Windows 10 or 11 SDK, then run `src\camera\build.cmd`.
It writes the DLL next to the script, and a test program to `src\camera\out`:

```powershell
src\camera\out\CameraTest.exe --mf "(Direct)" 600   # read 600 frames from a Media Foundation link
```

## License

[MIT](LICENSE)
