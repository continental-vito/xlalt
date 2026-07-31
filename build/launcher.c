/* ExcelAlt native launcher: writes the app's own preferences (config path,
 * no engine menu icon, no dock icon, no console, no update checks) via
 * CFPreferences under the app's own bundle id, then execs the engine.
 * Compiled on the CI macOS runner; replaces the former shell shim, which
 * some Gatekeeper configurations refuse as a bundle main executable. */
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>

static void setb(const char *k, Boolean v) {
  CFStringRef ks = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
  CFPreferencesSetAppValue(ks, v ? kCFBooleanTrue : kCFBooleanFalse,
                           kCFPreferencesCurrentApplication);
  CFRelease(ks);
}

int main(void) {
  char exe[PATH_MAX]; uint32_t n = sizeof exe;
  if (_NSGetExecutablePath(exe, &n) != 0) return 1;
  char real[PATH_MAX];
  if (!realpath(exe, real)) { strncpy(real, exe, sizeof real - 1); real[sizeof real - 1] = 0; }

  char contents[PATH_MAX];
  strncpy(contents, real, sizeof contents - 1); contents[sizeof contents - 1] = 0;
  char *p = strrchr(contents, '/'); if (p) *p = 0;   /* strip /ExcelAlt  */
  p = strrchr(contents, '/'); if (p) *p = 0;         /* strip /MacOS     */

  char cfg[PATH_MAX];
  snprintf(cfg, sizeof cfg, "%s/Resources/init.lua", contents);
  CFStringRef cfgs = CFStringCreateWithCString(NULL, cfg, kCFStringEncodingUTF8);
  CFPreferencesSetAppValue(CFSTR("MJConfigFile"), cfgs, kCFPreferencesCurrentApplication);
  CFRelease(cfgs);

  /* Silence Sparkle at the only level that actually wins.
   *
   * SUEnableAutomaticChecks in Info.plist is only a DEFAULT: once a value
   * has been written to this app's user defaults — which happens the
   * first time Sparkle runs — that value overrides the bundle every
   * launch afterwards. So an installed copy kept checking for updates
   * long after the plist said not to, and every check ended at "An error
   * occurred while running the updater", because applying an update means
   * launching Sparkle's nested Updater.app and macOS refuses to do that
   * inside an ad-hoc-signed, un-notarized bundle.
   *
   * Clearing SUFeedURL as well leaves nothing to check even if something
   * does trigger one. All of this becomes unnecessary with a Developer ID
   * certificate, at which point Sparkle can be turned back on. */
  CFPreferencesSetAppValue(CFSTR("SUEnableAutomaticChecks"), kCFBooleanFalse,
                           kCFPreferencesCurrentApplication);
  CFPreferencesSetAppValue(CFSTR("SUAutomaticallyUpdate"), kCFBooleanFalse,
                           kCFPreferencesCurrentApplication);
  CFPreferencesSetAppValue(CFSTR("HSAutomaticallyCheckForUpdates"), kCFBooleanFalse,
                           kCFPreferencesCurrentApplication);
  CFPreferencesSetAppValue(CFSTR("SUFeedURL"), NULL, kCFPreferencesCurrentApplication);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);


  setb("MJShowMenuIconKey", false);
  setb("MJShowDockIconKey", true);   /* regular app: dock icon + top-left menus */
  setb("MJShowWindowAtLaunchKey", false);
  setb("MJKeepConsoleOnTopKey", false);
  setb("SUEnableAutomaticChecks", false);
  setb("HSUploadCrashData", false);
  /* Purge persisted "status item hidden" flags: if the item was ever
   * dragged off the menu bar, macOS keeps NSStatusItem Visible=false and
   * silently hides every future item this bundle creates. */
  CFBundleRef mainb = CFBundleGetMainBundle();
  CFStringRef bid = mainb ? CFBundleGetIdentifier(mainb) : NULL;
  /* A development build has bundle id "...excel-alt-shortcuts.dev". It gets
   * its own preferences domain for free (they are keyed by bundle id) and,
   * below, its own fallback config directory — so it cannot disturb the
   * released app installed alongside it. */
  Boolean isDev = bid && CFStringHasSuffix(bid, CFSTR(".dev"));
  CFArrayRef klist = bid ? CFPreferencesCopyKeyList(
      bid, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) : NULL;
  if (klist) {
    for (CFIndex i = 0; i < CFArrayGetCount(klist); i++) {
      CFStringRef k = CFArrayGetValueAtIndex(klist, i);
      if (CFStringHasPrefix(k, CFSTR("NSStatusItem")))
        CFPreferencesSetAppValue(k, NULL, kCFPreferencesCurrentApplication);
    }
    CFRelease(klist);
  }
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);

  /* Robust config delivery: cfprefsd may ignore or cache MJConfigFile
   * written by this short-lived process, and older installs can leave a
   * stale config dir (~/.hammerspoon or a custom folder) that wins. So we
   * ALSO copy our init.lua into the runtime's default config directory and
   * point the preference at that copy. Whichever path the engine chooses,
   * it runs our code. */
  const char *home = getenv("HOME");
  if (home) {
    char defdir[PATH_MAX], defcfg[PATH_MAX], cmd[PATH_MAX * 3];
    snprintf(defdir, sizeof defdir, "%s/%s", home,
             isDev ? ".hammerspoon-xldev" : ".hammerspoon");
    mkdir(defdir, 0755);
    snprintf(defcfg, sizeof defcfg, "%s/init.lua", defdir);
    snprintf(cmd, sizeof cmd, "/bin/cp -f '%s' '%s' 2>/dev/null", cfg, defcfg);
    system(cmd);
    /* Remove stale Spoons/engine files from earlier experiments so they
     * cannot shadow ours. */
    snprintf(cmd, sizeof cmd, "/bin/rm -f '%s/engine.lua' 2>/dev/null", defdir);
    system(cmd);
  }

  char core[PATH_MAX];
  snprintf(core, sizeof core, "%s/MacOS/ExcelAltCore", contents);
  char *args[] = { core, NULL };
  execv(core, args);
  return 1;   /* execv only returns on failure */
}
