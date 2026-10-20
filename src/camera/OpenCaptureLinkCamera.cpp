// OpenCaptureLink virtual camera.
//
// A Media Foundation media source that Windows' camera service (Frame Server) loads for a
// "(Direct)" virtual camera. It opens the real device through DirectShow and the stock
// capture proxy (ksproxy.ax), which works for drivers that Media Foundation cannot open
// itself, and hands each frame to Media Foundation.
//
// Each virtual camera has its own COM class ID. Its registry key
// (HKLM\Software\Classes\CLSID\{id}) carries the device's DirectShow DevicePath, so one DLL
// serves every linked device.

#include <windows.h>
#include <wrl.h>
#include <dshow.h>
#include <ks.h>
#include <ksmedia.h>
#include <ksproxy.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ChainInterfaces;
using Microsoft::WRL::Make;

// Media Foundation device attributes (declared here so the code builds with older SDKs).
static const GUID kStreamCategory    = { 0x2939e7b8, 0xa62e, 0x4579, { 0xb6, 0x74, 0xd4, 0x07, 0x3d, 0xfa, 0xbb, 0xba } };
static const GUID kStreamId          = { 0x11bd5120, 0xd124, 0x446b, { 0x88, 0xe6, 0x17, 0x06, 0x02, 0x57, 0xff, 0xf9 } };
static const GUID kFrameServerShared = { 0x1cb378e9, 0xb279, 0x41d4, { 0xaf, 0x97, 0x34, 0xa2, 0x43, 0xe6, 0x83, 0x20 } };
static const GUID kFrameSourceTypes  = { 0x17145fd1, 0x1b2b, 0x423c, { 0x80, 0x01, 0x2b, 0x68, 0x33, 0xed, 0x35, 0x88 } };
static const GUID kPinVideoCapture   = { 0xfb6c4281, 0x0353, 0x11d1, { 0x90, 0x5f, 0x00, 0x00, 0xc0, 0xcc, 0x16, 0xba } };
static const UINT32 kFrameSourceColor = 0x0001;  // MFFrameSourceTypes_Color

// DirectShow Sample Grabber and Null Renderer (qedit.dll; qedit.h is no longer in the SDK).
static const CLSID kSampleGrabber = { 0xc1f400a0, 0x3f08, 0x11d3, { 0x9f, 0x0b, 0x00, 0x60, 0x08, 0x03, 0x9e, 0x37 } };
static const CLSID kNullRenderer  = { 0xc1f400a4, 0x3f08, 0x11d3, { 0x9f, 0x0b, 0x00, 0x60, 0x08, 0x03, 0x9e, 0x37 } };
MIDL_INTERFACE("0579154A-2B53-4994-B0D0-E773148EFF85")
ISampleGrabberCB : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE SampleCB(double time, IMediaSample *sample) = 0;
  virtual HRESULT STDMETHODCALLTYPE BufferCB(double time, BYTE *buffer, long length) = 0;
};
MIDL_INTERFACE("6B652FFF-11FE-4fce-92AD-0266B5D7C78F")
ISampleGrabber : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE SetOneShot(BOOL oneShot) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetMediaType(const AM_MEDIA_TYPE *type) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetConnectedMediaType(AM_MEDIA_TYPE *type) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetBufferSamples(BOOL buffer) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetCurrentBuffer(long *size, long *buffer) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetCurrentSample(IMediaSample **sample) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetCallback(ISampleGrabberCB *callback, long method) = 0;
};

#define RETURN_IF_FAILED(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { Log(L"%S failed: 0x%08X", #expr, hr_); return hr_; } } while (0)

// ---------------------------------------------------------------------------------------
// Logging: %ProgramData%\OpenCaptureLink\camera.log. Any user can read it, so a log written
// inside Frame Server (which runs as LOCAL SERVICE) can be attached to a bug report.

static std::mutex g_logLock;

static void Log(const wchar_t *format, ...) {
  wchar_t line[1024];
  SYSTEMTIME now; GetLocalTime(&now);
  int prefix = swprintf_s(line, L"%02d:%02d:%02d.%03d [%lu:%lu] ", now.wHour, now.wMinute, now.wSecond, now.wMilliseconds, GetCurrentProcessId(), GetCurrentThreadId());
  va_list args; va_start(args, format);
  _vsnwprintf_s(line + prefix, _countof(line) - prefix, _TRUNCATE, format, args);
  va_end(args);

  wchar_t path[MAX_PATH];
  if (!ExpandEnvironmentStringsW(L"%ProgramData%\\OpenCaptureLink", path, MAX_PATH)) return;
  CreateDirectoryW(path, nullptr);
  if (wcscat_s(path, L"\\camera.log")) return;
  std::lock_guard<std::mutex> lock(g_logLock);
  HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER size;
  if (GetFileSizeEx(file, &size) && size.QuadPart > 1024 * 1024) {  // keep it small
    CloseHandle(file);
    file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
  }
  char utf8[3072];
  int length = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8, sizeof(utf8) - 2, nullptr, nullptr);
  if (length > 0) {
    utf8[length - 1] = '\r'; utf8[length] = '\n';
    DWORD written; WriteFile(file, utf8, length + 1, &written, nullptr);
  }
  CloseHandle(file);
}

// ---------------------------------------------------------------------------------------
// DirectShow side: the real device, a Sample Grabber and a Null Renderer.

static std::wstring GuidText(REFGUID guid) {
  wchar_t text[64];
  return StringFromGUID2(guid, text, _countof(text)) ? text : L"?";
}

