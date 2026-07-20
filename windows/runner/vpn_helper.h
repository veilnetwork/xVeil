#ifndef RUNNER_VPN_HELPER_H_
#define RUNNER_VPN_HELPER_H_

#include <optional>

// Runs the privileged VPN lifecycle when xVeil was re-executed with the
// private helper argument. Returns no value for a normal Flutter launch.
std::optional<int> RunWindowsVpnHelperIfRequested();

#endif  // RUNNER_VPN_HELPER_H_
