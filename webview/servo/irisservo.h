// The C functions of Iris's Servo bridge (rust/src/lib.rs).
#include <stdint.h>

typedef void (*IrisWakeFn)(void);
typedef void (*IrisEventFn)(uint64_t id, int kind, const char *text, int a, int b);
typedef void (*IrisFrameFn)(uint64_t id, const uint8_t *rgba, int w, int h);
typedef int (*IrisAllowFn)(uint64_t id, const char *url, const char *page, const char *kind);
typedef int (*IrisNavigateFn)(uint64_t id, const char *url);
typedef void (*IrisResultFn)(uint64_t token, const char *json);

int iris_servo_init(IrisWakeFn, IrisEventFn, IrisFrameFn, IrisAllowFn, IrisNavigateFn, IrisResultFn, float scale);
void iris_servo_spin(void);
int iris_servo_open(uint64_t id, int w, int h, const char *url);
void iris_servo_close(uint64_t id);
void iris_servo_load(uint64_t id, const char *url);
void iris_servo_back(uint64_t id);
void iris_servo_forward(uint64_t id);
void iris_servo_reload(uint64_t id);
void iris_servo_resize(uint64_t id, int w, int h);
void iris_servo_show(uint64_t id, int on);
void iris_servo_focus(uint64_t id, int on);
void iris_servo_zoom(uint64_t id, float z);
void iris_servo_mouse_move(uint64_t id, float x, float y);
void iris_servo_mouse_button(uint64_t id, float x, float y, int button, int down);
void iris_servo_wheel(uint64_t id, float x, float y, double dx, double dy, int pixels);
void iris_servo_key(uint64_t id, const char *key, const char *code, int down, int mods, int repeat);
void iris_servo_eval(uint64_t id, const char *js, uint64_t token);
char *iris_servo_cookies(const char *url);
void iris_servo_set_cookie(const char *url, const char *line);
void iris_servo_free(char *p);
void iris_servo_set_scale(float scale);