static void FreeMediaType(AM_MEDIA_TYPE &type) {
  if (type.cbFormat) CoTaskMemFree(type.pbFormat);
  if (type.pUnk) type.pUnk->Release();
  type.cbFormat = 0; type.pbFormat = nullptr; type.pUnk = nullptr;
}

static void DeleteMediaType(AM_MEDIA_TYPE *type) {
  if (type) { FreeMediaType(*type); CoTaskMemFree(type); }
}

// A format the device offers, with the matching Media Foundation type.
struct Format {
  AM_MEDIA_TYPE am{};
  ComPtr<IMFMediaType> mf;
  GUID subtype{};
  UINT32 width = 0, height = 0, rateNum = 0, rateDen = 0;
};

// Devices being opened in this process right now. DirectShow lists Frame Server cameras,
// including our own virtual cameras, and reading one of those from inside Frame Server
// activates another of our sources on another thread, which opens a device again, without
// end. Opening by path avoids that; this cap stops it if anything else triggers it, while
// still allowing a few genuinely concurrent opens.
static std::atomic<int> g_opening{0};
static const int kMaxConcurrentOpens = 4;

struct OpeningScope {
  OpeningScope() { g_opening++; }
  ~OpeningScope() { g_opening--; }
};

static HRESULT FindDeviceFilter(const std::wstring &devicePath, IBaseFilter **filter) {
  OpeningScope opening;
  // Bind the device's moniker directly from its path, without listing devices.
  ComPtr<IBindCtx> context;
  ComPtr<IMoniker> direct;
  ULONG eaten = 0;
  std::wstring name = L"@device:pnp:" + devicePath;
  HRESULT hr = CreateBindCtx(0, &context);
  if (SUCCEEDED(hr)) hr = MkParseDisplayName(context.Get(), name.c_str(), &eaten, &direct);
  if (SUCCEEDED(hr)) hr = direct->BindToObject(nullptr, nullptr, IID_PPV_ARGS(filter));
  if (SUCCEEDED(hr)) return S_OK;
  Log(L"Direct bind failed (0x%08X), listing devices", hr);

  // Match monikers by display name: reading their property bags would activate virtual cameras.

  ComPtr<ICreateDevEnum> devEnum;
  RETURN_IF_FAILED(CoCreateInstance(CLSID_SystemDeviceEnum, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&devEnum)));
  ComPtr<IEnumMoniker> monikers;
  // Hardware devices only, so our own DirectShow links never match.
  if (devEnum->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, &monikers, CDEF_DEVMON_PNP_DEVICE) != S_OK) {
    Log(L"No DirectShow video devices");
    return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
  }
  ComPtr<IMoniker> moniker;
  while (monikers->Next(1, &moniker, nullptr) == S_OK) {
    LPOLESTR display = nullptr;
    bool match = SUCCEEDED(moniker->GetDisplayName(context.Get(), nullptr, &display)) && display &&
                 _wcsicmp(display, name.c_str()) == 0;
    CoTaskMemFree(display);
    if (match) return moniker->BindToObject(nullptr, nullptr, IID_PPV_ARGS(filter));
    moniker.Reset();
  }
  Log(L"Device not found: %s", devicePath.c_str());
  return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
}

// The first output pin that offers video (the capture pin; some cards also have an audio pin).
static HRESULT FindVideoPin(IBaseFilter *filter, IPin **result) {
  ComPtr<IEnumPins> pins;
  RETURN_IF_FAILED(filter->EnumPins(&pins));
  ComPtr<IPin> pin;
  while (pins->Next(1, &pin, nullptr) == S_OK) {
    PIN_DIRECTION direction;
    ComPtr<IAMStreamConfig> config;
    int count = 0, size = 0;
    if (SUCCEEDED(pin->QueryDirection(&direction)) && direction == PINDIR_OUTPUT &&
        SUCCEEDED(pin.As(&config)) && SUCCEEDED(config->GetNumberOfCapabilities(&count, &size))) {
      for (int i = 0; i < count; i++) {
        AM_MEDIA_TYPE *type = nullptr;
        std::vector<BYTE> caps(size);
        if (SUCCEEDED(config->GetStreamCaps(i, &type, caps.data()))) {
          bool video = type->majortype == MEDIATYPE_Video;
          DeleteMediaType(type);
          if (video) { *result = pin.Detach(); return S_OK; }
        }
      }
    }
    pin.Reset();
  }
  Log(L"No video output pin");
  return VFW_E_NOT_FOUND;
}

// Formats Media Foundation apps can use without conversion: NV12 and YUY2, NV12 first.
static HRESULT ListFormats(IPin *pin, std::vector<Format> &formats) {
  ComPtr<IAMStreamConfig> config;
  RETURN_IF_FAILED(pin->QueryInterface(IID_PPV_ARGS(&config)));
  int count = 0, size = 0;
  RETURN_IF_FAILED(config->GetNumberOfCapabilities(&count, &size));
  for (const GUID &wanted : { MEDIASUBTYPE_NV12, MEDIASUBTYPE_YUY2 }) {
    for (int i = 0; i < count; i++) {
      AM_MEDIA_TYPE *type = nullptr;
      std::vector<BYTE> caps(size);
      if (FAILED(config->GetStreamCaps(i, &type, caps.data()))) continue;
      if (type->majortype != MEDIATYPE_Video || type->subtype != wanted ||
          (type->formattype != FORMAT_VideoInfo && type->formattype != FORMAT_VideoInfo2) || !type->pbFormat) {
        DeleteMediaType(type); continue;
      }
      Format format;
      if (FAILED(MFCreateMediaType(&format.mf)) || FAILED(MFInitMediaTypeFromAMMediaType(format.mf.Get(), type))) {
        DeleteMediaType(type); continue;
      }
      format.subtype = wanted;
      MFGetAttributeSize(format.mf.Get(), MF_MT_FRAME_SIZE, &format.width, &format.height);
      MFGetAttributeRatio(format.mf.Get(), MF_MT_FRAME_RATE, &format.rateNum, &format.rateDen);
      format.mf->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      format.mf->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
      bool duplicate = false;
      for (const Format &other : formats)
        duplicate |= other.subtype == format.subtype && other.width == format.width && other.height == format.height &&
                     (UINT64)other.rateNum * format.rateDen == (UINT64)format.rateNum * other.rateDen;
      if (duplicate || !format.width || !format.height) { DeleteMediaType(type); continue; }
      format.am = *type;  // takes ownership of the format block
      CoTaskMemFree(type);
      formats.push_back(std::move(format));
    }
  }
  return formats.empty() ? MF_E_INVALIDMEDIATYPE : S_OK;
}

