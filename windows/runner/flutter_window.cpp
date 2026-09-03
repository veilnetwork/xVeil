#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // CLEAR THE MEMBER BEFORE THE CONTROLLER DIES, or quitting crashes.
  //
  // `windowManager.destroy()` — what the tray's Quit calls — is
  // `PostQuitMessage(0)` on Windows and nothing else. The top-level window is
  // still alive when the message loop returns, so `OnDestroy` never runs and
  // `flutter_controller_` is still set here. Tearing the controller down then
  // destroys the engine's child view window, and `DestroyWindow` dispatches
  // messages back to THIS window's procedure while the controller is
  // half-gone.
  //
  // `std::unique_ptr`'s destructor does not null the pointer before it runs
  // the deleter, so the `if (flutter_controller_)` guard in `MessageHandler`
  // below still passed and handed the message to a destroyed controller:
  //
  //   flutter_windows!FlutterDesktopViewControllerHandleTopLevelWindowProc
  //   ldr x0,[x0,#0x10]   with x0 = 0   ->   c0000005
  //
  // The access violation escaped a kernel user-callback, which Windows turns
  // into STATUS_FATAL_USER_CALLBACK_EXCEPTION (0xc000041d), and Error
  // Reporting then held the process for about 150 seconds. That wait is what
  // users reported as "Quit hangs": the window and the tray icon go, and
  // xveil.exe stays in the task list for two and a half minutes. Measured on
  // a Windows 11 ARM64 stand, 0.17 s of CPU across those 150 s.
  //
  // A stock `flutter create` app never reaches this: its close button
  // destroys the window first, so `OnDestroy` nulls the controller and this
  // destructor has nothing left to tear down. It exits in 3 s.
  //
  // Moving out leaves the member null for the whole of the deleter's work.
  auto controller = std::move(flutter_controller_);
}

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
      // Guarded, unlike the template this came from. Now that the destructor
      // above clears the member first, a message CAN arrive here with no
      // controller — that is the whole point of the change — and this line
      // dereferences it without asking.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
