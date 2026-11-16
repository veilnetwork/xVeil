# flutter_local_notifications_windows 3.1.1 omits individual cancellation for
# portable (non-MSIX) apps. Keep tags in a nonempty group so Windows can remove
# one toast by tag/group/AUMID, without clearing unrelated notifications.
# Also contain WinRT failures in the bool show/schedule API before Dart FFI.
# Patch only the build copy; never mutate the shared pub cache.
function(xveil_fix_windows_notification_history target)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "Windows notifications target is missing")
  endif()
  get_target_property(source_dir "${target}" SOURCE_DIR)
  set(original "${source_dir}/ffi_api.cpp")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${original}")
  file(READ "${original}" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  string(SHA256 digest "${source}")
  if(NOT digest STREQUAL "f93f710e58a4a706238e9a9821bd3c0b9617609a8030f6d0f8fe7aa862a8e046")
    message(FATAL_ERROR
      "Windows notifications dependency changed; review the history fix before building")
  endif()

  string(REPLACE
    "notification.Tag(winrt::to_hstring(id));"
    "notification.Tag(winrt::to_hstring(id));\n  notification.Group(L\"xveil\");"
    source "${source}")
  string(REPLACE
    "plugin->notifier.value().Update(data, tag);"
    "plugin->notifier.value().Update(data, tag, L\"xveil\");"
    source "${source}")
  string(REPLACE
    "if (plugin->hasIdentity) plugin->history.value().Remove(tag);"
    "if (plugin->hasIdentity) {\n    plugin->history.value().Remove(tag, L\"xveil\");\n  } else {\n    plugin->history.value().Remove(tag, L\"xveil\", plugin->aumid);\n  }"
    source "${source}")

  # HRESULT exceptions must not unwind through Dart FFI. The bool API already
  # represents rejection; include construction and Show/AddToSchedule, not only
  # XML parsing, in that boundary. In particular Show can reject a large toast.
  string(REPLACE
    "bool showNotification(NativePlugin* plugin, int id, char* xml, NativeStringMap bindings) {"
    "bool showNotification(NativePlugin* plugin, int id, char* xml, NativeStringMap bindings) try {"
    source "${source}")
  string(REPLACE
    "\n}\n\nbool scheduleNotification"
    "\n} catch (const winrt::hresult_error&) {\n  return false;\n}\n\nbool scheduleNotification"
    source "${source}")
  string(REPLACE
    "bool scheduleNotification(NativePlugin* plugin, int id, char* xml, int time) {"
    "bool scheduleNotification(NativePlugin* plugin, int id, char* xml, int time) try {"
    source "${source}")
  string(REPLACE
    "\n}\n\nNativeUpdateResult updateNotification"
    "\n} catch (const winrt::hresult_error&) {\n  return false;\n}\n\nNativeUpdateResult updateNotification"
    source "${source}")

  set(patched "${CMAKE_CURRENT_BINARY_DIR}/xveil_notifications/ffi_api.cpp")
  # configure_file avoids rewriting identical output on every configure.
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/xveil_notifications")
  set(template "${CMAKE_CURRENT_BINARY_DIR}/xveil_notifications/ffi_api.cpp.in")
  file(WRITE "${template}" "${source}")
  configure_file("${template}" "${patched}" COPYONLY)

  get_target_property(sources "${target}" SOURCES)
  set(updated_sources)
  set(replaced 0)
  foreach(entry IN LISTS sources)
    get_filename_component(absolute "${entry}" ABSOLUTE BASE_DIR "${source_dir}")
    if(absolute STREQUAL original)
      list(APPEND updated_sources "${patched}")
      math(EXPR replaced "${replaced} + 1")
    else()
      list(APPEND updated_sources "${absolute}")
    endif()
  endforeach()
  if(NOT replaced EQUAL 1)
    message(FATAL_ERROR "Expected one Windows notifications FFI source")
  endif()
  set_property(TARGET "${target}" PROPERTY SOURCES "${updated_sources}")
  target_include_directories("${target}" PRIVATE "${source_dir}")
endfunction()