class FrameSink {
public:
  virtual void OnFrame(const BYTE *data, DWORD length) = 0;
};

// Runs the DirectShow graph and passes every frame to a sink.
class Capture : public RuntimeClass<RuntimeClassFlags<ClassicCom>, ISampleGrabberCB> {
public:
  HRESULT Start(const std::wstring &devicePath, const AM_MEDIA_TYPE &type, FrameSink *sink) {
    m_sink = sink;
    ComPtr<IBaseFilter> device, grabberFilter, renderer;
    ComPtr<IPin> devicePin;
    RETURN_IF_FAILED(CoCreateInstance(CLSID_FilterGraph, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&m_graph)));
    RETURN_IF_FAILED(FindDeviceFilter(devicePath, &device));
    RETURN_IF_FAILED(m_graph->AddFilter(device.Get(), L"Device"));
    RETURN_IF_FAILED(FindVideoPin(device.Get(), &devicePin));
    ComPtr<IAMStreamConfig> config;
    RETURN_IF_FAILED(devicePin.As(&config));
    RETURN_IF_FAILED(config->SetFormat(const_cast<AM_MEDIA_TYPE *>(&type)));

    RETURN_IF_FAILED(CoCreateInstance(kSampleGrabber, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&grabberFilter)));
    RETURN_IF_FAILED(m_graph->AddFilter(grabberFilter.Get(), L"Grabber"));
    ComPtr<ISampleGrabber> grabber;
    RETURN_IF_FAILED(grabberFilter.As(&grabber));
    RETURN_IF_FAILED(grabber->SetMediaType(&type));
    RETURN_IF_FAILED(grabber->SetBufferSamples(FALSE));
    RETURN_IF_FAILED(grabber->SetOneShot(FALSE));
    RETURN_IF_FAILED(grabber->SetCallback(this, 1 /* BufferCB */));
    RETURN_IF_FAILED(CoCreateInstance(kNullRenderer, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&renderer)));
    RETURN_IF_FAILED(m_graph->AddFilter(renderer.Get(), L"Renderer"));

    ComPtr<IPin> grabberIn, grabberOut, rendererIn;
    RETURN_IF_FAILED(FirstPin(grabberFilter.Get(), PINDIR_INPUT, &grabberIn));
    RETURN_IF_FAILED(FirstPin(grabberFilter.Get(), PINDIR_OUTPUT, &grabberOut));
    RETURN_IF_FAILED(FirstPin(renderer.Get(), PINDIR_INPUT, &rendererIn));
    RETURN_IF_FAILED(m_graph->ConnectDirect(devicePin.Get(), grabberIn.Get(), &type));
    RETURN_IF_FAILED(m_graph->ConnectDirect(grabberOut.Get(), rendererIn.Get(), nullptr));

    // No reference clock: deliver frames as soon as the device produces them.
    ComPtr<IMediaFilter> mediaFilter;
    RETURN_IF_FAILED(m_graph.As(&mediaFilter));
    RETURN_IF_FAILED(mediaFilter->SetSyncSource(nullptr));
    RETURN_IF_FAILED(m_graph.As(&m_control));
    HRESULT hr = m_control->Run();
    if (FAILED(hr)) { Log(L"Graph Run failed: 0x%08X", hr); Stop(); return hr; }
    Log(L"Capture running");
    return S_OK;
  }

  void Stop() {
    if (m_control) m_control->Stop();
    m_control.Reset();
    m_graph.Reset();
    std::lock_guard<std::mutex> lock(m_lock);
    m_sink = nullptr;
  }

  IFACEMETHODIMP SampleCB(double, IMediaSample *) override { return E_NOTIMPL; }
  IFACEMETHODIMP BufferCB(double, BYTE *buffer, long length) override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_sink && buffer && length > 0) m_sink->OnFrame(buffer, (DWORD)length);
    return S_OK;
  }

private:
  static HRESULT FirstPin(IBaseFilter *filter, PIN_DIRECTION wanted, IPin **result) {
    ComPtr<IEnumPins> pins;
    RETURN_IF_FAILED(filter->EnumPins(&pins));
    ComPtr<IPin> pin;
    while (pins->Next(1, &pin, nullptr) == S_OK) {
      PIN_DIRECTION direction;
      if (SUCCEEDED(pin->QueryDirection(&direction)) && direction == wanted) { *result = pin.Detach(); return S_OK; }
      pin.Reset();
    }
    return VFW_E_NOT_FOUND;
  }

  ComPtr<IGraphBuilder> m_graph;
  ComPtr<IMediaControl> m_control;
  std::mutex m_lock;
  FrameSink *m_sink = nullptr;
};

