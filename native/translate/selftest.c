// Exercises libveil_translate through its C ABI, the way Dart will.
//
//   selftest <model_dir>
//
// This is the build's own check that what it produced can do its job. Linking
// and exporting the right names proves neither: the pipeline inside has an
// order to it — tokenise, append the end marker, decode, detokenise — and
// getting the marker wrong yields output that is fluent, plausible and wrong
// in a way no symbol check can see.
//
// Exit 0 only if every case behaves. Prints what it saw either way.
#include <stdio.h>
#include <string.h>

#include "veil_translate.h"

static int failures = 0;

static void ok(const char* name) { printf("  ok    %s\n", name); }

static void fail(const char* name, const char* detail) {
  printf("  FAIL  %s: %s\n", name, detail ? detail : "");
  failures++;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <model_dir>\n", argv[0]);
    return 2;
  }
  const char* model_dir = argv[1];
  printf("%s\n", veil_translate_version());

  // A missing model must be refused, and must say why. Returning NULL with an
  // empty explanation is how a deployment problem gets reported as "the
  // feature does not work".
  veil_translate_engine* absent = veil_translate_open("/nonexistent/model", 1, 1);
  if (absent != NULL) {
    fail("a missing model is refused", "open() succeeded");
    veil_translate_close(absent);
  } else if (strlen(veil_translate_last_error(NULL)) == 0) {
    fail("a missing model is refused", "no reason given");
  } else {
    ok("a missing model is refused, with a reason");
  }

  veil_translate_engine* engine = veil_translate_open(model_dir, 0, 4);
  if (engine == NULL) {
    fail("the model opens", veil_translate_last_error(NULL));
    printf("\nFAILED: %d\n", failures);
    return 1;
  }
  ok("the model opens");

  // Content, not just non-emptiness. "не покидает устройство" -> "never leaves
  // the device" is the sentence that first exposed the missing end marker:
  // without it the tail repeats and this substring still appears, so the check
  // also bounds the length.
  char* out = veil_translate(engine, "Это сообщение зашифровано и не покидает устройство.");
  if (out == NULL) {
    fail("a sentence translates", veil_translate_last_error(engine));
  } else {
    printf("        -> %s\n", out);
    if (strstr(out, "device") == NULL) {
      fail("a sentence translates", "the result does not mention the device");
    } else if (strlen(out) > 120) {
      fail("the output is not degenerate",
           "far longer than the input — the end-of-sequence marker is probably missing");
    } else {
      ok("a sentence translates, and does not ramble");
    }
    veil_translate_free(out);
  }

  // A long message must not come back with its tail missing.
  //
  // The decode has to be bounded — an unbounded one turns a degenerate
  // repetition loop into a hung UI — but a FIXED bound cuts honest text, and
  // silently: nothing in a truncated translation says it was truncated. The
  // bound is now four times this input, so the end of a long paragraph still
  // arrives. The marker is in the LAST sentence on purpose.
  {
    char longer[4096];
    longer[0] = '\0';
    for (int i = 0; i < 24; i++) {
      strcat(longer, "Это сообщение зашифровано и не покидает устройство. ");
    }
    strcat(longer, "Встретимся завтра у входа в метро.");

    char* out = veil_translate(engine, longer);
    if (out == NULL) {
      fail("a long message translates", veil_translate_last_error(engine));
    } else {
      if (strstr(out, "subway") == NULL && strstr(out, "metro") == NULL) {
        printf("        -> %.200s...\n", out);
        fail("the END of a long message survives",
             "the last sentence is missing — the decode was cut short");
      } else {
        ok("a long message keeps its tail");
      }
      veil_translate_free(out);
    }
  }

  char* blank = veil_translate(engine, "   ");
  if (blank == NULL) {
    fail("blank input is not an error", veil_translate_last_error(engine));
  } else {
    if (blank[0] != '\0') fail("blank input yields nothing", blank);
    else ok("blank input yields nothing, not an error");
    veil_translate_free(blank);
  }

  char* nothing = veil_translate(engine, NULL);
  if (nothing == NULL) {
    fail("a null string does not crash", "returned NULL");
  } else {
    ok("a null string is handled");
    veil_translate_free(nothing);
  }

  // Twice through the same engine: state carried between calls is the defect
  // this catches, and it is invisible to a single-shot test.
  char* first = veil_translate(engine, "Привет!");
  char* second = veil_translate(engine, "Привет!");
  if (first == NULL || second == NULL) {
    fail("the engine is reusable", "one of two calls failed");
  } else if (strcmp(first, second) != 0) {
    fail("the same input gives the same output", second);
  } else {
    ok("the same input gives the same output twice");
  }
  veil_translate_free(first);
  veil_translate_free(second);

  veil_translate_close(engine);

  if (failures > 0) {
    printf("\nFAILED: %d\n", failures);
    return 1;
  }
  printf("\nOK\n");
  return 0;
}
