#include "my_application.h"
#include "vpn_helper.h"

#include <cstring>

int main(int argc, char** argv) {
  if (argc == 3 && std::strcmp(argv[1], "--xveil-vpn-helper") == 0) {
    return RunVpnHelper(argv[2]);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
