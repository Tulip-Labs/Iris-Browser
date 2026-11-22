// Background blur from the compositor (niri 26.04+, KWin and others that
// speak ext-background-effect-v1). Iris's window is translucent; where the
// compositor can blur what lies behind it, it asks for that, shaped like
// the window (rounded corners as a stack of rectangles).
#pragma once
#include <gtk/gtk.h>

// 1 when the window's compositor offers blur (call once the window is realized)
int iris_blur_available(GtkWidget *window);

// asks for blur behind the window's content: x, y, w, h in the window's
// logical units (the content, without its shadow); w == 0 asks for none
void iris_blur_set(GtkWidget *window, int x, int y, int w, int h, int radius);
