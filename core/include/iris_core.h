/* Iris's Rust core (core/): the flat C interface Odin binds in
 * linux/src/core_ffi.odin. Only flat types cross: const char*, uint8_t,
 * uint32_t, bool, size_t and opaque pointers. Every opaque pointer has a
 * create (or a function that makes it) and a destroy. Strings and buffers
 * the library returns are freed with iris_string_free / iris_bytes_free. */
#ifndef IRIS_CORE_H
#define IRIS_CORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *iris_core_version(void);
void iris_string_free(char *s);
void iris_bytes_free(uint8_t *p, size_t len);

/* ---- adblock-rust ---- */
typedef struct IrisAdblockBuilder IrisAdblockBuilder;
typedef struct IrisAdblock IrisAdblock; /* immutable: any thread may ask */

IrisAdblockBuilder *iris_adblock_builder_create(void);
void iris_adblock_builder_destroy(IrisAdblockBuilder *b);
bool iris_adblock_builder_add_list(IrisAdblockBuilder *b, const uint8_t *text, size_t len);
bool iris_adblock_builder_set_resources(IrisAdblockBuilder *b, const uint8_t *json, size_t len);
IrisAdblock *iris_adblock_build(IrisAdblockBuilder *b); /* NULL if no list was added */
void iris_adblock_destroy(IrisAdblock *e);

#define IRIS_ALLOW 0u
#define IRIS_BLOCK 1u
#define IRIS_REDIRECT 2u /* payload: the resource body to answer with */
#define IRIS_REWRITE 3u  /* payload: the address to load instead */
typedef struct {
	uint32_t action;
	char *payload; /* NULL, or iris_verdict_free */
} IrisVerdict;

bool iris_adblock_check(const IrisAdblock *e, const char *url, const char *source_url, const char *request_type, IrisVerdict *out);
void iris_verdict_free(IrisVerdict *v);
char *iris_adblock_cosmetic(const IrisAdblock *e, const char *url); /* JSON {css, script, generichide, exceptions} */
char *iris_adblock_class_id_css(const IrisAdblock *e, const char *classes, const char *ids, const char *exceptions);
uint8_t *iris_adblock_serialize(const IrisAdblock *e, size_t *len);
IrisAdblock *iris_adblock_deserialize(const uint8_t *p, size_t len);

/* ---- Mozilla add-ons (.xpi) ---- */
char *iris_xpi_inspect(const uint8_t *xpi, size_t len);
/* 0 ok; -1 checksum, -2 not a ZIP, -3 too big, -4 unsafe path or link,
 * -5 no manifest.json, -6 bad manifest, -7 disk */
int32_t iris_xpi_install(const uint8_t *xpi, size_t len, const char *dest_dir, const char *sha256, char **out);
bool iris_xpi_uninstall(const char *dest_dir, const char *dir);

/* ---- which address is an add-on page ---- */
char *iris_url_classify(const char *url); /* JSON {"kind":"amo"|"cws"|""...} */

#ifdef __cplusplus
}
#endif
#endif