// ---------------------------------------------------------------------------------------
// Media Foundation side.

static HRESULT KsNotFound() { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }

class MediaSource;

class MediaStream : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                        ChainInterfaces<IMFMediaStream2, IMFMediaStream, IMFMediaEventGenerator>>,
                    public FrameSink {
public:
  HRESULT Initialize(IMFMediaSource *source, const std::wstring &devicePath, std::vector<Format> &&formats) {
    m_source = source;
    m_devicePath = devicePath;
    m_formats = std::move(formats);
    RETURN_IF_FAILED(MFCreateEventQueue(&m_queue));
    RETURN_IF_FAILED(MFCreateAttributes(&m_attributes, 4));
    RETURN_IF_FAILED(m_attributes->SetGUID(kStreamCategory, kPinVideoCapture));
    RETURN_IF_FAILED(m_attributes->SetUINT32(kStreamId, 0));
    RETURN_IF_FAILED(m_attributes->SetUINT32(kFrameServerShared, 1));
    RETURN_IF_FAILED(m_attributes->SetUINT32(kFrameSourceTypes, kFrameSourceColor));

    std::vector<IMFMediaType *> types;
    for (Format &format : m_formats) types.push_back(format.mf.Get());
    RETURN_IF_FAILED(MFCreateStreamDescriptor(0, (DWORD)types.size(), types.data(), &m_descriptor));
    ComPtr<IMFMediaTypeHandler> handler;
    RETURN_IF_FAILED(m_descriptor->GetMediaTypeHandler(&handler));
    RETURN_IF_FAILED(handler->SetCurrentMediaType(types[0]));
    RETURN_IF_FAILED(m_attributes->CopyAllItems(m_descriptor.Get()));
    return S_OK;
  }

  ~MediaStream() {
    for (Format &format : m_formats) FreeMediaType(format.am);
  }

  IMFStreamDescriptor *Descriptor() { return m_descriptor.Get(); }
  IMFAttributes *Attributes() { return m_attributes.Get(); }

  HRESULT Start() {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    RETURN_IF_FAILED(StartCaptureLocked());
    m_state = MF_STREAM_STATE_RUNNING;
    return m_queue->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, nullptr);
  }

  HRESULT Stop() {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    StopCaptureLocked();
    m_state = MF_STREAM_STATE_STOPPED;
    return m_queue->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr);
  }

  void Shutdown() {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return;
    m_shutdown = true;
    StopCaptureLocked();
    if (m_queue) m_queue->Shutdown();
    m_source.Reset();
  }

  // FrameSink: called on the DirectShow streaming thread for every frame.
  void OnFrame(const BYTE *data, DWORD length) override {
    ComPtr<IUnknown> token;
    {
      std::lock_guard<std::mutex> lock(m_lock);
      if (m_shutdown || m_state != MF_STREAM_STATE_RUNNING || m_requests.empty()) { m_dropped++; return; }
      token = m_requests.front();
      m_requests.pop_front();
    }
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = m_allocator->AllocateSample(&sample);
    if (SUCCEEDED(hr)) hr = sample->GetBufferByIndex(0, &buffer);
    if (SUCCEEDED(hr)) hr = CopyFrame(data, length, buffer.Get());
    if (FAILED(hr)) {
      if (m_copyFailures++ == 0) Log(L"Could not fill a sample: 0x%08X", hr);
      std::lock_guard<std::mutex> lock(m_lock);
      m_requests.push_front(token);  // try again with the next frame
      return;
    }
    sample->SetSampleTime(MFGetSystemTime());
    sample->SetSampleDuration(m_frameDuration);
    if (token) sample->SetUnknown(MFSampleExtension_Token, token.Get());

    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return;
    m_queue->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample.Get());
    if (++m_delivered == 1) Log(L"First frame delivered (%lu bytes)", length);
  }

  // IMFMediaEventGenerator
  IFACEMETHODIMP GetEvent(DWORD flags, IMFMediaEvent **event) override {
    ComPtr<IMFMediaEventQueue> queue;
    { std::lock_guard<std::mutex> lock(m_lock); if (m_shutdown) return MF_E_SHUTDOWN; queue = m_queue; }
    return queue->GetEvent(flags, event);
  }
  IFACEMETHODIMP BeginGetEvent(IMFAsyncCallback *callback, IUnknown *state) override {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown ? MF_E_SHUTDOWN : m_queue->BeginGetEvent(callback, state);
  }
  IFACEMETHODIMP EndGetEvent(IMFAsyncResult *result, IMFMediaEvent **event) override {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown ? MF_E_SHUTDOWN : m_queue->EndGetEvent(result, event);
  }
  IFACEMETHODIMP QueueEvent(MediaEventType type, REFGUID extended, HRESULT status, const PROPVARIANT *value) override {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown ? MF_E_SHUTDOWN : m_queue->QueueEventParamVar(type, extended, status, value);
  }

  // IMFMediaStream
  IFACEMETHODIMP GetMediaSource(IMFMediaSource **source) override {
    if (!source) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    return m_source.CopyTo(source);
  }
  IFACEMETHODIMP GetStreamDescriptor(IMFStreamDescriptor **descriptor) override {
    if (!descriptor) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    return m_descriptor.CopyTo(descriptor);
  }
  IFACEMETHODIMP RequestSample(IUnknown *token) override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    if (m_state != MF_STREAM_STATE_RUNNING) return MF_E_MEDIA_SOURCE_WRONGSTATE;
    if (m_requests.size() > 30) return MF_E_SAMPLEALLOCATOR_EMPTY;  // caller is far ahead of the device
    m_requests.push_back(token);
    return S_OK;
  }

  // IMFMediaStream2
  IFACEMETHODIMP SetStreamState(MF_STREAM_STATE state) override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    if (state == m_state) return S_OK;
    switch (state) {
    case MF_STREAM_STATE_RUNNING: RETURN_IF_FAILED(StartCaptureLocked()); break;
    case MF_STREAM_STATE_STOPPED: StopCaptureLocked(); break;
    case MF_STREAM_STATE_PAUSED: break;
    default: return MF_E_INVALID_STATE_TRANSITION;
    }
    m_state = state;
    return S_OK;
  }
  IFACEMETHODIMP GetStreamState(MF_STREAM_STATE *state) override {
    if (!state) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    *state = m_state;
    return S_OK;
  }

  // Frame Server shares frames with apps in other processes, so samples must come from the
  // allocator it provides (see MediaSource::SetDefaultAllocator).
  HRESULT SetAllocator(IMFVideoSampleAllocator *allocator) {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    if (m_capture) return MF_E_INVALIDREQUEST;
    m_allocator = allocator;
    return S_OK;
  }

