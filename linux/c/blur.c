#include <string.h>
#include "iris_blur.h"
#include <gdk/wayland/gdkwayland.h>
#include <math.h>
#include <wayland-client.h>
#include "ext-background-effect-v1-client.h"

struct manager {
    struct wl_display *display;
    struct wl_event_queue *queue;
    struct ext_background_effect_manager_v1 *mgr;
    struct wl_compositor *compositor;
    uint32_t caps;
};

static struct manager *shared; // one Wayland display per Iris

static void on_caps(void *data, struct ext_background_effect_manager_v1 *m, uint32_t flags) {
    (void)m;
    ((struct manager *)data)->caps = flags;
}
static const struct ext_background_effect_manager_v1_listener mgr_listener = {.capabilities = on_caps};

static void on_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    struct manager *m = data;
    if (strcmp(iface, ext_background_effect_manager_v1_interface.name) == 0) {
        m->mgr = wl_registry_bind(reg, name, &ext_background_effect_manager_v1_interface, 1);
        ext_background_effect_manager_v1_add_listener(m->mgr, &mgr_listener, m);
    } else if (strcmp(iface, wl_compositor_interface.name) == 0) {
        m->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, version < 4 ? version : 4);
    }
}
static void on_global_remove(void *data, struct wl_registry *reg, uint32_t name) { (void)data; (void)reg; (void)name; }
static const struct wl_registry_listener reg_listener = {.global = on_global, .global_remove = on_global_remove};

static struct manager *manager_for(GtkWidget *window) {
    GdkDisplay *d = gtk_widget_get_display(window);
    if (!GDK_IS_WAYLAND_DISPLAY(d)) return NULL;
    if (shared) return shared;
    shared = g_new0(struct manager, 1);
    shared->display = gdk_wayland_display_get_wl_display(d);
    // a queue of its own, so asking does not run GTK's own Wayland events
    shared->queue = wl_display_create_queue(shared->display);
    struct wl_display *wrapped = wl_proxy_create_wrapper(shared->display);
    wl_proxy_set_queue((struct wl_proxy *)wrapped, shared->queue);
    struct wl_registry *reg = wl_display_get_registry(wrapped);
    wl_proxy_wrapper_destroy(wrapped);
    wl_registry_add_listener(reg, &reg_listener, shared);
    wl_display_roundtrip_queue(shared->display, shared->queue); // the globals
    wl_display_roundtrip_queue(shared->display, shared->queue); // their first events
    return shared;
}

int iris_blur_available(GtkWidget *window) {
    struct manager *m = manager_for(window);
    return m && m->mgr && m->compositor && (m->caps & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR);
}

void iris_blur_set(GtkWidget *window, int x, int y, int w, int h, int radius) {
    if (!iris_blur_available(window)) return;
    GdkSurface *s = gtk_native_get_surface(GTK_NATIVE(window));
    if (!s || !GDK_IS_WAYLAND_SURFACE(s)) return;
    struct wl_surface *ws = gdk_wayland_surface_get_wl_surface(s);
    struct ext_background_effect_surface_v1 *fx = g_object_get_data(G_OBJECT(s), "iris-blur");
    if (!fx) {
        fx = ext_background_effect_manager_v1_get_background_effect(shared->mgr, ws);
        wl_proxy_set_queue((struct wl_proxy *)fx, shared->queue);
        g_object_set_data_full(G_OBJECT(s), "iris-blur", fx, (GDestroyNotify)ext_background_effect_surface_v1_destroy);
    }
    if (w <= 0 || h <= 0) {
        ext_background_effect_surface_v1_set_blur_region(fx, NULL);
    } else {
        struct wl_region *r = wl_compositor_create_region(shared->compositor);
        int rad = radius < 0 ? 0 : radius;
        if (rad * 2 > h) rad = h / 2;
        if (rad * 2 > w) rad = w / 2;
        wl_region_add(r, x, y + rad, w, h - 2 * rad);
        for (int i = 0; i < rad; i++) { // the corners, one row at a time
            double dy = rad - i - 0.5;
            int in = rad - (int)floor(sqrt((double)rad * rad - dy * dy));
            wl_region_add(r, x + in, y + i, w - 2 * in, 1);
            wl_region_add(r, x + in, y + h - 1 - i, w - 2 * in, 1);
        }
        ext_background_effect_surface_v1_set_blur_region(fx, r);
        wl_region_destroy(r);
    }
    // GTK commits the surface with its next frame, which carries the region
    gtk_widget_queue_draw(window);
    wl_display_flush(shared->display);
}
