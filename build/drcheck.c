// build/drcheck.c — does a new build satisfy an old build's designated
// requirement?
//
// This is the single check that decides whether the runtime's own
// "Check for Updates…" can install anything. Sparkle's installer helper
// (Sparkle.framework/Versions/B/Autoupdate) does exactly this, in this
// order, and reports
//
//   Code signature of the new version doesn't match the old version: %@
//
// where %@ is the requirement printed below. Ad-hoc signing with no
// explicit requirement makes macOS synthesise `cdhash H"…"`, which is
// pinned to one build and can never be satisfied by the next one. An
// explicit `identifier "…"` requirement is stable across builds.
//
// Build:  clang -O2 -o drcheck build/drcheck.c -framework CoreFoundation \
//               -framework Security
// Usage:  drcheck OLD.app NEW.app     (exit 0 = the update would install)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>

static CFURLRef url_for(const char *path) {
  CFStringRef s = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  CFURLRef u = CFURLCreateWithFileSystemPath(NULL, s, kCFURLPOSIXPathStyle, true);
  CFRelease(s);
  return u;
}

static void print_cf(const char *label, CFStringRef s) {
  if (!s) return;
  CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s),
                                                  kCFStringEncodingUTF8) + 1;
  char *buf = malloc((size_t)max);
  if (buf && CFStringGetCString(s, buf, max, kCFStringEncodingUTF8))
    printf("%s%s\n", label, buf);
  free(buf);
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s OLD.app NEW.app\n", argv[0]);
    return 2;
  }

  SecStaticCodeRef old_code = NULL, new_code = NULL;
  SecRequirementRef requirement = NULL;
  CFStringRef text = NULL;
  OSStatus st;

  CFURLRef old_url = url_for(argv[1]);
  CFURLRef new_url = url_for(argv[2]);

  st = SecStaticCodeCreateWithPath(old_url, kSecCSDefaultFlags, &old_code);
  if (st != errSecSuccess) {
    fprintf(stderr, "  cannot read the old bundle's signature (OSStatus %d)\n", (int)st);
    return 1;
  }
  // Precisely what Autoupdate asks for.
  st = SecCodeCopyDesignatedRequirement(old_code, kSecCSDefaultFlags, &requirement);
  if (st != errSecSuccess) {
    fprintf(stderr, "  cannot read the old bundle's designated requirement (OSStatus %d)\n", (int)st);
    return 1;
  }
  SecRequirementCopyString(requirement, kSecCSDefaultFlags, &text);
  print_cf("  old designated requirement: ", text);

  // A cdhash requirement is build-specific by construction. Say so
  // rather than letting the check below fail with a generic message.
  if (text && CFStringFind(text, CFSTR("cdhash"), 0).location != kCFNotFound) {
    fprintf(stderr, "  this is pinned to one build; no other build can satisfy it\n");
  }

  st = SecStaticCodeCreateWithPath(new_url, kSecCSDefaultFlags, &new_code);
  if (st != errSecSuccess) {
    fprintf(stderr, "  cannot read the new bundle's signature (OSStatus %d)\n", (int)st);
    return 1;
  }

  CFErrorRef err = NULL;
  st = SecStaticCodeCheckValidityWithErrors(
         new_code, kSecCSDefaultFlags | kSecCSCheckAllArchitectures, requirement, &err);
  if (st != errSecSuccess) {
    fprintf(stderr, "  the new build does NOT satisfy it (OSStatus %d)\n", (int)st);
    if (err) {
      CFStringRef d = CFErrorCopyDescription(err);
      print_cf("  ", d);
    }
    return 1;
  }

  printf("  the new build satisfies it — an in-place update would install\n");
  return 0;
}
