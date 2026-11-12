//go:build android

// JNI glue for the Android engine: Go calls into LiteWeb (Java) here, and the
// string conversions for the events LiteWeb sends back.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static JavaVM *vm;
static jclass cls;
static jmethodID mStart, mOp, mVersion, mExitFull, mToBack, mTrim, mFocusApp;

// env gives this thread's JNIEnv, attaching it when needed (*attached says so).
static JNIEnv *env(int *attached) {
	JNIEnv *e = NULL;
	*attached = 0;
	if ((*vm)->GetEnv(vm, (void **)&e, JNI_VERSION_1_6) == JNI_EDETACHED) {
		if ((*vm)->AttachCurrentThread(vm, &e, NULL) != JNI_OK) return NULL;
		*attached = 1;
	}
	return e;
}

static void done(int attached) {
	if (attached) (*vm)->DetachCurrentThread(vm);
}

static void clearExc(JNIEnv *e) {
	if ((*e)->ExceptionCheck(e)) {
		(*e)->ExceptionDescribe(e);
		(*e)->ExceptionClear(e);
	}
}

// lgaInit finds LiteWeb through the app's class loader (FindClass on a Go
// thread only sees the system's classes).
int lgaInit(uintptr_t jvm, uintptr_t context) {
	vm = (JavaVM *)jvm;
	int at;
	JNIEnv *e = env(&at);
	if (!e) return 0;
	jobject ctx = (jobject)context;
	jclass ctxCls = (*e)->GetObjectClass(e, ctx);
	jmethodID getLoader = (*e)->GetMethodID(e, ctxCls, "getClassLoader", "()Ljava/lang/ClassLoader;");
	jobject loader = (*e)->CallObjectMethod(e, ctx, getLoader);
	jclass loaderCls = (*e)->FindClass(e, "java/lang/ClassLoader");
	jmethodID load = (*e)->GetMethodID(e, loaderCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
	jstring name = (*e)->NewStringUTF(e, "org.tulipanlabs.litego.LiteWeb");
	jclass c = (jclass)(*e)->CallObjectMethod(e, loader, load, name);
	clearExc(e);
	if (!c) {
		done(at);
		return 0;
	}
	cls = (jclass)(*e)->NewGlobalRef(e, c);
	mStart = (*e)->GetStaticMethodID(e, cls, "start", "(Landroid/view/View;Z)V");
	mOp = (*e)->GetStaticMethodID(e, cls, "op", "(IJIIIILjava/lang/String;J)V");
	mVersion = (*e)->GetStaticMethodID(e, cls, "version", "()Ljava/lang/String;");
	mExitFull = (*e)->GetStaticMethodID(e, cls, "exitFullscreen", "()Z");
	mToBack = (*e)->GetStaticMethodID(e, cls, "toBack", "()V");
	mTrim = (*e)->GetStaticMethodID(e, cls, "trim", "()V");
	mFocusApp = (*e)->GetStaticMethodID(e, cls, "focusApp", "()V");
	clearExc(e);
	done(at);
	return mStart && mOp;
}

void lgaStart(uintptr_t view, int low) {
	int at;
	JNIEnv *e = env(&at);
	if (!e || !cls) return;
	(*e)->CallStaticVoidMethod(e, cls, mStart, (jobject)view, (jboolean)(low != 0));
	clearExc(e);
	done(at);
}

void lgaOp(int op, int64_t id, int a, int b, int c, int d, const uint16_t *s, int n, int64_t cb) {
	int at;
	JNIEnv *e = env(&at);
	if (!e || !cls) return;
	jstring js = s ? (*e)->NewString(e, (const jchar *)s, n) : NULL;
	(*e)->CallStaticVoidMethod(e, cls, mOp, (jint)op, (jlong)id, (jint)a, (jint)b, (jint)c, (jint)d, js, (jlong)cb);
	clearExc(e);
	if (js) (*e)->DeleteLocalRef(e, js);
	done(at);
}

static void callStatic(jmethodID m) {
	int at;
	JNIEnv *e = env(&at);
	if (!e || !cls || !m) return;
	(*e)->CallStaticVoidMethod(e, cls, m);
	clearExc(e);
	done(at);
}

void lgaToBack(void) { callStatic(mToBack); }
void lgaTrim(void) { callStatic(mTrim); }
void lgaFocusApp(void) { callStatic(mFocusApp); }

int lgaExitFullscreen(void) {
	int at;
	JNIEnv *e = env(&at);
	if (!e || !cls) return 0;
	jboolean r = (*e)->CallStaticBooleanMethod(e, cls, mExitFull);
	clearExc(e);
	done(at);
	return r;
}

// lgaString copies a Java string as UTF-16 (Go turns it into UTF-8); *n is
// its length. The copy is freed by the caller.
uint16_t *lgaString(JNIEnv *e, jstring s, int *n) {
	*n = 0;
	if (!s) return NULL;
	jsize len = (*e)->GetStringLength(e, s);
	uint16_t *out = malloc((len + 1) * sizeof(uint16_t));
	if (!out) return NULL;
	(*e)->GetStringRegion(e, s, 0, len, (jchar *)out);
	*n = len;
	return out;
}

jstring lgaNewString(JNIEnv *e, const uint16_t *s, int n) { return (*e)->NewString(e, (const jchar *)s, n); }

uint16_t *lgaVersion(int *n) {
	int at;
	*n = 0;
	JNIEnv *e = env(&at);
	if (!e || !cls) return NULL;
	jstring s = (jstring)(*e)->CallStaticObjectMethod(e, cls, mVersion);
	clearExc(e);
	uint16_t *out = lgaString(e, s, n);
	if (s) (*e)->DeleteLocalRef(e, s);
	done(at);
	return out;
}
