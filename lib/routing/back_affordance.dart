import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Leaves the current screen: pops when something sits below on the stack,
/// otherwise roots the app at home.
///
/// WHY THIS EXISTS: the router in [routerProvider] is FLAT — there is no
/// `ShellRoute` and no nested `GoRoute` tree — so a screen entered by anything
/// other than a `push` (a bare `go`, a redirect, a deep link, a restored
/// location) has NOTHING below it on the navigator. `AppBar` only synthesises
/// its automatic leading when `Navigator.canPop` is true, so such a screen
/// renders with the title flush to the edge and no way out at all: a dead end.
///
/// Every screen reachable as a route must therefore state its back affordance
/// explicitly rather than relying on the automatic one. Use [RootedBackButton].
void goBackOrHome(BuildContext context) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  context.go('/home');
}

/// The back arrow every routed screen should use as its `AppBar.leading`.
///
/// Behaves exactly like the automatic leading when the screen was pushed (it
/// pops), and — unlike the automatic one — is still THERE when the screen was
/// entered with an empty stack, where it falls back to home. Passing it costs
/// nothing in the common case and removes the dead-end class entirely.
class RootedBackButton extends StatelessWidget {
  const RootedBackButton({super.key});

  @override
  Widget build(BuildContext context) =>
      BackButton(onPressed: () => goBackOrHome(context));
}