private:
  // Copies one DirectShow frame (tightly packed rows) into a sample buffer, row by row.
  HRESULT CopyFrame(const BYTE *data, DWORD length, IMFMediaBuffer *buffer) {
    const Format &format = *m_format;
    bool nv12 = format.subtype == MEDIASUBTYPE_NV12;
    DWORD rowBytes = nv12 ? format.width : format.width * 2;
    DWORD rows = nv12 ? format.height + format.height / 2 : format.height;
    DWORD sourceStride = length / rows;
    if (sourceStride < rowBytes) return MF_E_BUFFERTOOSMALL;

    ComPtr<IMF2DBuffer2> buffer2d;
    if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d)))) {
      BYTE *target = nullptr, *start = nullptr;
      LONG pitch = 0;
      DWORD capacity = 0;
      RETURN_IF_FAILED(buffer2d->Lock2DSize(MF2DBuffer_LockFlags_Write, &target, &pitch, &start, &capacity));
      for (DWORD row = 0; row < rows; row++) memcpy(target + (LONG_PTR)pitch * row, data + sourceStride * row, rowBytes);
      buffer2d->Unlock2D();
      DWORD contiguous = 0;
      RETURN_IF_FAILED(buffer2d->GetContiguousLength(&contiguous));
      return buffer->SetCurrentLength(contiguous);
    }
    BYTE *target = nullptr;
    DWORD capacity = 0;
    RETURN_IF_FAILED(buffer->Lock(&target, &capacity, nullptr));
    DWORD size = rowBytes * rows;
    if (capacity >= size)
      for (DWORD row = 0; row < rows; row++) memcpy(target + rowBytes * row, data + sourceStride * row, rowBytes);
    buffer->Unlock();
    if (capacity < size) return MF_E_BUFFERTOOSMALL;
    return buffer->SetCurrentLength(size);
  }

  HRESULT StartCaptureLocked() {
    ComPtr<IMFMediaTypeHandler> handler;
    ComPtr<IMFMediaType> current;
    RETURN_IF_FAILED(m_descriptor->GetMediaTypeHandler(&handler));
    RETURN_IF_FAILED(handler->GetCurrentMediaType(&current));
    // Match on what identifies a format; the caller's copy may carry extra attributes.
    GUID subtype{};
    UINT32 width = 0, height = 0, rateNum = 0, rateDen = 1;
    current->GetGUID(MF_MT_SUBTYPE, &subtype);
    MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width, &height);
    MFGetAttributeRatio(current.Get(), MF_MT_FRAME_RATE, &rateNum, &rateDen);
    const Format *chosen = nullptr;
    for (const Format &format : m_formats) {
      if (format.subtype == subtype && format.width == width && format.height == height &&
          (UINT64)format.rateNum * rateDen == (UINT64)rateNum * format.rateDen) {
        chosen = &format; break;
      }
    }
    if (!chosen) { Log(L"Current media type is not one of ours"); return MF_E_INVALIDMEDIATYPE; }
    if (m_capture) {
      if (chosen == m_format) return S_OK;
      StopCaptureLocked();  // the app picked another format: restart in it
      if (m_shutdown) return MF_E_SHUTDOWN;
      if (m_capture) return S_OK;  // another thread started one while we were stopping
    }
    if (!m_allocator) {  // running outside Frame Server
      ComPtr<IMFVideoSampleAllocatorEx> own;
      RETURN_IF_FAILED(MFCreateVideoSampleAllocatorEx(IID_PPV_ARGS(&own)));
      m_allocator = own;
    }
    RETURN_IF_FAILED(m_allocator->InitializeSampleAllocator(10, chosen->mf.Get()));
    m_format = chosen;
    m_frameDuration = chosen->rateNum ? (LONGLONG)10000000 * chosen->rateDen / chosen->rateNum : 0;
    Log(L"Starting %c%c%c%c %ux%u @ %u/%u", (char)chosen->subtype.Data1, (char)(chosen->subtype.Data1 >> 8),
        (char)(chosen->subtype.Data1 >> 16), (char)(chosen->subtype.Data1 >> 24), chosen->width, chosen->height,
        chosen->rateNum, chosen->rateDen);
    m_capture = Make<Capture>();
    if (!m_capture) return E_OUTOFMEMORY;
    HRESULT hr = m_capture->Start(m_devicePath, chosen->am, this);
    if (FAILED(hr)) { m_capture->Stop(); m_capture.Reset(); return hr; }
    m_delivered = m_dropped = 0;
    return S_OK;
  }

  void StopCaptureLocked() {
    // Take the capture first, so another thread stopping at the same time finds none.
    ComPtr<Capture> capture = std::move(m_capture);
    if (capture) {
      // The streaming thread takes m_lock in OnFrame; stop the graph without holding it.
      m_lock.unlock();
      capture->Stop();
      m_lock.lock();
      Log(L"Capture stopped (%llu delivered, %llu dropped)", m_delivered, m_dropped);
    }
    m_requests.clear();
  }

  std::mutex m_lock;
  bool m_shutdown = false;
  MF_STREAM_STATE m_state = MF_STREAM_STATE_STOPPED;
  ComPtr<IMFMediaSource> m_source;
  ComPtr<IMFMediaEventQueue> m_queue;
  ComPtr<IMFAttributes> m_attributes;
  ComPtr<IMFStreamDescriptor> m_descriptor;
  std::wstring m_devicePath;
  std::vector<Format> m_formats;
  ComPtr<Capture> m_capture;
  ComPtr<IMFVideoSampleAllocator> m_allocator;
  const Format *m_format = nullptr;
  unsigned long m_copyFailures = 0;
  std::deque<ComPtr<IUnknown>> m_requests;
  LONGLONG m_frameDuration = 0;
  unsigned long long m_delivered = 0, m_dropped = 0;
};

