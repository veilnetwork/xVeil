import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_stack.dart';

/// Which local control channels each platform gets for the embedded node.
///
/// Windows is the reason this is a test and not an inline `Platform.isIOS`.
/// It fell through to the POSIX branch and handed the node a bare
/// `C:\...\admin.sock`, which the FFI wrapped as `unix://C:\...` and pasted
/// into a TOML template — where `\U` opens a unicode escape. The shipped
/// Windows build died composing its config, before the node ever started, and
/// no "unsupported endpoint" reached any log to say why.
void main() {
  const runtimeDir = r'C:\Users\me\AppData\Local\Temp\xveil-rt-1';
  const posixDir = '/tmp/xveil-rt-1';

  group('platforms without a Unix domain socket', () {
    test('Windows takes loopback TCP with anchor sidecars', () {
      final plan = localEndpointPlanFor('windows');
      expect(plan.loopbackTcp, isTrue);
      // The node binds TCP and drops its port/token sidecars in the runtime dir.
      expect(
        plan.adminEndpoint(runtimeDir),
        'tcp://127.0.0.1:0?runtime_dir=$runtimeDir',
      );
      expect(
        plan.ipcEndpoint(runtimeDir),
        'tcp://127.0.0.1:0?runtime_dir=$runtimeDir',
      );
      // Nothing may ask Windows for a Unix socket.
      expect(plan.adminEndpoint(runtimeDir), isNot(contains('.sock')));
      expect(plan.ipcEndpoint(runtimeDir), isNot(contains('.sock')));
      // The app watches the anchors, whose parent dir carries the sidecars.
      // Joined with `/`, which Win32 accepts as a separator just as it does
      // `\` — what the readiness probe needs is the parent directory and the
      // basename, so assert those rather than the separator.
      expect(plan.adminSocket(runtimeDir), startsWith(runtimeDir));
      expect(plan.adminSocket(runtimeDir), endsWith('admin.anchor'));
      expect(plan.ipcSocket(runtimeDir), startsWith(runtimeDir));
      expect(plan.ipcSocket(runtimeDir), endsWith('ipc.anchor'));
      // The backslashes must reach the node intact — this is the exact string
      // that used to detonate the TOML template.
      expect(plan.adminEndpoint(runtimeDir), contains(r'C:\Users\me'));
    });

    test('iOS keeps the shape it already had', () {
      // Container paths exceed sockaddr_un's SUN_LEN; unchanged by the Windows
      // fix, and asserted so a later edit cannot quietly take it back.
      final plan = localEndpointPlanFor('ios');
      expect(plan.loopbackTcp, isTrue);
      expect(
        plan.adminEndpoint(posixDir),
        'tcp://127.0.0.1:0?runtime_dir=$posixDir',
      );
      expect(plan.adminSocket(posixDir), '$posixDir/admin.anchor');
      expect(plan.ipcSocket(posixDir), '$posixDir/ipc.anchor');
    });
  });

  group('platforms with a Unix domain socket', () {
    test('macOS and Linux keep binding real sockets', () {
      for (final os in ['macos', 'linux']) {
        final plan = localEndpointPlanFor(os);
        expect(plan.loopbackTcp, isFalse, reason: '$os has unix sockets');
        // The endpoint the node binds IS the path the app connects to.
        expect(plan.adminEndpoint(posixDir), '$posixDir/admin.sock');
        expect(plan.adminSocket(posixDir), '$posixDir/admin.sock');
        expect(plan.ipcEndpoint(posixDir), '$posixDir/app.sock');
        expect(plan.ipcSocket(posixDir), '$posixDir/app.sock');
        // No TCP anywhere on the desktop POSIX path.
        expect(plan.adminEndpoint(posixDir), isNot(startsWith('tcp://')));
      }
    });

    test('Android keeps binding real sockets', () {
      final plan = localEndpointPlanFor('android');
      expect(plan.loopbackTcp, isFalse);
      expect(plan.adminEndpoint(posixDir), '$posixDir/admin.sock');
      expect(plan.ipcEndpoint(posixDir), '$posixDir/app.sock');
    });
  });

  test('an unknown platform is treated as POSIX, not as Windows', () {
    // The TCP arm is the exception; anything unrecognised keeps the default.
    final plan = localEndpointPlanFor('fuchsia');
    expect(plan.loopbackTcp, isFalse);
    expect(plan.adminEndpoint(posixDir), '$posixDir/admin.sock');
  });
}
