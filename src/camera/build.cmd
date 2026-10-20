@echo off
rem Builds OpenCaptureLinkCamera.dll (x64) into the repository root, and the test harness into
rem src\camera\out. Needs the Visual Studio C++ build tools and a Windows 10 SDK.
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (echo Visual Studio C++ build tools not found & exit /b 1)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

set "HERE=%~dp0"
set "OUT=%HERE%out"
if not exist "%OUT%" mkdir "%OUT%"
set CFLAGS=/nologo /O2 /EHsc /MT /W3 /std:c++17 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN

cl %CFLAGS% /LD "%HERE%OpenCaptureLinkCamera.cpp" /Fo"%OUT%\\" /Fe"%HERE%..\..\OpenCaptureLinkCamera.dll" ^
  /link /DEF:"%HERE%OpenCaptureLinkCamera.def" /IMPLIB:"%OUT%\OpenCaptureLinkCamera.lib" ^
  mfplat.lib mfuuid.lib strmiids.lib ole32.lib oleaut32.lib advapi32.lib || exit /b 1

cl %CFLAGS% "%HERE%test\CameraTest.cpp" /Fo"%OUT%\\" /Fe"%OUT%\CameraTest.exe" ^
  /link mf.lib mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib || exit /b 1