class MediaSource : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                        ChainInterfaces<IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator>,
                                        IMFGetService, IKsControl, IMFSampleAllocatorControl> {
public:
  bool IsShutdown() {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown;
  }

  HRESULT Initialize(const std::wstring &devicePath, IMFAttributes *activateAttributes) {
    if (g_opening >= kMaxConcurrentOpens) { Log(L"Refusing runaway nested activation"); return HRESULT_FROM_WIN32(ERROR_POSSIBLE_DEADLOCK); }
    Log(L"Opening %s", devicePath.c_str());
    RETURN_IF_FAILED(MFCreateEventQueue(&m_queue));
    RETURN_IF_FAILED(MFCreateAttributes(&m_attributes, 4));
    if (activateAttributes) activateAttributes->CopyAllItems(m_attributes.Get());

    std::vector<Format> formats;
    {
      ComPtr<IBaseFilter> device;
      ComPtr<IPin> pin;
      RETURN_IF_FAILED(FindDeviceFilter(devicePath, &device));
      RETURN_IF_FAILED(FindVideoPin(device.Get(), &pin));
      RETURN_IF_FAILED(ListFormats(pin.Get(), formats));
    }
    Log(L"%zu formats", formats.size());
    m_stream = Make<MediaStream>();
    if (!m_stream) return E_OUTOFMEMORY;
    RETURN_IF_FAILED(m_stream->Initialize(this, devicePath, std::move(formats)));
    IMFStreamDescriptor *descriptor = m_stream->Descriptor();
    RETURN_IF_FAILED(MFCreatePresentationDescriptor(1, &descriptor, &m_presentation));
    RETURN_IF_FAILED(m_presentation->SelectStream(0));
    return S_OK;
  }

  // IMFMediaEventGenerator
  IFACEMETHODIMP GetEvent(DWORD flags, IMFMediaEvent **event) override {
    ComPtr<IMFMediaEventQueue> queue;
    { std::lock_guard<std::mutex> lock(m_lock); if (m_shutdown) return MF_E_SHUTDOWN; queue = m_queue; }
    return queue->GetEvent(flags, event);
  }
  IFACEMETHODIMP BeginGetEvent(IMFAsyncCallback *callback, IUnknown *state) override {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown ? MF_E_SHUTDOWN : m_queue->BeginGetEvent(callback, state);
  }
  IFACEMETHODIMP EndGetEvent(IMFAsyncResult *result, IMFMediaEvent **event) override {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown ? MF_E_SHUTDOWN : m_queue->EndGetEvent(result, event);
  }
  IFACEMETHODIMP QueueEvent(MediaEventType type, REFGUID extended, HRESULT status, const PROPVARIANT *value) override {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_shutdown ? MF_E_SHUTDOWN : m_queue->QueueEventParamVar(type, extended, status, value);
  }

  // IMFMediaSource
  IFACEMETHODIMP GetCharacteristics(DWORD *characteristics) override {
    if (!characteristics) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    *characteristics = MFMEDIASOURCE_IS_LIVE;
    return S_OK;
  }
  IFACEMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor **descriptor) override {
    if (!descriptor) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    return m_presentation->Clone(descriptor);
  }
  IFACEMETHODIMP Start(IMFPresentationDescriptor *descriptor, const GUID *timeFormat, const PROPVARIANT *startPosition) override {
    if (!descriptor || !startPosition) return E_INVALIDARG;
    if (timeFormat && *timeFormat != GUID_NULL) return MF_E_UNSUPPORTED_TIME_FORMAT;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    BOOL selected = FALSE;
    ComPtr<IMFStreamDescriptor> stream;
    RETURN_IF_FAILED(descriptor->GetStreamDescriptorByIndex(0, &selected, &stream));
    Log(L"Start (stream selected: %d)", selected);
    if (selected) {
      ComPtr<IUnknown> streamUnknown;
      RETURN_IF_FAILED(m_stream.As(&streamUnknown));
      RETURN_IF_FAILED(m_queue->QueueEventParamUnk(m_streamActive ? MEUpdatedStream : MENewStream, GUID_NULL, S_OK, streamUnknown.Get()));
      m_streamActive = true;
      HRESULT hr = m_stream->Start();
      if (FAILED(hr)) { Log(L"Stream start failed: 0x%08X", hr); return hr; }
    }
    PROPVARIANT now; PropVariantInit(&now);
    now.vt = VT_I8; now.hVal.QuadPart = MFGetSystemTime();
    return m_queue->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &now);
  }
  IFACEMETHODIMP Stop() override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    Log(L"Stop");
    m_stream->Stop();
    return m_queue->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, nullptr);
  }
  IFACEMETHODIMP Pause() override { return MF_E_INVALID_STATE_TRANSITION; }
  IFACEMETHODIMP Shutdown() override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    Log(L"Shutdown");
    m_shutdown = true;
    if (m_stream) m_stream->Shutdown();
    if (m_queue) m_queue->Shutdown();
    m_stream.Reset();
    return S_OK;
  }

  // IMFMediaSourceEx
  IFACEMETHODIMP GetSourceAttributes(IMFAttributes **attributes) override {
    if (!attributes) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    return m_attributes.CopyTo(attributes);
  }
  IFACEMETHODIMP GetStreamAttributes(DWORD id, IMFAttributes **attributes) override {
    if (!attributes) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    if (id != 0) return MF_E_INVALIDSTREAMNUMBER;
    *attributes = m_stream->Attributes();
    (*attributes)->AddRef();
    return S_OK;
  }
  IFACEMETHODIMP SetD3DManager(IUnknown *) override { return S_OK; }  // frames are in system memory

  // IMFGetService
  IFACEMETHODIMP GetService(REFGUID, REFIID, LPVOID *) override { return MF_E_UNSUPPORTED_SERVICE; }

  // IMFSampleAllocatorControl
  IFACEMETHODIMP SetDefaultAllocator(DWORD id, IUnknown *allocator) override {
    if (!allocator) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    if (id != 0) return MF_E_INVALIDSTREAMNUMBER;
    ComPtr<IMFVideoSampleAllocator> videoAllocator;
    RETURN_IF_FAILED(allocator->QueryInterface(IID_PPV_ARGS(&videoAllocator)));
    return m_stream->SetAllocator(videoAllocator.Get());
  }
  IFACEMETHODIMP GetAllocatorUsage(DWORD id, DWORD *inputId, MFSampleAllocatorUsage *usage) override {
    if (!inputId || !usage) return E_POINTER;
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_shutdown) return MF_E_SHUTDOWN;
    if (id != 0) return MF_E_INVALIDSTREAMNUMBER;
    *inputId = id;
    *usage = MFSampleAllocatorUsage_UsesProvidedAllocator;
    return S_OK;
  }

  // IKsControl: no custom controls.
  IFACEMETHODIMP KsProperty(PKSPROPERTY, ULONG, LPVOID, ULONG, ULONG *) override { return KsNotFound(); }
  IFACEMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG *) override { return KsNotFound(); }
  IFACEMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG *) override { return KsNotFound(); }

