/* Everything Iris calls in C: GTK 4 and libadwaita for the window, WPE
 * WebKit with its WPEPlatform API for the pages, libsoup for fetching, and
 * Iris's own C for the compositor's blur. build.zig translates this once
 * (std.Build.Step.TranslateC) into the module `c`. */
#include <adwaita.h>
#include <gdk/wayland/gdkwayland.h>
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <libsoup/soup.h>
#include <libdrm/drm_fourcc.h>
#include "iris_blur.h"
