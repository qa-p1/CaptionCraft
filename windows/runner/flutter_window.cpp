#include "flutter_window.h"

#include <cstdint>
#include <algorithm>
#include <optional>
#include <string>
#include <variant>

#include <flutter/method_result_functions.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr UINT kCloseApprovedMessage = WM_APP + 0x47;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_lifecycle_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "captioncraft/window_lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
  storage_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "captioncraft/asset_pack_storage",
      &flutter::StandardMethodCodec::GetInstance());
  storage_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "availableBytes") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<flutter::EncodableMap>(
            call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_path", "A storage path is required.");
          return;
        }
        const auto path_entry = arguments->find(flutter::EncodableValue("path"));
        if (path_entry == arguments->end()) {
          result->Error("invalid_path", "A storage path is required.");
          return;
        }
        const auto* path = std::get_if<std::string>(&path_entry->second);
        const std::wstring wide_path =
            path == nullptr ? std::wstring() : Utf16FromUtf8(*path);
        if (wide_path.empty()) {
          result->Error("invalid_path", "The storage path is invalid.");
          return;
        }
        ULARGE_INTEGER available_bytes;
        if (!::GetDiskFreeSpaceExW(wide_path.c_str(), &available_bytes,
                                   nullptr, nullptr)) {
          result->Error("storage_probe_failed",
                        "Windows could not read available storage.");
          return;
        }
        result->Success(flutter::EncodableValue(
            static_cast<int64_t>(available_bytes.QuadPart)));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_lifecycle_channel_.reset();
  storage_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_GETMINMAXINFO) {
    const UINT window_dpi = ::GetDpiForWindow(hwnd);
    const UINT dpi = window_dpi == 0 ? 96 : window_dpi;
    auto* min_max = reinterpret_cast<MINMAXINFO*>(lparam);
    const LONG requested_width = ::MulDiv(800, dpi, 96);
    const LONG requested_height = ::MulDiv(520, dpi, 96);
    min_max->ptMinTrackSize.x = requested_width;
    min_max->ptMinTrackSize.y = requested_height;

    MONITORINFO monitor_info{};
    monitor_info.cbSize = sizeof(monitor_info);
    const HMONITOR monitor =
        ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (::GetMonitorInfo(monitor, &monitor_info)) {
      const LONG work_width =
          monitor_info.rcWork.right - monitor_info.rcWork.left;
      const LONG work_height =
          monitor_info.rcWork.bottom - monitor_info.rcWork.top;
      if (work_width > 0) {
        min_max->ptMinTrackSize.x =
            std::min<LONG>(requested_width, work_width);
      }
      if (work_height > 0) {
        min_max->ptMinTrackSize.y =
            std::min<LONG>(requested_height, work_height);
      }
    }
    return 0;
  }

  if (message == WM_CLOSE && !close_approved_) {
    if (close_request_pending_) {
      const int force_close = ::MessageBox(
          hwnd,
          L"CaptionCraft is still saving or stopping a render. Force closing "
          L"now may lose recent changes or leave a partial export.\n\nClose "
          L"anyway?",
          L"CaptionCraft is still working", MB_YESNO | MB_ICONWARNING |
                                                MB_DEFBUTTON2);
      if (force_close == IDYES) {
        close_approved_ = true;
        return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      }
      return 0;
    }
    if (!window_lifecycle_channel_) {
      return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    }

    close_request_pending_ = true;
    window_lifecycle_channel_->InvokeMethod(
        "requestClose", nullptr,
        std::make_unique<
            flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [this, hwnd](const flutter::EncodableValue* value) {
              close_request_pending_ = false;
              const bool* allow_close =
                  value == nullptr ? nullptr : std::get_if<bool>(value);
              if (allow_close != nullptr && *allow_close &&
                  GetHandle() == hwnd) {
                ::PostMessage(hwnd, kCloseApprovedMessage, 0, 0);
              }
            },
            [this](const std::string&, const std::string&,
                   const flutter::EncodableValue*) {
              close_request_pending_ = false;
            },
            [this, hwnd]() {
              close_request_pending_ = false;
              if (GetHandle() == hwnd) {
                ::PostMessage(hwnd, kCloseApprovedMessage, 0, 0);
              }
            }));
    return 0;
  }

  if (message == kCloseApprovedMessage) {
    close_approved_ = true;
    return Win32Window::MessageHandler(hwnd, WM_CLOSE, 0, 0);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