private:
  std::mutex m_lock;
  bool m_shutdown = false;
  bool m_streamActive = false;
  ComPtr<IMFMediaEventQueue> m_queue;
  ComPtr<IMFAttributes> m_attributes;
  ComPtr<IMFPresentationDescriptor> m_presentation;
  ComPtr<MediaStream> m_stream;
};

// ---------------------------------------------------------------------------------------
// Activation object: what Frame Server creates from the camera's class ID.

#define DELEGATE_ATTRIBUTES(store) \
  IFACEMETHODIMP GetItem(REFGUID k, PROPVARIANT *v) override { return store->GetItem(k, v); } \
  IFACEMETHODIMP GetItemType(REFGUID k, MF_ATTRIBUTE_TYPE *t) override { return store->GetItemType(k, t); } \
  IFACEMETHODIMP CompareItem(REFGUID k, REFPROPVARIANT v, BOOL *r) override { return store->CompareItem(k, v, r); } \
  IFACEMETHODIMP Compare(IMFAttributes *o, MF_ATTRIBUTES_MATCH_TYPE m, BOOL *r) override { return store->Compare(o, m, r); } \
  IFACEMETHODIMP GetUINT32(REFGUID k, UINT32 *v) override { return store->GetUINT32(k, v); } \
  IFACEMETHODIMP GetUINT64(REFGUID k, UINT64 *v) override { return store->GetUINT64(k, v); } \
  IFACEMETHODIMP GetDouble(REFGUID k, double *v) override { return store->GetDouble(k, v); } \
  IFACEMETHODIMP GetGUID(REFGUID k, GUID *v) override { return store->GetGUID(k, v); } \
  IFACEMETHODIMP GetStringLength(REFGUID k, UINT32 *l) override { return store->GetStringLength(k, l); } \
  IFACEMETHODIMP GetString(REFGUID k, LPWSTR v, UINT32 s, UINT32 *l) override { return store->GetString(k, v, s, l); } \
  IFACEMETHODIMP GetAllocatedString(REFGUID k, LPWSTR *v, UINT32 *l) override { return store->GetAllocatedString(k, v, l); } \
  IFACEMETHODIMP GetBlobSize(REFGUID k, UINT32 *s) override { return store->GetBlobSize(k, s); } \
  IFACEMETHODIMP GetBlob(REFGUID k, UINT8 *b, UINT32 s, UINT32 *l) override { return store->GetBlob(k, b, s, l); } \
  IFACEMETHODIMP GetAllocatedBlob(REFGUID k, UINT8 **b, UINT32 *s) override { return store->GetAllocatedBlob(k, b, s); } \
  IFACEMETHODIMP GetUnknown(REFGUID k, REFIID i, LPVOID *v) override { return store->GetUnknown(k, i, v); } \
  IFACEMETHODIMP SetItem(REFGUID k, REFPROPVARIANT v) override { return store->SetItem(k, v); } \
  IFACEMETHODIMP DeleteItem(REFGUID k) override { return store->DeleteItem(k); } \
  IFACEMETHODIMP DeleteAllItems() override { return store->DeleteAllItems(); } \
  IFACEMETHODIMP SetUINT32(REFGUID k, UINT32 v) override { return store->SetUINT32(k, v); } \
  IFACEMETHODIMP SetUINT64(REFGUID k, UINT64 v) override { return store->SetUINT64(k, v); } \
  IFACEMETHODIMP SetDouble(REFGUID k, double v) override { return store->SetDouble(k, v); } \
  IFACEMETHODIMP SetGUID(REFGUID k, REFGUID v) override { return store->SetGUID(k, v); } \
  IFACEMETHODIMP SetString(REFGUID k, LPCWSTR v) override { return store->SetString(k, v); } \
  IFACEMETHODIMP SetBlob(REFGUID k, const UINT8 *b, UINT32 s) override { return store->SetBlob(k, b, s); } \
  IFACEMETHODIMP SetUnknown(REFGUID k, IUnknown *v) override { return store->SetUnknown(k, v); } \
  IFACEMETHODIMP LockStore() override { return store->LockStore(); } \
  IFACEMETHODIMP UnlockStore() override { return store->UnlockStore(); } \
  IFACEMETHODIMP GetCount(UINT32 *c) override { return store->GetCount(c); } \
  IFACEMETHODIMP GetItemByIndex(UINT32 i, GUID *k, PROPVARIANT *v) override { return store->GetItemByIndex(i, k, v); } \
  IFACEMETHODIMP CopyAllItems(IMFAttributes *d) override { return store->CopyAllItems(d); }

