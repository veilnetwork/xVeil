import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:win32/win32.dart' as win;

/// Uncertainty never means that an elevated helper released its resources.
enum WindowsProcessState { running, exited, unknown }

/// Read-only kernel facts. Tests supply call results, not a lifecycle verdict.
abstract interface class WindowsProcessCalls {
  ({int handle, int error}) open(int pid);
  int poll(int handle);
  bool close(int handle);
}

final class _NativeProcessCalls implements WindowsProcessCalls {
  const _NativeProcessCalls();
  @override
  ({int handle, int error}) open(int pid) {
    // Resolve GetLastError's lazy binding before OpenProcess sets thread-local
    // error state. No await or other native call separates failure and sampling.
    win.GetLastError();
    final handle = win.OpenProcess(win.SYNCHRONIZE, 0, pid);
    return (handle: handle, error: handle == 0 ? win.GetLastError() : 0);
  }

  @override
  int poll(int handle) => win.WaitForSingleObject(handle, 0);
  @override
  bool close(int handle) => win.CloseHandle(handle) != 0;
}

/// A zero-duration kernel wait avoids localized/truncated tasklist output and
/// never blocks the UI. An unopenable or failed wait remains unknown. Like the
/// .NET process implementation, ERROR_INVALID_PARAMETER for a positive valid
/// PID means it no longer exists; PID zero is rejected before any native call.
/// https://learn.microsoft.com/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject
/// https://github.com/dotnet/runtime/blob/main/src/libraries/System.Diagnostics.Process/src/System/Diagnostics/ProcessManager.Windows.cs
class WindowsProcessProbe {
  const WindowsProcessProbe() : _calls = null;
  @visibleForTesting
  const WindowsProcessProbe.withCallsForTesting(WindowsProcessCalls calls)
    : _calls = calls;
  final WindowsProcessCalls? _calls;

  WindowsProcessState read(int pid) {
    if (pid <= 0 ||
        pid > 0xffffffff ||
        (_calls == null && !Platform.isWindows)) {
      return WindowsProcessState.unknown;
    }
    final calls = _calls ?? const _NativeProcessCalls();
    final ({int handle, int error}) opened;
    try {
      opened = calls.open(pid);
    } catch (_) {
      return WindowsProcessState.unknown;
    }
    if (opened.handle == 0) {
      return opened.error == win.ERROR_INVALID_PARAMETER
          ? WindowsProcessState.exited
          : WindowsProcessState.unknown;
    }
    var state = WindowsProcessState.unknown;
    try {
      state = switch (calls.poll(opened.handle)) {
        win.WAIT_OBJECT_0 => WindowsProcessState.exited,
        win.WAIT_TIMEOUT => WindowsProcessState.running,
        _ => WindowsProcessState.unknown,
      };
    } catch (_) {
      // A failed probe is not observed process termination.
    } finally {
      try {
        if (!calls.close(opened.handle)) state = WindowsProcessState.unknown;
      } catch (_) {
        state = WindowsProcessState.unknown;
      }
    }
    return state;
  }
}
