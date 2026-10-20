// Reads frames with a Source Reader, either from a device opened through
// OpenCaptureLinkCamera.dll in this process (no Frame Server), or from a Media Foundation
// camera picked by name (for a registered virtual camera, through Frame Server).
//   CameraTest <dll> <DirectShow DevicePath> [frames]
//   CameraTest --mf <part of camera name> [frames]
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <cstdio>

typedef HRESULT(STDAPICALLTYPE *CreateSourceFn)(LPCWSTR, IMFMediaSource **);

int wmain(int argc, wchar_t **argv) {
  if (argc < 3) { wprintf(L"usage: CameraTest <dll> <devicePath> [frames] | CameraTest --mf <name> [frames]\n"); return 2; }
  int frames = argc > 3 ? _wtoi(argv[3]) : 120;
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  MFStartup(MF_VERSION);
  IMFMediaSource *source = nullptr;
  HRESULT hr = E_FAIL;
  DWORD openStart = GetTickCount();
  if (wcscmp(argv[1], L"--mf") == 0) {
    IMFAttributes *attributes = nullptr;
    MFCreateAttributes(&attributes, 1);
    attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate **devices = nullptr;
    UINT32 count = 0;
    MFEnumDeviceSources(attributes, &devices, &count);
    for (UINT32 i = 0; i < count && !source; i++) {
      wchar_t *name = nullptr;
      UINT32 length = 0;
      devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length);
      if (name && wcsstr(name, argv[2])) {
        hr = devices[i]->ActivateObject(IID_PPV_ARGS(&source));
        wprintf(L"Activate \"%s\" 0x%08X\n", name, hr);
      }
      CoTaskMemFree(name);
    }
    if (!source) { wprintf(L"no camera matches\n"); return 1; }
  } else {
    HMODULE dll = LoadLibraryW(argv[1]);
    if (!dll) { wprintf(L"LoadLibrary failed %lu\n", GetLastError()); return 1; }
    auto create = (CreateSourceFn)GetProcAddress(dll, "OpenCaptureLinkCreateSource");
    hr = create(argv[2], &source);
    wprintf(L"CreateSource 0x%08X\n", hr);
    if (FAILED(hr)) return 1;
  }
  wprintf(L"opened in %lu ms\n", GetTickCount() - openStart);

  IMFSourceReader *reader = nullptr;
  hr = MFCreateSourceReaderFromMediaSource(source, nullptr, &reader);
  wprintf(L"CreateSourceReader 0x%08X\n", hr);
  if (FAILED(hr)) return 1;
  for (DWORD i = 0;; i++) {
    IMFMediaType *type = nullptr;
    if (FAILED(reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &type))) break;
    GUID sub; UINT32 w, h, n, d;
    type->GetGUID(MF_MT_SUBTYPE, &sub);
    MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &w, &h);
    MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &n, &d);
    wprintf(L"  type %lu: %.4S %ux%u @ %u/%u\n", i, (char *)&sub.Data1, w, h, n, d);
    type->Release();
  }

  LONGLONG first = 0, last = 0, lastArrival = 0, worstGap = 0;
  int got = 0;
  DWORD start = GetTickCount();
  for (int i = 0; i < frames; i++) {
    DWORD index, flags; LONGLONG ts; IMFSample *sample = nullptr;
    hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &index, &flags, &ts, &sample);
    if (FAILED(hr)) { wprintf(L"ReadSample 0x%08X\n", hr); break; }
    if (sample) {
      DWORD length = 0; sample->GetTotalLength(&length);
      if (!got) { first = ts; wprintf(L"first frame: %lu bytes after %lu ms\n", length, GetTickCount() - start); }
      LONGLONG now = MFGetSystemTime();
      if (got && now - lastArrival > worstGap) worstGap = now - lastArrival;
      lastArrival = now;
      last = ts; got++;
      sample->Release();
    }
  }
  if (got > 1) wprintf(L"%d frames, %.2f fps, longest gap between frames %.1f ms\n", got,
                      (got - 1) * 1e7 / (double)(last - first), worstGap / 1e4);
  reader->Release();
  source->Shutdown();
  source->Release();
  MFShutdown();
  return got ? 0 : 1;
}