class Activate : public RuntimeClass<RuntimeClassFlags<ClassicCom>, ChainInterfaces<IMFActivate, IMFAttributes>> {
public:
  HRESULT Initialize(const std::wstring &devicePath) {
    m_devicePath = devicePath;
    return MFCreateAttributes(&m_store, 4);
  }

  DELEGATE_ATTRIBUTES(m_store)

  IFACEMETHODIMP ActivateObject(REFIID riid, void **object) override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (!m_source || m_source->IsShutdown()) {  // the caller may have shut it down directly
      auto source = Make<MediaSource>();
      if (!source) return E_OUTOFMEMORY;
      HRESULT hr = source->Initialize(m_devicePath, m_store.Get());
      if (FAILED(hr)) { Log(L"Source initialization failed: 0x%08X", hr); return hr; }
      m_source = source;
    }
    return m_source.CopyTo(riid, object);
  }
  IFACEMETHODIMP ShutdownObject() override {
    std::lock_guard<std::mutex> lock(m_lock);
    if (m_source) m_source->Shutdown();
    m_source.Reset();
    return S_OK;
  }
  IFACEMETHODIMP DetachObject() override {
    std::lock_guard<std::mutex> lock(m_lock);
    m_source.Reset();
    return S_OK;
  }

private:
  std::mutex m_lock;
  std::wstring m_devicePath;
  ComPtr<IMFAttributes> m_store;
  ComPtr<MediaSource> m_source;
};

class ClassFactory : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IClassFactory> {
public:
  explicit ClassFactory(const std::wstring &devicePath) : m_devicePath(devicePath) {}
  IFACEMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **object) override {
    if (outer) return CLASS_E_NOAGGREGATION;
    auto activate = Make<Activate>();
    if (!activate) return E_OUTOFMEMORY;
    RETURN_IF_FAILED(activate->Initialize(m_devicePath));
    HRESULT hr = activate.CopyTo(riid, object);
    if (hr == E_NOINTERFACE) hr = activate->ActivateObject(riid, object);  // caller wants the source itself
    return hr;
  }
  IFACEMETHODIMP LockServer(BOOL) override { return S_OK; }
private:
  std::wstring m_devicePath;
};

// ---------------------------------------------------------------------------------------
// Exports.

static std::wstring DevicePathForClass(REFCLSID clsid) {
  wchar_t id[64], key[128], path[1024];
  if (!StringFromGUID2(clsid, id, _countof(id))) return {};
  swprintf_s(key, L"Software\\Classes\\CLSID\\%s", id);
  DWORD size = sizeof(path);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, key, L"DevicePath", RRF_RT_REG_SZ, nullptr, path, &size) != ERROR_SUCCESS) return {};
  return path;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void **object) {
  if (!object) return E_POINTER;
  *object = nullptr;
  std::wstring devicePath = DevicePathForClass(clsid);
  if (devicePath.empty()) { Log(L"No DevicePath for %s", GuidText(clsid).c_str()); return CLASS_E_CLASSNOTAVAILABLE; }
  auto factory = Make<ClassFactory>(devicePath);
  return factory ? factory.CopyTo(riid, object) : E_OUTOFMEMORY;
}

// Frame Server keeps the DLL loaded while any camera is open; never unload early.
STDAPI DllCanUnloadNow() { return S_FALSE; }

// For tests: a source for a DirectShow device path, without any registration.
extern "C" __declspec(dllexport) HRESULT STDAPICALLTYPE OpenCaptureLinkCreateSource(LPCWSTR devicePath, IMFMediaSource **source) {
  if (!devicePath || !source) return E_POINTER;
  auto created = Make<MediaSource>();
  if (!created) return E_OUTOFMEMORY;
  RETURN_IF_FAILED(created->Initialize(devicePath, nullptr));
  *source = created.Detach();
  return S_OK;
}
