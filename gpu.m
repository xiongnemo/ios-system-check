// System Check's GPU tab (what was GPU Check): every graphics capability an iOS game may need, tested one at a time,
// each with PASS, FAIL or SKIP -- or CRASHED / HUNG when it took the application down. OpenGL ES 1, 2 and 3 contexts
// with their limits and extensions, drawing off screen (depth, stencil, blending), the texture formats games ship
// (compressed ones too), the extensions engines use (vertex arrays, mapped buffers, instancing, queries, fences,
// framebuffer fetch...), drawing on the screen through a CAEAGLLayer (MSAA, discards), GLKit, CADisplayLink's rates,
// Core Image, Metal, SceneKit and SpriteKit. Written to test the iOS 16.5 port to the Redmi K40, where OpenGL ES is
// Mesa's freedreno behind the port's own EAGLContext. Run (or systemcheck://gpu/run) runs everything in order, with
// no tap. Each test is written down in Documents/gpucheck.log before it starts and when it ends, so that one that
// takes the application down is found at the next launch, marked, and skipped from then on (until Run again), and
// the next Run goes on with the next test. Every result is also a line on /dev/console ("gpucheck: ...") and in
// NSLog.
#define GLES_SILENCE_DEPRECATION 1      /* OpenGL ES and GLKit: deprecated since iOS 12, and what is tested here */
#define CI_SILENCE_GL_DEPRECATION 1
#define SCN_SILENCE_GL_DEPRECATION 1
#import <CoreImage/CoreImage.h>
#import <GLKit/GLKit.h>
#import <Metal/Metal.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>
#import <SpriteKit/SpriteKit.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <unistd.h>
#import "check.h"

/* (preferredFramesPerSecond and the like: deprecated, and tested on purpose) */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* formats iOS's headers do not name: no iPhone has them, other GPUs do */
#ifndef GL_ETC1_RGB8_OES
#define GL_ETC1_RGB8_OES                        0x8D64
#endif
#ifndef GL_COMPRESSED_RGB_S3TC_DXT1_EXT
#define GL_COMPRESSED_RGB_S3TC_DXT1_EXT         0x83F0
#endif
#ifndef GL_COMPRESSED_RGBA_S3TC_DXT5_EXT
#define GL_COMPRESSED_RGBA_S3TC_DXT5_EXT        0x83F3
#endif

#define ES1 kEAGLRenderingAPIOpenGLES1
#define ES2 kEAGLRenderingAPIOpenGLES2
#define ES3 kEAGLRenderingAPIOpenGLES3

#define HANG_SECONDS    8.0     /* a test still running after this long has hung (the main thread is held) */
#define ASYNC_LIMIT     7.5     /* an asynchronous test with the main thread free gets this long to answer */
#define SHOW_SECONDS    1.5     /* how long the on-screen tests leave their last picture up, for a screenshot */
#define CYCLE_FRAMES    30      /* frames presented by the on-screen tests (and drawn by GLKViewController) */
#define MSAA_FRAMES     10
#define DISCARD_FRAMES  20
#define LINE_BYTES      260     /* a console line, after "gpucheck: ", at most */

/* a test's status, in rising order of severity: a later verdict only counts if it is worse */
enum { ST_WAITING, ST_RUNNING, ST_PASS, ST_SKIP, ST_FAIL, ST_HUNG, ST_CRASHED, ST_COUNT };

static const char *const status_c[ST_COUNT] = {
	[ST_WAITING] = "-", [ST_RUNNING] = "running", [ST_PASS] = "PASS", [ST_SKIP] = "SKIP", [ST_FAIL] = "FAIL",
	[ST_HUNG] = "HUNG", [ST_CRASHED] = "CRASHED",
};

static int
status_from_name(NSString *name)
{
	for (int s = 0; s < ST_COUNT; s++) {
		if (strcmp(status_c[s], name.UTF8String) == 0) {
			return s;
		}
	}
	return ST_FAIL;
}

static UIColor *
status_color(int status)
{
	switch (status) {
	case ST_PASS:
		return UIColor.systemGreenColor;
	case ST_FAIL:
		return UIColor.systemRedColor;
	case ST_CRASHED:
		return UIColor.systemPurpleColor;
	case ST_HUNG:
		return UIColor.systemOrangeColor;
	case ST_RUNNING:
		return UIColor.systemBlueColor;
	default:
		return UIColor.secondaryLabelColor;
	}
}

/* the hardware's own name for itself: on the K40 port, the iPhone it says it is */
static NSString *
machine(void)
{
	char name[64] = "";
	size_t size = sizeof(name) - 1;

	return sysctlbyname("hw.machine", name, &size, NULL, 0) == 0 ? @(name) : @"?";
}

#pragma mark the record: Documents/gpucheck.log, /dev/console and NSLog

/*
 * The log is a line per event, KIND <tab> TEST <tab> TEXT, appended and flushed to the disk before anything else
 * happens: "run" (a run starts), "running" (a test starts), "note", "result", "crashed" (a signal or an uncaught
 * exception, written by the handler on its way out), "hung" (the watchdog), "mark" (a test that took the application
 * down: skipped until Run again), "done". What the last launch left "running" is what took it down.
 */
static int g_log = -1, g_console = -1;

static NSString *
log_path(void)
{
	NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?:
	    NSTemporaryDirectory();

	[NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil
	    error:nil];
	return [documents stringByAppendingPathComponent:@"gpucheck.log"];
}

/* one line of the log (field: a third column, or NULL), on the disk when this returns */
static void
record(const char *kind, const char *ident, const char *field, NSString *text)
{
	NSString *clean = [[text ?: @"" stringByReplacingOccurrencesOfString:@"\t" withString:@" "]
	    stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
	NSString *line = field != NULL ? [NSString stringWithFormat:@"%s\t%s\t%s\t%@\n", kind, ident, field, clean] :
	    [NSString stringWithFormat:@"%s\t%s\t%@\n", kind, ident, clean];
	NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];

	if (g_log >= 0) {
		(void)write(g_log, bytes.bytes, bytes.length);
		(void)fsync(g_log);
	}
}

/* a line for whoever reads the console, "gpucheck: TEXT", cut into pieces of at most LINE_BYTES; and NSLog */
static void say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void
say(NSString *format, ...)
{
	va_list arguments;
	NSString *text;
	NSData *bytes;
	const char *p;
	size_t left;
	BOOL first = YES;

	va_start(arguments, format);
	text = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	NSLog(@"gpucheck: %@", text);
	if (g_console < 0) {
		return;
	}
	bytes = [text dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
	p = bytes.bytes;
	left = bytes.length;
	do {
		const char *head = first ? "gpucheck: " : "gpucheck: ... ";
		size_t h = strlen(head), n = MIN(left, (size_t)LINE_BYTES);
		char line[LINE_BYTES + 32];

		memcpy(line, head, h);
		memcpy(line + h, p, n);
		line[h + n] = '\n';
		(void)write(g_console, line, h + n + 1);
		p += n;
		left -= n;
		first = NO;
	} while (left > 0);
}

/* words as lines of at most width characters: the long lists, in the notes and on the console */
static NSArray<NSString *> *
lines_of(NSArray<NSString *> *words, NSUInteger width)
{
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	NSMutableString *line = [NSMutableString string];

	for (NSString *word in words) {
		if (line.length > 0 && line.length + 1 + word.length > width) {
			[lines addObject:[line copy]];
			[line setString:@""];
		}
		if (line.length > 0) {
			[line appendString:@" "];
		}
		[line appendString:word];
	}
	if (line.length > 0) {
		[lines addObject:line];
	}
	return lines;
}

#pragma mark a test

/*
 * The one test being run: what it found (notes, each logged and said at once, so a crash keeps what came before it)
 * and its verdict. pass/skip/fail may be called more than once: the worst wins. A test whose extension is not listed
 * still runs -- games call these without looking -- and whatever it finds becomes a SKIP. A synchronous test is over
 * when its function returns; an asynchronous one sets async and calls end itself, and keeps what it needs in helper.
 */
@interface Test : NSObject
@property (readonly, nonatomic) int index;
@property (readonly, nonatomic) const char *ident;
@property (readonly, nonatomic) int status;
@property (readonly, nonatomic) NSString *detail;
@property (readonly, nonatomic) NSMutableArray<NSString *> *notes;
@property (readonly, nonatomic) BOOL ended;
@property (nonatomic) BOOL async;
@property (strong, nonatomic) id helper;
@property (copy, nonatomic) void (^cleanup)(void);
@property (copy, nonatomic) void (^done)(Test *test);
@property (weak, nonatomic) UIWindow *window;
@property (weak, nonatomic) UIViewController *presenter;
- (instancetype)initWithIndex:(int)index ident:(const char *)ident;
- (void)note:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)pass:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)skip:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)fail:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)missing:(NSString *)extension;
- (BOOL)failed;
- (void)end;
@end

@implementation Test {
	NSString *_missing;
}

- (instancetype)initWithIndex:(int)index ident:(const char *)ident
{
	self = [super init];
	if (self != nil) {
		_index = index;
		_ident = ident;
		_status = ST_WAITING;
		_notes = [NSMutableArray array];
	}
	return self;
}

- (void)note:(NSString *)format, ...
{
	va_list arguments;
	NSString *text;

	va_start(arguments, format);
	text = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	[_notes addObject:text];
	record("note", _ident, NULL, text);
	say(@"%s + %@", _ident, text);
}

- (void)verdict:(int)status format:(NSString *)format arguments:(va_list)arguments
{
	NSString *text = [[NSString alloc] initWithFormat:format arguments:arguments];

	if (_ended) {
		return;
	}
	if (status > _status) {
		_status = status;
		_detail = text;
	} else if (status == ST_FAIL) {
		[self note:@"also: %@", text];
	}
}

- (void)pass:(NSString *)format, ...
{
	va_list arguments;

	va_start(arguments, format);
	[self verdict:ST_PASS format:format arguments:arguments];
	va_end(arguments);
}

- (void)skip:(NSString *)format, ...
{
	va_list arguments;

	va_start(arguments, format);
	[self verdict:ST_SKIP format:format arguments:arguments];
	va_end(arguments);
}

- (void)fail:(NSString *)format, ...
{
	va_list arguments;

	va_start(arguments, format);
	[self verdict:ST_FAIL format:format arguments:arguments];
	va_end(arguments);
}

- (void)missing:(NSString *)extension
{
	if (_missing == nil) {
		_missing = extension;
		[self note:@"%@ is not listed: trying anyway", extension];
	}
}

- (BOOL)failed
{
	return _status == ST_FAIL;
}

- (void)end
{
	void (^cleanup)(void) = _cleanup;
	void (^done)(Test *) = _done;

	if (_ended) {
		return;
	}
	_ended = YES;
	if (_status < ST_PASS) {
		_status = ST_FAIL;
		_detail = @"gave no verdict (a bug in GPU Check)";
	}
	if (_missing != nil) {
		_detail = [NSString stringWithFormat:@"no %@ (tried anyway: %s %@)", _missing, status_c[_status], _detail];
		_status = ST_SKIP;
	}
	_cleanup = nil;
	_done = nil;
	if (cleanup != nil) {
		cleanup();
	}
	_helper = nil;
	if (done != nil) {
		done(self);
	}
}

@end

#pragma mark GL helpers

static NSString *
api_name(EAGLRenderingAPI api)
{
	return api == ES1 ? @"ES1" : api == ES2 ? @"ES2" : @"ES3";
}

static NSString *
gl_error_name(GLenum error)
{
	switch (error) {
	case GL_NO_ERROR:
		return @"GL_NO_ERROR";
	case GL_INVALID_ENUM:
		return @"GL_INVALID_ENUM";
	case GL_INVALID_VALUE:
		return @"GL_INVALID_VALUE";
	case GL_INVALID_OPERATION:
		return @"GL_INVALID_OPERATION";
	case GL_INVALID_FRAMEBUFFER_OPERATION:
		return @"GL_INVALID_FRAMEBUFFER_OPERATION";
	case GL_OUT_OF_MEMORY:
		return @"GL_OUT_OF_MEMORY";
	case GL_STACK_OVERFLOW:
		return @"GL_STACK_OVERFLOW";
	case GL_STACK_UNDERFLOW:
		return @"GL_STACK_UNDERFLOW";
	default:
		return [NSString stringWithFormat:@"GL error 0x%04x", error];
	}
}

/* every error GL holds (it may hold more than one), as one string; nil when there is none */
static NSString *
gl_errors(void)
{
	NSMutableArray<NSString *> *names = nil;
	GLenum error;

	for (int i = 0; i < 8 && (error = glGetError()) != GL_NO_ERROR; i++) {
		names = names ?: [NSMutableArray array];
		[names addObject:gl_error_name(error)];
	}
	return [names componentsJoinedByString:@" + "];
}

/* after a step: YES if GL holds no error, else the test fails naming the step */
static BOOL
gl_step(Test *t, NSString *step)
{
	NSString *errors = gl_errors();

	if (errors == nil) {
		return YES;
	}
	[t fail:@"%@: %@", step, errors];
	return NO;
}

/* a new context of api, made current; nil, the test failed, when there is none */
static EAGLContext *
gl_begin(Test *t, EAGLRenderingAPI api)
{
	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:api];

	if (ctx == nil) {
		[t fail:@"no OpenGL %@ context: initWithAPI: returned nil", api_name(api)];
		return nil;
	}
	if (![EAGLContext setCurrentContext:ctx]) {
		[t fail:@"setCurrentContext: returned NO"];
		return nil;
	}
	(void)gl_errors();
	return ctx;
}

/* the end of a test's context: an error still held fails the test; then no context is current */
static void
gl_end(Test *t, EAGLContext *ctx)
{
	NSString *errors;

	if (ctx == nil) {
		return;
	}
	if (EAGLContext.currentContext != ctx) {
		[EAGLContext setCurrentContext:ctx];
	}
	errors = gl_errors();
	if (errors != nil) {
		[t fail:@"GL error left at the end: %@", errors];
	}
	[EAGLContext setCurrentContext:nil];
}

static BOOL
has_extension(const char *name)
{
	const char *list = (const char *)glGetString(GL_EXTENSIONS), *p;
	size_t n = strlen(name);

	for (p = list; p != NULL && (p = strstr(p, name)) != NULL; p += n) {
		if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0')) {
			return YES;
		}
	}
	return NO;
}

/* the extension a test needs ("A|B": either), in the current context; when it is missing the test goes on, a SKIP */
static BOOL
need(Test *t, NSString *names)
{
	for (NSString *name in [names componentsSeparatedByString:@"|"]) {
		if (has_extension(name.UTF8String)) {
			return YES;
		}
	}
	[t missing:[names stringByReplacingOccurrencesOfString:@"|" withString:@" or "]];
	return NO;
}

/*
 * Framebuffers: ES1 has them only as OES_framebuffer_object's functions, ES2 and ES3 in the core; the names of the
 * enums are different, their values the same. So the functions are picked once, here, and the rest is shared.
 */
typedef struct {
	void (*genFramebuffers)(GLsizei, GLuint *);
	void (*bindFramebuffer)(GLenum, GLuint);
	void (*deleteFramebuffers)(GLsizei, const GLuint *);
	void (*genRenderbuffers)(GLsizei, GLuint *);
	void (*bindRenderbuffer)(GLenum, GLuint);
	void (*deleteRenderbuffers)(GLsizei, const GLuint *);
	void (*renderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
	void (*framebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
	GLenum (*checkFramebufferStatus)(GLenum);
	void (*getRenderbufferParameteriv)(GLenum, GLenum, GLint *);
} FBFuncs;

static const FBFuncs fb_oes = {
	glGenFramebuffersOES, glBindFramebufferOES, glDeleteFramebuffersOES, glGenRenderbuffersOES, glBindRenderbufferOES,
	glDeleteRenderbuffersOES, glRenderbufferStorageOES, glFramebufferRenderbufferOES, glCheckFramebufferStatusOES,
	glGetRenderbufferParameterivOES,
};

static const FBFuncs fb_core = {
	glGenFramebuffers, glBindFramebuffer, glDeleteFramebuffers, glGenRenderbuffers, glBindRenderbuffer,
	glDeleteRenderbuffers, glRenderbufferStorage, glFramebufferRenderbuffer, glCheckFramebufferStatus,
	glGetRenderbufferParameteriv,
};

static NSString *
fb_status_name(GLenum status)
{
	switch (status) {
	case GL_FRAMEBUFFER_COMPLETE:
		return @"GL_FRAMEBUFFER_COMPLETE";
	case GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT:
		return @"GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT";
	case GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT:
		return @"GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT";
	case GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS:
		return @"GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS";
	case GL_FRAMEBUFFER_UNSUPPORTED:
		return @"GL_FRAMEBUFFER_UNSUPPORTED";
	case GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE:
		return @"GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE";
	case 0:
		return [NSString stringWithFormat:@"0 (%@)", gl_errors() ?: @"no error"];
	default:
		return [NSString stringWithFormat:@"0x%04x", status];
	}
}

static NSString *
depth_name(GLenum depth)
{
	return depth == GL_DEPTH_COMPONENT16 ? @"DEPTH_COMPONENT16" : depth == GL_DEPTH24_STENCIL8_OES ?
	    @"DEPTH24_STENCIL8" : depth == 0 ? @"no depth" : [NSString stringWithFormat:@"depth 0x%04x", depth];
}

typedef struct {
	const FBFuncs *f;
	GLuint frame, color, depth;
	GLsizei w, h;
} FBO;

/*
 * An off-screen framebuffer, w x h: an RGBA8 colour renderbuffer and, unless depth is 0, a depth renderbuffer of that
 * format (a packed depth-stencil one is the stencil attachment too). Bound, with the viewport over it. NO, the test
 * failed, when GL will not have it.
 */
static BOOL
fbo_make(Test *t, FBO *b, BOOL es1, GLsizei w, GLsizei h, GLenum depth)
{
	const FBFuncs *f = es1 ? &fb_oes : &fb_core;
	GLenum status;

	*b = (FBO){ f, 0, 0, 0, w, h };
	f->genFramebuffers(1, &b->frame);
	f->bindFramebuffer(GL_FRAMEBUFFER, b->frame);
	f->genRenderbuffers(1, &b->color);
	f->bindRenderbuffer(GL_RENDERBUFFER, b->color);
	f->renderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, w, h);
	f->framebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, b->color);
	if (depth != 0) {
		f->genRenderbuffers(1, &b->depth);
		f->bindRenderbuffer(GL_RENDERBUFFER, b->depth);
		f->renderbufferStorage(GL_RENDERBUFFER, depth, w, h);
		f->framebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, b->depth);
		if (depth == GL_DEPTH24_STENCIL8_OES) {
			f->framebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, b->depth);
		}
	}
	if (!gl_step(t, [NSString stringWithFormat:@"framebuffer (RGBA8, %@)", depth_name(depth)])) {
		return NO;
	}
	status = f->checkFramebufferStatus(GL_FRAMEBUFFER);
	if (status != GL_FRAMEBUFFER_COMPLETE) {
		[t fail:@"glCheckFramebufferStatus (RGBA8, %@): %@", depth_name(depth), fb_status_name(status)];
		return NO;
	}
	glViewport(0, 0, w, h);
	return YES;
}

static void
fbo_free(FBO *b)
{
	if (b->f == NULL) {
		return;
	}
	b->f->bindFramebuffer(GL_FRAMEBUFFER, 0);
	b->f->deleteFramebuffers(1, &b->frame);
	b->f->deleteRenderbuffers(1, &b->color);
	if (b->depth != 0) {
		b->f->deleteRenderbuffers(1, &b->depth);
	}
	*b = (FBO){ NULL, 0, 0, 0, 0, 0 };
}

/* ES1's matrices for drawing in clip space: (near 1, far -1: z comes out as it went in, as in the shaders) */
static void
es1_setup(void)
{
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glOrthof(-1, 1, -1, 1, 1, -1);
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
}

/*
 * The frame most GL tests run in: a context of api made current, the extension it needs looked for, a w x h
 * framebuffer (depth if asked) bound, then body; afterwards the framebuffer is deleted, the context checked for an
 * error left over and let go.
 */
static void
with_fbo(Test *t, EAGLRenderingAPI api, GLsizei w, GLsizei h, GLenum depth, NSString *needs, void (^body)(FBO *b))
{
	EAGLContext *ctx = gl_begin(t, api);
	FBO b = { NULL, 0, 0, 0, 0, 0 };

	if (ctx == nil) {
		return;
	}
	if (api == ES1) {
		es1_setup();
	}
	if (needs != nil) {
		need(t, needs);
	}
	if (fbo_make(t, &b, api == ES1, w, h, depth)) {
		body(&b);
	}
	[EAGLContext setCurrentContext:ctx];
	fbo_free(&b);
	gl_end(t, ctx);
}

/* shaders: a program from two sources, its attributes where the drawing code puts them (a_pos 0, a_uv 1, a_color 2) */
static GLuint
compile_shader(GLenum kind, const char *source, NSString **log)
{
	GLuint shader = glCreateShader(kind);
	GLint ok = GL_FALSE, length = 0;
	char *text;

	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (ok) {
		return shader;
	}
	glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
	text = calloc(1, (size_t)MAX(length, 0) + 1);
	glGetShaderInfoLog(shader, length, NULL, text);
	*log = [NSString stringWithFormat:@"%s shader: %@", kind == GL_VERTEX_SHADER ? "vertex" : "fragment",
	    [[@(text) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
	    stringByReplacingOccurrencesOfString:@"\n" withString:@" / "]];
	free(text);
	glDeleteShader(shader);
	return 0;
}

static GLuint
link_program(const char *vs, const char *fs, NSString **log)
{
	GLuint vertex = compile_shader(GL_VERTEX_SHADER, vs, log), fragment, program;
	GLint ok = GL_FALSE;

	if (vertex == 0) {
		return 0;
	}
	fragment = compile_shader(GL_FRAGMENT_SHADER, fs, log);
	if (fragment == 0) {
		glDeleteShader(vertex);
		return 0;
	}
	program = glCreateProgram();
	glAttachShader(program, vertex);
	glAttachShader(program, fragment);
	glBindAttribLocation(program, 0, "a_pos");
	glBindAttribLocation(program, 1, "a_uv");
	glBindAttribLocation(program, 2, "a_color");
	glLinkProgram(program);
	glDeleteShader(vertex);
	glDeleteShader(fragment);
	glGetProgramiv(program, GL_LINK_STATUS, &ok);
	if (!ok) {
		GLint length = 0;
		char *text;

		glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
		text = calloc(1, (size_t)MAX(length, 0) + 1);
		glGetProgramInfoLog(program, length, NULL, text);
		*log = [NSString stringWithFormat:@"link: %@", [@(text) stringByReplacingOccurrencesOfString:@"\n"
		    withString:@" / "]];
		free(text);
		glDeleteProgram(program);
		return 0;
	}
	return program;
}

/* the same, failing the test with the compiler's words when it does not build */
static GLuint
program(Test *t, const char *vs, const char *fs)
{
	NSString *log = nil;
	GLuint p = link_program(vs, fs, &log);

	if (p == 0) {
		[t fail:@"the shaders do not build: %@", [log length] > 220 ? [log substringToIndex:220] : log];
	}
	return p;
}

static const char *const vs_solid_100 =
	"#version 100\n"
	"attribute vec3 a_pos;\n"
	"void main() { gl_Position = vec4(a_pos, 1.0); }\n";

static const char *const fs_solid_100 =
	"#version 100\n"
	"precision mediump float;\n"
	"uniform vec4 u_color;\n"
	"void main() { gl_FragColor = u_color; }\n";

static const char *const vs_solid_300 =
	"#version 300 es\n"
	"in vec3 a_pos;\n"
	"void main() { gl_Position = vec4(a_pos, 1.0); }\n";

static const char *const fs_solid_300 =
	"#version 300 es\n"
	"precision mediump float;\n"
	"uniform vec4 u_color;\n"
	"out vec4 o_color;\n"
	"void main() { o_color = u_color; }\n";

/* a texture over the viewport: a_pos is a corner of the quad, and the texture coordinate is derived from it */
static const char *const vs_tex =
	"#version 100\n"
	"attribute vec2 a_pos;\n"
	"varying vec2 v_uv;\n"
	"void main() { v_uv = a_pos * 0.5 + 0.5; gl_Position = vec4(a_pos, 0.0, 1.0); }\n";

static const char *const fs_tex =
	"#version 100\n"
	"precision mediump float;\n"
	"uniform sampler2D u_tex;\n"
	"varying vec2 v_uv;\n"
	"void main() { gl_FragColor = texture2D(u_tex, v_uv); }\n";

enum { SH_100, SH_300 };

static GLuint
solid_program(Test *t, int shader)
{
	return shader == SH_300 ? program(t, vs_solid_300, fs_solid_300) : program(t, vs_solid_100, fs_solid_100);
}

/* geometry, in clip space */
static const GLfloat tri_centre[9] = { -0.5f, -0.5f, 0, 0.5f, -0.5f, 0, 0, 0.6f, 0 };     /* the centre, no corner */
static const GLfloat tri_full[9] = { -1, -1, 0, 3, -1, 0, -1, 3, 0 };                     /* everything */
static const GLfloat quad[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };                            /* a strip, 2D */

static const GLfloat RED[4] = { 1, 0, 0, 1 }, GREEN[4] = { 0, 1, 0, 1 }, BLUE[4] = { 0, 0, 1, 1 };

/* the triangle tri moved to depth z */
static void
at_depth(const GLfloat *tri, GLfloat z, GLfloat out[9])
{
	for (int v = 0; v < 3; v++) {
		out[3 * v] = tri[3 * v];
		out[3 * v + 1] = tri[3 * v + 1];
		out[3 * v + 2] = z;
	}
}

/* triangles in one colour: with prog 0 through ES1's fixed function (a colour per vertex), else through prog */
static void
draw_solid(GLuint prog, const GLfloat *xyz, GLsizei count, const GLfloat rgba[4])
{
	if (prog == 0) {
		GLfloat colors[4 * 6];

		for (GLsizei v = 0; v < count && v < 6; v++) {
			memcpy(colors + 4 * v, rgba, 4 * sizeof(GLfloat));
		}
		glEnableClientState(GL_VERTEX_ARRAY);
		glEnableClientState(GL_COLOR_ARRAY);
		glVertexPointer(3, GL_FLOAT, 0, xyz);
		glColorPointer(4, GL_FLOAT, 0, colors);
		glDrawArrays(GL_TRIANGLES, 0, count);
		glDisableClientState(GL_COLOR_ARRAY);
		glDisableClientState(GL_VERTEX_ARRAY);
		return;
	}
	glUseProgram(prog);
	glUniform4fv(glGetUniformLocation(prog, "u_color"), 1, rgba);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, xyz);
	glDrawArrays(GL_TRIANGLES, 0, count);
	glDisableVertexAttribArray(0);
}

/* a texture, nearest, clamped to its edges, bound to unit 0 */
static GLuint
new_texture(GLenum min_filter)
{
	GLuint tex = 0;

	glGenTextures(1, &tex);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (GLint)min_filter);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	return tex;
}

/* the texture over the whole viewport, through prog (vs_tex and a fragment shader with u_tex) */
static void
draw_texture(GLuint prog, GLuint tex)
{
	glUseProgram(prog);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, tex);
	glUniform1i(glGetUniformLocation(prog, "u_tex"), 0);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glDisableVertexAttribArray(0);
}

/* the four quadrants -- red top left, green top right, blue bottom left, white bottom right (GL's y goes up) -- that a
   screenshot shows a flip or red and blue swapped in at once */
static void
draw_quadrants(GLint w, GLint h)
{
	static const GLfloat colors[4][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 1, 1 } };
	const GLint x[4] = { 0, w / 2, 0, w / 2 }, y[4] = { h / 2, h / 2, 0, 0 };

	glEnable(GL_SCISSOR_TEST);
	for (int q = 0; q < 4; q++) {
		glScissor(x[q], y[q], (w + 1) / 2, (h + 1) / 2);
		glClearColor(colors[q][0], colors[q][1], colors[q][2], colors[q][3]);
		glClear(GL_COLOR_BUFFER_BIT);
	}
	glDisable(GL_SCISSOR_TEST);
}

/* where to look for each quadrant, as fractions of the width and height from GL's bottom left */
static const struct quadrant {
	double x, y;
	int rgb[3];
	const char *name;
} quadrants[4] = {
	{ 0.25, 0.75, { 255, 0, 0 }, "top left" },
	{ 0.75, 0.75, { 0, 255, 0 }, "top right" },
	{ 0.25, 0.25, { 0, 0, 255 }, "bottom left" },
	{ 0.75, 0.25, { 255, 255, 255 }, "bottom right" },
};

/* reading back: a pixel of the bound framebuffer, compared with what it should be (a channel < 0: any value) */
static void
pixel(GLint x, GLint y, GLubyte p[4])
{
	p[0] = p[1] = p[2] = p[3] = 0;
	glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, p);
}

static NSString *
rgba(const GLubyte p[4])
{
	return [NSString stringWithFormat:@"(%d,%d,%d,%d)", p[0], p[1], p[2], p[3]];
}

static NSString *
want_text(const int want[4])
{
	NSMutableArray<NSString *> *parts = [NSMutableArray array];

	for (int c = 0; c < 4; c++) {
		[parts addObject:want[c] < 0 ? @"*" : [NSString stringWithFormat:@"%d", want[c]]];
	}
	return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@","]];
}

static BOOL
near_px(const GLubyte p[4], const int want[4], int tol)
{
	for (int c = 0; c < 4; c++) {
		if (want[c] >= 0 && abs((int)p[c] - want[c]) > tol) {
			return NO;
		}
	}
	return YES;
}

/* the pixel at x, y must be r, g, b, a within tol: if it is not, the test fails saying what came */
static BOOL
expect(Test *t, NSString *where, GLint x, GLint y, int r, int g, int b, int a, int tol)
{
	GLubyte p[4];
	int want[4] = { r, g, b, a };

	pixel(x, y, p);
	if (near_px(p, want, tol)) {
		return YES;
	}
	[t fail:@"%@ %@, want %@", where, rgba(p), want_text(want)];
	return NO;
}

/* images (snapshots, Core Image): a pixel at fractions of the width and height from the top left, as RGBA8 */
static BOOL
image_pixel(CGImageRef image, double fx, double fy, GLubyte p[4])
{
	size_t w = image != NULL ? CGImageGetWidth(image) : 0, h = image != NULL ? CGImageGetHeight(image) : 0, x, y;
	CGColorSpaceRef rgb;
	CGContextRef bitmap;
	GLubyte *data;

	if (w == 0 || h == 0) {
		return NO;
	}
	data = calloc(w * h, 4);
	rgb = CGColorSpaceCreateDeviceRGB();
	bitmap = CGBitmapContextCreate(data, w, h, 8, w * 4, rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(rgb);
	if (bitmap == NULL) {
		free(data);
		return NO;
	}
	CGContextDrawImage(bitmap, CGRectMake(0, 0, w, h), image);
	CGContextRelease(bitmap);
	x = MIN(w - 1, (size_t)(fx * w));
	y = MIN(h - 1, (size_t)(fy * h));
	memcpy(p, data + (y * w + x) * 4, 4);
	free(data);
	return YES;
}

static BOOL
expect_image(Test *t, NSString *where, CGImageRef image, double fx, double fy, int r, int g, int b, int tol)
{
	GLubyte p[4];
	int want[4] = { r, g, b, -1 };

	if (!image_pixel(image, fx, fy, p)) {
		[t fail:@"%@: the image has no pixels to read", where];
		return NO;
	}
	if (near_px(p, want, tol)) {
		return YES;
	}
	[t fail:@"%@ %@, want %@", where, rgba(p), want_text(want)];
	return NO;
}

/* an image the way it is shown (a snapshot may come with an orientation rather than its pixels the right way up) */
static UIImage *
upright(UIImage *image)
{
	UIGraphicsImageRendererFormat *format;

	if (image == nil || image.imageOrientation == UIImageOrientationUp) {
		return image;
	}
	format = [UIGraphicsImageRendererFormat preferredFormat];
	format.scale = image.scale;
	format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
	return [[[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format]
	    imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[image drawAtPoint:CGPointZero];
	}];
}

/* a label at the top of a full-screen test's view: which test the screenshot shows */
static UILabel *
overlay(UIView *on, UIWindow *window, NSString *text)
{
	UILabel *label = [UILabel new];
	CGFloat top = MAX(window.safeAreaInsets.top, 20);

	label.text = text;
	label.numberOfLines = 0;
	label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
	label.textColor = UIColor.whiteColor;
	label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
	label.textAlignment = NSTextAlignmentCenter;
	label.frame = CGRectMake(0, top + 4, on.bounds.size.width, 52);
	label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[on addSubview:label];
	return label;
}

/* count copies of a unit (a texel, a compressed block) */
static NSData *
repeated(const void *unit, size_t size, size_t count)
{
	NSMutableData *data = [NSMutableData dataWithLength:size * count];

	for (size_t i = 0; i < count; i++) {
		memcpy((char *)data.mutableBytes + i * size, unit, size);
	}
	return data;
}

#pragma mark contexts (ctx.*)

/* ctx.es1/2/3: the context, what GL says it is, its limits, its compressed formats, its extensions */
static void
context_test(Test *t, EAGLRenderingAPI api)
{
	EAGLContext *ctx = gl_begin(t, api);
	const char *vendor, *renderer, *version, *glsl, *list;
	GLint size = 0, renderbuffer = 0, viewport[2] = { 0, 0 }, count = 0;
	NSMutableArray<NSString *> *names = [NSMutableArray array], *formats = [NSMutableArray array];
	NSString *errors;

	if (ctx == nil) {
		return;
	}
	vendor = (const char *)glGetString(GL_VENDOR);
	renderer = (const char *)glGetString(GL_RENDERER);
	version = (const char *)glGetString(GL_VERSION);
	glsl = api == ES1 ? NULL : (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
	list = (const char *)glGetString(GL_EXTENSIONS);
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &size);
	glGetIntegerv(GL_MAX_VIEWPORT_DIMS, viewport);
	glGetIntegerv(api == ES1 ? GL_MAX_RENDERBUFFER_SIZE_OES : GL_MAX_RENDERBUFFER_SIZE, &renderbuffer);
	[t note:@"GL_VENDOR %s", vendor ?: "(NULL)"];
	[t note:@"GL_RENDERER %s", renderer ?: "(NULL)"];
	[t note:@"GL_VERSION %s", version ?: "(NULL)"];
	if (api != ES1) {
		[t note:@"GL_SHADING_LANGUAGE_VERSION %s", glsl ?: "(NULL)"];
	}
	[t note:@"GL_MAX_TEXTURE_SIZE %d, GL_MAX_RENDERBUFFER_SIZE %d, GL_MAX_VIEWPORT_DIMS %dx%d", size, renderbuffer,
	    viewport[0], viewport[1]];
	if (api == ES1) {
		GLint units = 0;

		glGetIntegerv(GL_MAX_TEXTURE_UNITS, &units);
		[t note:@"GL_MAX_TEXTURE_UNITS %d", units];
	} else {
		GLint attributes = 0, units = 0, vertexUnits = 0, samples = 0;

		glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &attributes);
		glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &units);
		glGetIntegerv(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, &vertexUnits);
		glGetIntegerv(api == ES3 ? GL_MAX_SAMPLES : GL_MAX_SAMPLES_APPLE, &samples);
		[t note:@"GL_MAX_VERTEX_ATTRIBS %d, texture units %d (vertex %d), GL_MAX_SAMPLES %d", attributes, units,
		    vertexUnits, samples];
	}
	if (api == ES3) {
		GLint major = 0, minor = 0, extensions = 0, buffers = 0;

		glGetIntegerv(GL_MAJOR_VERSION, &major);
		glGetIntegerv(GL_MINOR_VERSION, &minor);
		glGetIntegerv(GL_NUM_EXTENSIONS, &extensions);
		glGetIntegerv(GL_MAX_DRAW_BUFFERS, &buffers);
		[t note:@"GL_MAJOR/MINOR_VERSION %d.%d, GL_NUM_EXTENSIONS %d, GL_MAX_DRAW_BUFFERS %d", major, minor,
		    extensions, buffers];
	}
	glGetIntegerv(GL_NUM_COMPRESSED_TEXTURE_FORMATS, &count);
	if (count > 0 && count < 1024) {
		GLint *values = calloc((size_t)count, sizeof(GLint));

		glGetIntegerv(GL_COMPRESSED_TEXTURE_FORMATS, values);
		for (GLint i = 0; i < count; i++) {
			[formats addObject:[NSString stringWithFormat:@"0x%04x", values[i]]];
		}
		free(values);
	}
	/* (a limit this context does not know is an error, which is not what this test is about: said, then forgotten) */
	errors = gl_errors();
	if (errors != nil) {
		[t note:@"some of these queries gave %@ (a limit this context does not know)", errors];
	}
	[t note:@"GL_COMPRESSED_TEXTURE_FORMATS: %d", count];
	for (NSString *line in lines_of(formats, 200)) {
		[t note:@"  %@", line];
	}
	for (NSString *name in [@(list ?: "") componentsSeparatedByString:@" "]) {
		if (name.length > 0) {
			[names addObject:name];
		}
	}
	[t note:@"GL_EXTENSIONS: %lu", (unsigned long)names.count];
	for (NSString *line in lines_of(names, 200)) {
		[t note:@"  %@", line];
	}
	if (vendor == NULL || renderer == NULL || version == NULL) {
		[t fail:@"glGetString gave NULL (vendor %s, renderer %s, version %s)", vendor ?: "NULL", renderer ?: "NULL",
		    version ?: "NULL"];
	} else {
		[t pass:@"%s | %s | %lu extensions, max texture %d", renderer, version, (unsigned long)names.count, size];
	}
	gl_end(t, ctx);
}

static void t_ctx_es1(Test *t) { context_test(t, ES1); }
static void t_ctx_es2(Test *t) { context_test(t, ES2); }
static void t_ctx_es3(Test *t) { context_test(t, ES3); }

/*
 * ctx.sharegroup: a red texture made in one context, seen from a second made with its sharegroup -- glIsTexture, and
 * its texels through a framebuffer of the second's own -- and not from a third that shares nothing.
 */
static void
t_ctx_sharegroup(Test *t)
{
	EAGLContext *first = gl_begin(t, ES2), *second, *third;
	GLubyte red[4 * 4 * 4], p[4] = { 0, 0, 0, 0 };
	GLuint tex = 0, frame = 0;
	GLboolean seen, seenUnshared;
	GLenum status;
	NSString *errors;

	if (first == nil) {
		return;
	}
	for (int i = 0; i < 16; i++) {
		memcpy(red + 4 * i, (GLubyte[4]){ 255, 0, 0, 255 }, 4);
	}
	tex = new_texture(GL_NEAREST);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, red);
	glFlush();
	if (!gl_step(t, @"the texture, in the first context")) {
		gl_end(t, first);
		return;
	}
	second = [[EAGLContext alloc] initWithAPI:ES2 sharegroup:first.sharegroup];
	if (second == nil) {
		[t fail:@"initWithAPI:sharegroup: returned nil"];
		gl_end(t, first);
		return;
	}
	[EAGLContext setCurrentContext:second];
	seen = glIsTexture(tex);
	glGenFramebuffers(1, &frame);
	glBindFramebuffer(GL_FRAMEBUFFER, frame);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if (status == GL_FRAMEBUFFER_COMPLETE) {
		pixel(1, 1, p);
	}
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glDeleteFramebuffers(1, &frame);
	errors = gl_errors();
	third = [[EAGLContext alloc] initWithAPI:ES2];
	[EAGLContext setCurrentContext:third];
	seenUnshared = third != nil && glIsTexture(tex);
	(void)gl_errors();
	[EAGLContext setCurrentContext:first];
	glDeleteTextures(1, &tex);
	[t note:@"sharegroup %@ (the second's: %@)", first.sharegroup, second.sharegroup];
	if (errors != nil) {
		[t fail:@"in the second context: %@", errors];
	} else if (!seen) {
		[t fail:@"glIsTexture in the context sharing it: GL_FALSE"];
	} else if (status != GL_FRAMEBUFFER_COMPLETE) {
		[t fail:@"the shared texture as the second context's framebuffer: %@", fb_status_name(status)];
	} else if (!near_px(p, (int[4]){ 255, 0, 0, 255 }, 2)) {
		[t fail:@"the shared texture's texels in the second context %@, want red", rgba(p)];
	} else {
		[t pass:@"glIsTexture YES in the context sharing it, its texels red there; %@ in an unshared one",
		    seenUnshared ? @"YES (!)" : @"NO"];
	}
	gl_end(t, first);
}

#pragma mark drawing off screen (es*.fbo.*, es*.depth, es*.blend, es3.glsl300)

/* the stencil of a packed depth-stencil buffer: the triangle marks it (no colour), green then goes only where it is */
static BOOL
stencil_check(Test *t, GLuint prog)
{
	BOOL ok;

	glClearStencil(0);
	glClear(GL_STENCIL_BUFFER_BIT);
	glEnable(GL_STENCIL_TEST);
	glStencilFunc(GL_ALWAYS, 1, 0xff);
	glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
	glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
	draw_solid(prog, tri_centre, 3, RED);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glStencilFunc(GL_EQUAL, 1, 0xff);
	glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
	draw_solid(prog, tri_full, 3, GREEN);
	glDisable(GL_STENCIL_TEST);
	ok = gl_step(t, @"stencil");
	ok = expect(t, @"stencil: centre", 32, 32, 0, 255, 0, 255, 2) && ok;
	ok = expect(t, @"stencil: corner", 1, 1, 0, 0, 255, 255, 2) && ok;
	return ok;
}

/*
 * es*.fbo.*, es3.glsl300: a 64x64 framebuffer cleared blue, a red triangle over its centre (ES1: fixed function; ES2
 * and ES3: a "#version 100" shader, or "#version 300 es"): the centre must come back red, a corner blue. With a packed
 * depth-stencil buffer, its stencil too.
 */
static void
fbo_test(Test *t, EAGLRenderingAPI api, GLenum depth, int shader)
{
	NSString *needs = api == ES1 ? (depth == GL_DEPTH24_STENCIL8_OES ?
	    @"GL_OES_packed_depth_stencil" : @"GL_OES_framebuffer_object") :
	    api == ES2 && depth == GL_DEPTH24_STENCIL8_OES ? @"GL_OES_packed_depth_stencil" : nil;

	with_fbo(t, api, 64, 64, depth, needs, ^(FBO *b) {
		GLuint prog = 0;
		GLint depthBits = 0, stencilBits = 0;
		NSString *queried;
		BOOL ok;

		if (api != ES1 && (prog = solid_program(t, shader)) == 0) {
			return;
		}
		glGetIntegerv(GL_DEPTH_BITS, &depthBits);
		glGetIntegerv(GL_STENCIL_BITS, &stencilBits);
		/* (queries only, for the notes: an error from them is said, not held against the drawing) */
		queried = gl_errors();
		[t note:@"GL_DEPTH_BITS %d, GL_STENCIL_BITS %d%@", depthBits, stencilBits, queried != nil ?
		    [NSString stringWithFormat:@" (the query gave %@)", queried] : @""];
		glClearColor(0, 0, 1, 1);
		glClearDepthf(1);
		glClearStencil(0);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
		draw_solid(prog, tri_centre, 3, RED);
		ok = gl_step(t, @"clear and draw");
		ok = expect(t, @"centre", 32, 32, 255, 0, 0, 255, 2) && ok;
		ok = expect(t, @"corner", 1, 1, 0, 0, 255, 255, 2) && ok;
		if (ok && depth == GL_DEPTH24_STENCIL8_OES) {
			ok = stencil_check(t, prog);
		}
		if (ok) {
			[t pass:@"64x64 RGBA8 + %@ complete; %@: centre red, corner blue%@", depth_name(depth),
			    api == ES1 ? @"fixed function" : shader == SH_300 ? @"#version 300 es" : @"#version 100",
			    depth == GL_DEPTH24_STENCIL8_OES ? @"; stencil kept green to the triangle" : @""];
		}
		if (prog != 0) {
			glDeleteProgram(prog);
		}
	});
}

static void t_es1_fbo_d16(Test *t) { fbo_test(t, ES1, GL_DEPTH_COMPONENT16, SH_100); }
static void t_es1_fbo_d24s8(Test *t) { fbo_test(t, ES1, GL_DEPTH24_STENCIL8_OES, SH_100); }
static void t_es2_fbo_d16(Test *t) { fbo_test(t, ES2, GL_DEPTH_COMPONENT16, SH_100); }
static void t_es2_fbo_d24s8(Test *t) { fbo_test(t, ES2, GL_DEPTH24_STENCIL8_OES, SH_100); }
static void t_es3_fbo_d16(Test *t) { fbo_test(t, ES3, GL_DEPTH_COMPONENT16, SH_100); }
static void t_es3_fbo_d24s8(Test *t) { fbo_test(t, ES3, GL_DEPTH24_STENCIL8_OES, SH_100); }
static void t_es3_glsl300(Test *t) { fbo_test(t, ES3, GL_DEPTH_COMPONENT16, SH_300); }

/*
 * es*.depth: a small red triangle near, then a big blue one far behind it: with GL_LESS the centre stays red and the
 * corner, where only the far one is, turns blue. (Without the depth test the centre would come back blue.)
 */
static void
depth_test(Test *t, EAGLRenderingAPI api)
{
	with_fbo(t, api, 64, 64, GL_DEPTH_COMPONENT16, api == ES1 ? @"GL_OES_framebuffer_object" : nil, ^(FBO *b) {
		GLuint prog = 0;
		GLfloat near[9], far[9];
		BOOL ok;

		if (api != ES1 && (prog = solid_program(t, SH_100)) == 0) {
			return;
		}
		at_depth(tri_centre, -0.5f, near);
		at_depth(tri_full, 0.5f, far);
		glClearColor(0, 0, 0, 1);
		glClearDepthf(1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glEnable(GL_DEPTH_TEST);
		glDepthFunc(GL_LESS);
		draw_solid(prog, near, 3, RED);
		draw_solid(prog, far, 3, BLUE);
		glDisable(GL_DEPTH_TEST);
		ok = gl_step(t, @"depth-tested draws");
		ok = expect(t, @"centre (near red in front of far blue)", 32, 32, 255, 0, 0, 255, 2) && ok;
		ok = expect(t, @"corner (far blue only)", 1, 1, 0, 0, 255, 255, 2) && ok;
		if (ok) {
			[t pass:@"GL_LESS: the near triangle hid the far one drawn after it; the far one filled the rest"];
		}
		if (prog != 0) {
			glDeleteProgram(prog);
		}
	});
}

/* es*.blend: red at 50% alpha over blue, SRC_ALPHA / ONE_MINUS_SRC_ALPHA: (128, 0, 128), alpha 0.75 */
static void
blend_test(Test *t, EAGLRenderingAPI api)
{
	with_fbo(t, api, 64, 64, 0, api == ES1 ? @"GL_OES_framebuffer_object" : nil, ^(FBO *b) {
		static const GLfloat half_red[4] = { 1, 0, 0, 0.5f };
		GLuint prog = 0;
		BOOL ok;

		if (api != ES1 && (prog = solid_program(t, SH_100)) == 0) {
			return;
		}
		glClearColor(0, 0, 1, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		draw_solid(prog, tri_centre, 3, half_red);
		glDisable(GL_BLEND);
		ok = gl_step(t, @"blended draw");
		ok = expect(t, @"centre", 32, 32, 128, 0, 128, 191, 2) && ok;
		ok = expect(t, @"corner", 1, 1, 0, 0, 255, 255, 2) && ok;
		if (ok) {
			[t pass:@"50%% red over blue: (128,0,128), alpha 191; the corner untouched"];
		}
		if (prog != 0) {
			glDeleteProgram(prog);
		}
	});
}

static void t_es1_depth(Test *t) { depth_test(t, ES1); }
static void t_es2_depth(Test *t) { depth_test(t, ES2); }
static void t_es3_depth(Test *t) { depth_test(t, ES3); }
static void t_es1_blend(Test *t) { blend_test(t, ES1); }
static void t_es2_blend(Test *t) { blend_test(t, ES2); }
static void t_es3_blend(Test *t) { blend_test(t, ES3); }

#pragma mark texture formats (tex.*)

/* what a texture test needs: the API, the extension the format needs (NULL: core), how to upload it, what comes back */
typedef struct {
	EAGLRenderingAPI api;
	const char *needs;              /* "A|B": either */
	GLenum internal, format, type;  /* type 0: compressed, internal is its format */
	GLenum retry;                   /* not 0: the internal format tried when the first is refused */
	GLsizei w, h;
	int want[4], tol;
	const char *what;
} TexCase;

static NSString *
upload(TexCase c, GLenum internal, NSData *data)
{
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	if (c.type == 0) {
		glCompressedTexImage2D(GL_TEXTURE_2D, 0, internal, c.w, c.h, 0, (GLsizei)data.length, data.bytes);
	} else {
		glTexImage2D(GL_TEXTURE_2D, 0, (GLint)internal, c.w, c.h, 0, c.format, c.type, data.bytes);
	}
	return gl_errors();
}

/*
 * A texture of the case's format, one colour, drawn over a 32x32 framebuffer: the centre and a corner must come back
 * that colour. The upload's GL error is reported either way.
 */
static void
texture_test(Test *t, TexCase c, NSData *data)
{
	with_fbo(t, c.api, 32, 32, 0, c.needs != NULL ? @(c.needs) : nil, ^(FBO *b) {
		const char *call = c.type == 0 ? "glCompressedTexImage2D" : "glTexImage2D";
		GLuint prog = program(t, vs_tex, fs_tex), tex;
		NSString *refused;
		GLubyte p[4];
		BOOL ok;

		if (prog == 0) {
			return;
		}
		tex = new_texture(GL_NEAREST);
		refused = upload(c, c.internal, data);
		if (refused != nil && c.retry != 0) {
			[t note:@"%s with internal format 0x%04x: %@; again with 0x%04x", call, c.internal, refused, c.retry];
			refused = upload(c, c.retry, data);
		}
		[t note:@"%s %s %dx%d: %@", call, c.what, c.w, c.h, refused ?: @"GL_NO_ERROR"];
		if (refused != nil) {
			[t fail:@"%s %s: %@", call, c.what, refused];
		} else {
			glClearColor(0, 0, 0, 0);
			glClear(GL_COLOR_BUFFER_BIT);
			draw_texture(prog, tex);
			ok = gl_step(t, @"draw");
			ok = expect(t, @"centre", 16, 16, c.want[0], c.want[1], c.want[2], c.want[3], c.tol) && ok;
			ok = expect(t, @"corner", 1, 1, c.want[0], c.want[1], c.want[2], c.want[3], c.tol) && ok;
			pixel(16, 16, p);
			if (ok) {
				[t pass:@"%s %dx%d: upload GL_NO_ERROR, drawn %@ as it should", c.what, c.w, c.h, rgba(p)];
			}
		}
		glDeleteTextures(1, &tex);
		glDeleteProgram(prog);
	});
}

/* the uncompressed formats: 4x4 of one texel; the 16-bit ones in values each format holds exactly */
static void
t_tex_rgba8(Test *t)
{
	static const GLubyte texel[4] = { 200, 100, 50, 255 };

	texture_test(t, (TexCase){ ES2, NULL, GL_RGBA, GL_RGBA, GL_UNSIGNED_BYTE, 0, 4, 4, { 200, 100, 50, 255 }, 2,
	    "RGBA/UNSIGNED_BYTE" }, repeated(texel, 4, 16));
}

static void
t_tex_rgb565(Test *t)
{
	static const GLushort texel = 25 << 11 | 50 << 5 | 6;      /* 25/31, 50/63, 6/31 */

	texture_test(t, (TexCase){ ES2, NULL, GL_RGB, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, 0, 4, 4, { 206, 202, 49, 255 },
	    3, "RGB/UNSIGNED_SHORT_5_6_5" }, repeated(&texel, 2, 16));
}

static void
t_tex_rgba4444(Test *t)
{
	static const GLushort texel = 12 << 12 | 6 << 8 | 3 << 4 | 15;

	texture_test(t, (TexCase){ ES2, NULL, GL_RGBA, GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, 0, 4, 4, { 204, 102, 51, 255 },
	    3, "RGBA/UNSIGNED_SHORT_4_4_4_4" }, repeated(&texel, 2, 16));
}

static void
t_tex_rgba5551(Test *t)
{
	static const GLushort texel = 25 << 11 | 12 << 6 | 6 << 1 | 1;

	texture_test(t, (TexCase){ ES2, NULL, GL_RGBA, GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1, 0, 4, 4, { 206, 99, 49, 255 },
	    3, "RGBA/UNSIGNED_SHORT_5_5_5_1" }, repeated(&texel, 2, 16));
}

static void
t_tex_luminance(Test *t)
{
	static const GLubyte texel = 180;

	texture_test(t, (TexCase){ ES2, NULL, GL_LUMINANCE, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, 4, 4, { 180, 180, 180, 255 },
	    2, "LUMINANCE" }, repeated(&texel, 1, 16));
}

static void
t_tex_alpha(Test *t)
{
	static const GLubyte texel = 120;

	texture_test(t, (TexCase){ ES2, NULL, GL_ALPHA, GL_ALPHA, GL_UNSIGNED_BYTE, 0, 4, 4, { 0, 0, 0, 120 }, 2,
	    "ALPHA" }, repeated(&texel, 1, 16));
}

static void
t_tex_luminance_alpha(Test *t)
{
	static const GLubyte texel[2] = { 180, 120 };

	texture_test(t, (TexCase){ ES2, NULL, GL_LUMINANCE_ALPHA, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 0, 4, 4,
	    { 180, 180, 180, 120 }, 2, "LUMINANCE_ALPHA" }, repeated(texel, 2, 16));
}

/* BGRA: Apple's way (internal format RGBA, APPLE_texture_format_BGRA8888), then the EXT's (internal BGRA) if refused */
static void
t_tex_bgra8(Test *t)
{
	static const GLubyte texel[4] = { 50, 100, 200, 255 };

	texture_test(t, (TexCase){ ES2, "GL_APPLE_texture_format_BGRA8888|GL_EXT_texture_format_BGRA8888", GL_RGBA,
	    GL_BGRA_EXT, GL_UNSIGNED_BYTE, GL_BGRA_EXT, 4, 4, { 200, 100, 50, 255 }, 2, "BGRA_EXT/UNSIGNED_BYTE" },
	    repeated(texel, 4, 16));
}

static void
t_tex_half_float(Test *t)
{
	static const __fp16 texel[4] = { 0.8f, 0.4f, 0.2f, 1.0f };

	texture_test(t, (TexCase){ ES2, "GL_OES_texture_half_float", GL_RGBA, GL_RGBA, GL_HALF_FLOAT_OES, 0, 4, 4,
	    { 204, 102, 51, 255 }, 2, "RGBA/HALF_FLOAT_OES" }, repeated(texel, sizeof(texel), 16));
}

static void
t_tex_float(Test *t)
{
	static const GLfloat texel[4] = { 0.8f, 0.4f, 0.2f, 1.0f };

	texture_test(t, (TexCase){ ES2, "GL_OES_texture_float", GL_RGBA, GL_RGBA, GL_FLOAT, 0, 4, 4, { 204, 102, 51, 255 },
	    2, "RGBA/FLOAT" }, repeated(texel, sizeof(texel), 16));
}

/* tex.npot: 30x18, clamped, no mipmaps (all ES2 asks for NPOT): the left half one colour, the right another */
static void
t_tex_npot(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, nil, ^(FBO *b) {
		GLubyte texels[30 * 18 * 4];
		GLuint prog = program(t, vs_tex, fs_tex), tex;
		BOOL ok;

		if (prog == 0) {
			return;
		}
		for (int y = 0; y < 18; y++) {
			for (int x = 0; x < 30; x++) {
				memcpy(texels + 4 * (y * 30 + x), x < 15 ? (GLubyte[4]){ 200, 100, 50, 255 } :
				    (GLubyte[4]){ 50, 100, 200, 255 }, 4);
			}
		}
		tex = new_texture(GL_NEAREST);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 30, 18, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
		if (gl_step(t, @"glTexImage2D 30x18")) {
			glClearColor(0, 0, 0, 0);
			glClear(GL_COLOR_BUFFER_BIT);
			draw_texture(prog, tex);
			ok = gl_step(t, @"draw");
			ok = expect(t, @"left half", 8, 16, 200, 100, 50, 255, 2) && ok;
			ok = expect(t, @"right half", 24, 16, 50, 100, 200, 255, 2) && ok;
			if (ok) {
				[t pass:@"30x18 RGBA, CLAMP_TO_EDGE, NEAREST: both halves where they should be"];
			}
		}
		glDeleteTextures(1, &tex);
		glDeleteProgram(prog);
	});
}

/*
 * tex.mipmap: a 64x64 checkerboard of single black and white texels, glGenerateMipmap, drawn at 8x8 with
 * NEAREST_MIPMAP_NEAREST: that samples level 3, all grey. (Level 0 would give black or white; an incomplete texture
 * black.)
 */
static void
t_tex_mipmap(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, nil, ^(FBO *b) {
		GLubyte *texels = malloc(64 * 64 * 4);
		GLuint prog = program(t, vs_tex, fs_tex), tex;
		GLubyte p[4];

		if (prog == 0) {
			free(texels);
			return;
		}
		for (int y = 0; y < 64; y++) {
			for (int x = 0; x < 64; x++) {
				GLubyte v = ((x ^ y) & 1) ? 255 : 0;

				memcpy(texels + 4 * (y * 64 + x), (GLubyte[4]){ v, v, v, 255 }, 4);
			}
		}
		tex = new_texture(GL_NEAREST_MIPMAP_NEAREST);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
		free(texels);
		glGenerateMipmap(GL_TEXTURE_2D);
		if (gl_step(t, @"glGenerateMipmap")) {
			glClearColor(1, 0, 1, 1);
			glClear(GL_COLOR_BUFFER_BIT);
			glViewport(0, 0, 8, 8);
			draw_texture(prog, tex);
			glViewport(0, 0, 32, 32);
			pixel(4, 4, p);
			if (gl_step(t, @"draw") && expect(t, @"drawn at 1/8 size", 4, 4, 128, 128, 128, 255, 12)) {
				[t pass:@"glGenerateMipmap GL_NO_ERROR; the 1-texel checkerboard at 1/8 size samples level 3: %@",
				    rgba(p)];
			}
		}
		glDeleteTextures(1, &tex);
		glDeleteProgram(prog);
	});
}

/* one texture w x h of one colour, drawn and read back; its size on the list when it is right */
static BOOL
big_texture(Test *t, GLuint prog, GLint w, GLint h, const GLubyte color[4], NSMutableArray<NSString *> *list)
{
	GLubyte *texels = malloc((size_t)w * (size_t)h * 4);
	GLuint tex;
	NSString *refused;
	BOOL ok;

	if (texels == NULL) {
		[t fail:@"%dx%d: no memory for its texels", w, h];
		return NO;
	}
	memset_pattern4(texels, color, (size_t)w * (size_t)h * 4);
	tex = new_texture(GL_NEAREST);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
	free(texels);
	refused = gl_errors();
	if (refused != nil) {
		[t fail:@"glTexImage2D %dx%d RGBA: %@", w, h, refused];
		glDeleteTextures(1, &tex);
		return NO;
	}
	glClearColor(0, 0, 0, 0);
	glClear(GL_COLOR_BUFFER_BIT);
	draw_texture(prog, tex);
	ok = gl_step(t, [NSString stringWithFormat:@"drawing %dx%d", w, h]);
	ok = ok && expect(t, [NSString stringWithFormat:@"%dx%d drawn", w, h], 16, 16, color[0], color[1], color[2], 255, 2);
	glDeleteTextures(1, &tex);
	if (ok) {
		[list addObject:[NSString stringWithFormat:@"%dx%d", w, h]];
	}
	return ok;
}

/*
 * tex.max_size: GL_MAX_TEXTURE_SIZE as a width and as a height (of 4 texels the other way), a 4096x4096 (64 MB, the
 * biggest an iPhone game uploads), and one texel more than the maximum, which GL must refuse. Not the maximum
 * squared: at 16384 that is 1 GB of RGBA, which would take the phone's memory rather than test the GPU.
 */
static void
t_tex_max_size(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, nil, ^(FBO *b) {
		static const GLubyte orange[4] = { 200, 100, 50, 255 }, blue[4] = { 50, 100, 200, 255 },
		    green[4] = { 100, 200, 50, 255 };
		NSMutableArray<NSString *> *drawn = [NSMutableArray array];
		GLuint prog = program(t, vs_tex, fs_tex), tex;
		GLint max = 0, square;
		NSString *over;
		BOOL ok;

		if (prog == 0) {
			return;
		}
		glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max);
		if (max < 64) {
			[t fail:@"GL_MAX_TEXTURE_SIZE %d", max];
			glDeleteProgram(prog);
			return;
		}
		square = MIN(max, 4096);
		ok = big_texture(t, prog, max, 4, orange, drawn);
		ok = big_texture(t, prog, 4, max, blue, drawn) && ok;
		ok = big_texture(t, prog, square, square, green, drawn) && ok;
		tex = new_texture(GL_NEAREST);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, max + 1, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		over = gl_errors();
		glDeleteTextures(1, &tex);
		if (over == nil || ![over containsString:@"GL_INVALID_VALUE"]) {
			[t fail:@"%dx4 (one more than the maximum) gave %@, want GL_INVALID_VALUE", max + 1, over ?: @"no error"];
			ok = NO;
		}
		if (ok) {
			[t pass:@"GL_MAX_TEXTURE_SIZE %d: %@ drawn right; %dx4 refused (GL_INVALID_VALUE); %dx%d (%lld MB) not tried",
			    max, [drawn componentsJoinedByString:@", "], max + 1, max, max, (long long)max * max * 4 >> 20];
		}
		glDeleteProgram(prog);
	});
}

/* the compressed formats: a 32x32 texture of copies of one block, one colour */
static void
compressed_test(Test *t, EAGLRenderingAPI api, const char *needs, GLenum format, const char *what, const void *block,
    size_t size, size_t blocks, int r, int g, int b, int a, int tol)
{
	texture_test(t, (TexCase){ api, needs, format, 0, 0, 0, 32, 32, { r, g, b, a }, tol, what },
	    repeated(block, size, blocks));
}

/*
 * PVRTC 1: a 64-bit word per block (4x4 texels at 4 bpp, 8x4 at 2 bpp), the modulation first, then the colours.
 * Both colours the same opaque one -- A is RGB554 in bits 1-14 with bit 15 set, B RGB555 in bits 16-30 with bit 31
 * set -- and every modulation 0, so every texel is colour A: R 25, G 12 of 31, B 3 of 15 (6 of 31), (206, 99, 49).
 * No Adreno has PVRTC; iPhone games ship it, and call these without looking.
 */
static void
pvrtc_test(Test *t, GLenum format, int bpp, const char *what)
{
	const uint32_t word[2] = { 0, 1u << 31 | 25u << 26 | 12u << 21 | 6u << 16 | 1u << 15 | 25u << 10 | 12u << 5 |
	    3u << 1 };

	compressed_test(t, ES2, "GL_IMG_texture_compression_pvrtc", format, what, word, sizeof(word),
	    bpp == 4 ? 32 * 32 / 16 : 32 * 32 / 32, 206, 99, 49, 255, 8);
}

static void t_tex_pvrtc4_rgb(Test *t) { pvrtc_test(t, GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG, 4, "PVRTC RGB 4bpp"); }
static void t_tex_pvrtc4_rgba(Test *t) { pvrtc_test(t, GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG, 4, "PVRTC RGBA 4bpp"); }
static void t_tex_pvrtc2_rgb(Test *t) { pvrtc_test(t, GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG, 2, "PVRTC RGB 2bpp"); }
static void t_tex_pvrtc2_rgba(Test *t) { pvrtc_test(t, GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG, 2, "PVRTC RGBA 2bpp"); }

/*
 * ETC1, and ETC2's mode compatible with it: individual colours, both halves R 12 G 6 B 3 of 15 (204, 102, 51), table
 * 0, every pixel index 0 (+2): (206, 104, 53). Big-endian bits: the colours in bytes 0-2, tables and flags in 3.
 */
static const GLubyte etc_block[8] = { 0xcc, 0x66, 0x33, 0x00, 0, 0, 0, 0 };

/* ETC2 RGBA8 EAC: the alpha block first -- base 158, multiplier 1, table 0, every index 4 (+2): 160 -- then ETC2 */
static const GLubyte eac_block[16] = { 158, 0x10, 0x92, 0x49, 0x24, 0x92, 0x49, 0x24, 0xcc, 0x66, 0x33, 0x00, 0, 0, 0,
	0 };

/* ASTC 4x4: a void-extent block (one colour for the block: LDR, no extent), RGBA as UNORM16 */
static const GLubyte astc_block[16] = { 0xfc, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xce, 0xce, 0x68, 0x68, 0x35,
	0x35, 0xff, 0xff };

/* S3TC: DXT1 both endpoints 565 (25, 50, 6), every index 0; DXT5 the same after an alpha block of 160, 160, index 0 */
static const GLubyte dxt1_block[8] = { 0x46, 0xce, 0x46, 0xce, 0, 0, 0, 0 };
static const GLubyte dxt5_block[16] = { 160, 160, 0, 0, 0, 0, 0, 0, 0x46, 0xce, 0x46, 0xce, 0, 0, 0, 0 };

static void
t_tex_etc1(Test *t)
{
	compressed_test(t, ES2, "GL_OES_compressed_ETC1_RGB8_texture", GL_ETC1_RGB8_OES, "ETC1_RGB8_OES", etc_block, 8, 64,
	    206, 104, 53, 255, 3);
}

static void
t_tex_etc2_rgb(Test *t)
{
	compressed_test(t, ES3, NULL, GL_COMPRESSED_RGB8_ETC2, "COMPRESSED_RGB8_ETC2 (ES3)", etc_block, 8, 64, 206, 104,
	    53, 255, 3);
}

static void
t_tex_etc2_rgba(Test *t)
{
	compressed_test(t, ES3, NULL, GL_COMPRESSED_RGBA8_ETC2_EAC, "COMPRESSED_RGBA8_ETC2_EAC (ES3)", eac_block, 16, 64,
	    206, 104, 53, 160, 3);
}

static void
t_tex_astc(Test *t)
{
	compressed_test(t, ES2, "GL_KHR_texture_compression_astc_ldr", GL_COMPRESSED_RGBA_ASTC_4x4_KHR,
	    "COMPRESSED_RGBA_ASTC_4x4_KHR", astc_block, 16, 64, 206, 104, 53, 255, 2);
}

static void
t_tex_dxt1(Test *t)
{
	compressed_test(t, ES2, "GL_EXT_texture_compression_s3tc|GL_EXT_texture_compression_dxt1|"
	    "GL_ANGLE_texture_compression_dxt1", GL_COMPRESSED_RGB_S3TC_DXT1_EXT, "COMPRESSED_RGB_S3TC_DXT1", dxt1_block, 8,
	    64, 206, 202, 49, 255, 3);
}

static void
t_tex_dxt5(Test *t)
{
	compressed_test(t, ES2, "GL_EXT_texture_compression_s3tc|GL_ANGLE_texture_compression_dxt5",
	    GL_COMPRESSED_RGBA_S3TC_DXT5_EXT, "COMPRESSED_RGBA_S3TC_DXT5", dxt5_block, 16, 64, 206, 202, 49, 160, 3);
}

#pragma mark GL features (es2.*, es3.*)

/* es2.rtt: a 16x16 texture as a framebuffer's colour (green, a red triangle), then drawn over the 32x32 one */
static void
t_es2_rtt(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, nil, ^(FBO *b) {
		GLuint solid = solid_program(t, SH_100), textured = solid != 0 ? program(t, vs_tex, fs_tex) : 0, tex,
		    frame = 0;
		GLenum status;
		BOOL ok;

		if (textured == 0) {
			return;
		}
		tex = new_texture(GL_NEAREST);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		glGenFramebuffers(1, &frame);
		glBindFramebuffer(GL_FRAMEBUFFER, frame);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
		status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
		if (status != GL_FRAMEBUFFER_COMPLETE) {
			[t fail:@"a 16x16 RGBA texture as a framebuffer: %@", fb_status_name(status)];
		} else {
			glViewport(0, 0, 16, 16);
			glClearColor(0, 1, 0, 1);
			glClear(GL_COLOR_BUFFER_BIT);
			draw_solid(solid, tri_centre, 3, RED);
			glBindFramebuffer(GL_FRAMEBUFFER, b->frame);
			glViewport(0, 0, 32, 32);
			glClearColor(0, 0, 0, 0);
			glClear(GL_COLOR_BUFFER_BIT);
			draw_texture(textured, tex);
			ok = gl_step(t, @"render to the texture, then draw it");
			ok = expect(t, @"centre", 16, 16, 255, 0, 0, 255, 2) && ok;
			ok = expect(t, @"corner", 1, 1, 0, 255, 0, 255, 2) && ok;
			if (ok) {
				[t pass:@"drawn into a 16x16 texture, then with it: centre red, corner green"];
			}
		}
		glBindFramebuffer(GL_FRAMEBUFFER, b->frame);
		glDeleteFramebuffers(1, &frame);
		glDeleteTextures(1, &tex);
		glDeleteProgram(solid);
		glDeleteProgram(textured);
	});
}

/* es2.vao / es3.vao: the triangle's buffer and attribute kept in a vertex array, which alone then draws it */
static void
vao_test(Test *t, EAGLRenderingAPI api)
{
	BOOL es3 = api == ES3;

	with_fbo(t, api, 64, 64, 0, es3 ? nil : @"GL_OES_vertex_array_object", ^(FBO *b) {
		void (*gen)(GLsizei, GLuint *) = es3 ? glGenVertexArrays : glGenVertexArraysOES;
		void (*bind)(GLuint) = es3 ? glBindVertexArray : glBindVertexArrayOES;
		void (*del)(GLsizei, const GLuint *) = es3 ? glDeleteVertexArrays : glDeleteVertexArraysOES;
		GLboolean (*is)(GLuint) = es3 ? glIsVertexArray : glIsVertexArrayOES;
		GLuint prog = solid_program(t, SH_100), vao = 0, vbo = 0;
		GLboolean known;
		BOOL ok;

		if (prog == 0) {
			return;
		}
		glGenBuffers(1, &vbo);
		gen(1, &vao);
		bind(vao);
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(tri_centre), tri_centre, GL_STATIC_DRAW);
		glEnableVertexAttribArray(0);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, (const void *)0);
		bind(0);
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glDisableVertexAttribArray(0);
		known = is(vao);
		glClearColor(0, 0, 1, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(prog);
		glUniform4fv(glGetUniformLocation(prog, "u_color"), 1, RED);
		bind(vao);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		bind(0);
		ok = gl_step(t, @"vertex array set up and drawn");
		ok = expect(t, @"centre", 32, 32, 255, 0, 0, 255, 2) && ok;
		ok = expect(t, @"corner", 1, 1, 0, 0, 255, 255, 2) && ok;
		if (!known) {
			[t fail:@"glIsVertexArray%s: GL_FALSE for a bound one", es3 ? "" : "OES"];
		} else if (ok) {
			[t pass:@"glGen/Bind/IsVertexArray%s: the vertex array alone drew the triangle", es3 ? "" : "OES"];
		}
		del(1, &vao);
		glDeleteBuffers(1, &vbo);
		glDeleteProgram(prog);
	});
}

static void t_es2_vao(Test *t) { vao_test(t, ES2); }
static void t_es3_vao(Test *t) { vao_test(t, ES3); }

/* es2.mapbuffer: the triangle written into a buffer through glMapBufferOES, then drawn from it */
static void
t_es2_mapbuffer(Test *t)
{
	with_fbo(t, ES2, 64, 64, 0, @"GL_OES_mapbuffer", ^(FBO *b) {
		GLuint prog = solid_program(t, SH_100), vbo = 0;
		GLboolean unmapped = GL_FALSE;
		void *mapped;
		BOOL ok;

		if (prog == 0) {
			return;
		}
		glGenBuffers(1, &vbo);
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(tri_centre), NULL, GL_DYNAMIC_DRAW);
		mapped = glMapBufferOES(GL_ARRAY_BUFFER, GL_WRITE_ONLY_OES);
		if (mapped == NULL) {
			[t fail:@"glMapBufferOES returned NULL (%@)", gl_errors() ?: @"no error"];
		} else {
			memcpy(mapped, tri_centre, sizeof(tri_centre));
			unmapped = glUnmapBufferOES(GL_ARRAY_BUFFER);
			glClearColor(0, 0, 1, 1);
			glClear(GL_COLOR_BUFFER_BIT);
			glUseProgram(prog);
			glUniform4fv(glGetUniformLocation(prog, "u_color"), 1, RED);
			glEnableVertexAttribArray(0);
			glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, (const void *)0);
			glDrawArrays(GL_TRIANGLES, 0, 3);
			glDisableVertexAttribArray(0);
			ok = gl_step(t, @"map, write, unmap, draw");
			ok = expect(t, @"centre", 32, 32, 255, 0, 0, 255, 2) && ok;
			if (!unmapped) {
				[t fail:@"glUnmapBufferOES returned GL_FALSE"];
			} else if (ok) {
				[t pass:@"glMapBufferOES(GL_WRITE_ONLY_OES) gave memory; what was written there drew the triangle"];
			}
		}
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glDeleteBuffers(1, &vbo);
		glDeleteProgram(prog);
	});
}

/* es3.mapbufferrange: written through glMapBufferRange (write, invalidate), drawn, mapped again to read it back */
static void
t_es3_mapbufferrange(Test *t)
{
	with_fbo(t, ES3, 64, 64, 0, nil, ^(FBO *b) {
		GLuint prog = solid_program(t, SH_100), vbo = 0;
		void *mapped;
		BOOL ok, same = NO;

		if (prog == 0) {
			return;
		}
		glGenBuffers(1, &vbo);
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(tri_centre), NULL, GL_DYNAMIC_DRAW);
		mapped = glMapBufferRange(GL_ARRAY_BUFFER, 0, sizeof(tri_centre), GL_MAP_WRITE_BIT |
		    GL_MAP_INVALIDATE_BUFFER_BIT);
		if (mapped == NULL) {
			[t fail:@"glMapBufferRange (write) returned NULL (%@)", gl_errors() ?: @"no error"];
		} else {
			memcpy(mapped, tri_centre, sizeof(tri_centre));
			glUnmapBuffer(GL_ARRAY_BUFFER);
			glClearColor(0, 0, 1, 1);
			glClear(GL_COLOR_BUFFER_BIT);
			glUseProgram(prog);
			glUniform4fv(glGetUniformLocation(prog, "u_color"), 1, RED);
			glEnableVertexAttribArray(0);
			glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, (const void *)0);
			glDrawArrays(GL_TRIANGLES, 0, 3);
			glDisableVertexAttribArray(0);
			ok = gl_step(t, @"map, write, unmap, draw");
			ok = expect(t, @"centre", 32, 32, 255, 0, 0, 255, 2) && ok;
			mapped = glMapBufferRange(GL_ARRAY_BUFFER, 0, sizeof(tri_centre), GL_MAP_READ_BIT);
			if (mapped != NULL) {
				same = memcmp(mapped, tri_centre, sizeof(tri_centre)) == 0;
				glUnmapBuffer(GL_ARRAY_BUFFER);
			}
			ok = gl_step(t, @"map to read") && ok;
			if (mapped == NULL) {
				[t fail:@"glMapBufferRange (read) returned NULL"];
			} else if (!same) {
				[t fail:@"the buffer read back through glMapBufferRange is not what was written"];
			} else if (ok) {
				[t pass:@"written through glMapBufferRange, drawn, and read back the same"];
			}
		}
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glDeleteBuffers(1, &vbo);
		glDeleteProgram(prog);
	});
}

/* es3.instanced: one small triangle, two instances -- placed by gl_InstanceID, coloured by an attribute of divisor 1 */
static const char *const vs_instanced =
	"#version 300 es\n"
	"in vec3 a_pos;\n"
	"in vec4 a_color;\n"
	"out vec4 v_color;\n"
	"void main() {\n"
	"	float dx = gl_InstanceID == 0 ? -0.5 : 0.5;\n"
	"	gl_Position = vec4(a_pos.xy * 0.4 + vec2(dx, 0.0), 0.0, 1.0);\n"
	"	v_color = a_color;\n"
	"}\n";

static const char *const fs_varying_300 =
	"#version 300 es\n"
	"precision mediump float;\n"
	"in vec4 v_color;\n"
	"out vec4 o_color;\n"
	"void main() { o_color = v_color; }\n";

static void
t_es3_instanced(Test *t)
{
	with_fbo(t, ES3, 64, 64, 0, nil, ^(FBO *b) {
		static const GLfloat colors[8] = { 1, 0, 0, 1, 0, 1, 0, 1 };
		GLuint prog = program(t, vs_instanced, fs_varying_300);
		BOOL ok;

		if (prog == 0) {
			return;
		}
		glClearColor(0, 0, 1, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(prog);
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glEnableVertexAttribArray(0);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, tri_centre);
		glEnableVertexAttribArray(2);
		glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, 0, colors);
		glVertexAttribDivisor(2, 1);
		glDrawArraysInstanced(GL_TRIANGLES, 0, 3, 2);
		glVertexAttribDivisor(2, 0);
		glDisableVertexAttribArray(2);
		glDisableVertexAttribArray(0);
		ok = gl_step(t, @"glDrawArraysInstanced");
		ok = expect(t, @"instance 0 (left)", 16, 32, 255, 0, 0, 255, 2) && ok;
		ok = expect(t, @"instance 1 (right)", 48, 32, 0, 255, 0, 255, 2) && ok;
		ok = expect(t, @"between them", 32, 32, 0, 0, 255, 255, 2) && ok;
		if (ok) {
			[t pass:@"glDrawArraysInstanced, 2 instances: gl_InstanceID placed them, glVertexAttribDivisor coloured them"];
		}
		glDeleteProgram(prog);
	});
}

/* es3.mrt: one draw into two colour attachments (glDrawBuffers), each read back with glReadBuffer */
static const char *const fs_mrt =
	"#version 300 es\n"
	"precision mediump float;\n"
	"layout(location = 0) out vec4 o_first;\n"
	"layout(location = 1) out vec4 o_second;\n"
	"void main() { o_first = vec4(1.0, 0.0, 0.0, 1.0); o_second = vec4(0.0, 1.0, 0.0, 1.0); }\n";

static void
t_es3_mrt(Test *t)
{
	with_fbo(t, ES3, 32, 32, 0, nil, ^(FBO *b) {
		static const GLenum both[2] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
		GLuint prog = program(t, vs_solid_300, fs_mrt), second = 0;
		GLint most = 0;
		GLenum status;
		BOOL ok;

		if (prog == 0) {
			return;
		}
		glGetIntegerv(GL_MAX_DRAW_BUFFERS, &most);
		glGenRenderbuffers(1, &second);
		glBindRenderbuffer(GL_RENDERBUFFER, second);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 32, 32);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_RENDERBUFFER, second);
		status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
		if (status != GL_FRAMEBUFFER_COMPLETE) {
			[t fail:@"two colour attachments: %@", fb_status_name(status)];
		} else {
			glDrawBuffers(2, both);
			glClearColor(0, 0, 0, 0);
			glClear(GL_COLOR_BUFFER_BIT);
			draw_solid(prog, tri_full, 3, RED);
			ok = gl_step(t, @"glDrawBuffers and draw");
			glReadBuffer(GL_COLOR_ATTACHMENT0);
			ok = expect(t, @"attachment 0", 16, 16, 255, 0, 0, 255, 2) && ok;
			glReadBuffer(GL_COLOR_ATTACHMENT1);
			ok = expect(t, @"attachment 1", 16, 16, 0, 255, 0, 255, 2) && ok;
			glReadBuffer(GL_COLOR_ATTACHMENT0);
			glDrawBuffers(1, both);
			ok = gl_step(t, @"glReadBuffer") && ok;
			if (ok) {
				[t pass:@"one draw wrote red to attachment 0, green to attachment 1 (GL_MAX_DRAW_BUFFERS %d)", most];
			}
		}
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_RENDERBUFFER, 0);
		glDeleteRenderbuffers(1, &second);
		glDeleteProgram(prog);
	});
}

/*
 * es2.occlusion / es3.occlusion: ANY_SAMPLES_PASSED over a triangle in the open (true), then over one behind a
 * nearer triangle that covers everything (false), the results waited for at most a second.
 */
static void
occlusion_test(Test *t, EAGLRenderingAPI api)
{
	BOOL es3 = api == ES3;

	with_fbo(t, api, 64, 64, GL_DEPTH_COMPONENT16, es3 ? nil : @"GL_EXT_occlusion_query_boolean", ^(FBO *b) {
		void (*gen)(GLsizei, GLuint *) = es3 ? glGenQueries : glGenQueriesEXT;
		void (*begin)(GLenum, GLuint) = es3 ? glBeginQuery : glBeginQueryEXT;
		void (*finish)(GLenum) = es3 ? glEndQuery : glEndQueryEXT;
		void (*get)(GLuint, GLenum, GLuint *) = es3 ? glGetQueryObjectuiv : glGetQueryObjectuivEXT;
		void (*del)(GLsizei, const GLuint *) = es3 ? glDeleteQueries : glDeleteQueriesEXT;
		GLuint prog = solid_program(t, SH_100), q[2] = { 0, 0 }, seen[2] = { 7, 7 };
		GLfloat middle[9], cover[9], behind[9];
		CFTimeInterval start;
		BOOL ok, waited = YES;

		if (prog == 0) {
			return;
		}
		at_depth(tri_centre, 0, middle);
		at_depth(tri_full, -0.9f, cover);
		at_depth(tri_centre, 0.5f, behind);
		gen(2, q);
		glClearColor(0, 0, 0, 1);
		glClearDepthf(1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glEnable(GL_DEPTH_TEST);
		begin(GL_ANY_SAMPLES_PASSED, q[0]);
		draw_solid(prog, middle, 3, RED);
		finish(GL_ANY_SAMPLES_PASSED);
		draw_solid(prog, cover, 3, GREEN);
		begin(GL_ANY_SAMPLES_PASSED, q[1]);
		draw_solid(prog, behind, 3, BLUE);
		finish(GL_ANY_SAMPLES_PASSED);
		glDisable(GL_DEPTH_TEST);
		glFlush();
		start = CACurrentMediaTime();
		for (int k = 0; k < 2; k++) {
			GLuint ready = GL_FALSE;

			while (get(q[k], GL_QUERY_RESULT_AVAILABLE, &ready), !ready && CACurrentMediaTime() - start < 1.0) {
				usleep(1000);
			}
			waited = waited && ready;
			get(q[k], GL_QUERY_RESULT, &seen[k]);
		}
		ok = gl_step(t, @"queries");
		if (!waited) {
			[t fail:@"GL_QUERY_RESULT_AVAILABLE still false after 1 s"];
		} else if (seen[0] != GL_TRUE || seen[1] != GL_FALSE) {
			[t fail:@"ANY_SAMPLES_PASSED: %u for the visible triangle (want 1), %u for the hidden one (want 0)",
			    seen[0], seen[1]];
		} else if (ok) {
			[t pass:@"ANY_SAMPLES_PASSED: 1 for the visible triangle, 0 for the hidden one, in %.1f ms",
			    (CACurrentMediaTime() - start) * 1000];
		}
		del(2, q);
		glDeleteProgram(prog);
	});
}

static void t_es2_occlusion(Test *t) { occlusion_test(t, ES2); }
static void t_es3_occlusion(Test *t) { occlusion_test(t, ES3); }

static NSString *
sync_name(GLenum result)
{
	switch (result) {
	case GL_ALREADY_SIGNALED:
		return @"GL_ALREADY_SIGNALED";
	case GL_CONDITION_SATISFIED:
		return @"GL_CONDITION_SATISFIED";
	case GL_TIMEOUT_EXPIRED:
		return @"GL_TIMEOUT_EXPIRED";
	case GL_WAIT_FAILED:
		return @"GL_WAIT_FAILED";
	default:
		return [NSString stringWithFormat:@"0x%04x", result];
	}
}

/* es2.fence / es3.fence: a fence after a draw, glFlush, then a client wait of at most 1 s: it must signal */
static void
fence_test(Test *t, EAGLRenderingAPI api)
{
	BOOL es3 = api == ES3;

	with_fbo(t, api, 256, 256, 0, es3 ? nil : @"GL_APPLE_sync", ^(FBO *b) {
		GLsync (*fence)(GLenum, GLbitfield) = es3 ? glFenceSync : glFenceSyncAPPLE;
		GLenum (*client_wait)(GLsync, GLbitfield, GLuint64) = es3 ? glClientWaitSync : glClientWaitSyncAPPLE;
		void (*del)(GLsync) = es3 ? glDeleteSync : glDeleteSyncAPPLE;
		GLuint prog = solid_program(t, SH_100);
		CFTimeInterval start, took;
		GLenum result;
		GLsync sync;

		if (prog == 0) {
			return;
		}
		glClearColor(0, 0, 0, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		for (int i = 0; i < 10; i++) {
			draw_solid(prog, tri_full, 3, i % 2 ? RED : GREEN);
		}
		sync = fence(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
		if (sync == NULL) {
			[t fail:@"glFenceSync%s returned NULL (%@)", es3 ? "" : "APPLE", gl_errors() ?: @"no error"];
			glDeleteProgram(prog);
			return;
		}
		glFlush();
		start = CACurrentMediaTime();
		result = client_wait(sync, 0, 1000000000ull);
		took = CACurrentMediaTime() - start;
		del(sync);
		if (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) {
			[t pass:@"glClientWaitSync%s: %@ after %.2f ms", es3 ? "" : "APPLE", sync_name(result), took * 1000];
		} else {
			[t fail:@"glClientWaitSync%s: %@ after %.0f ms (want it signalled within 1 s of glFlush)",
			    es3 ? "" : "APPLE", sync_name(result), took * 1000];
		}
		(void)gl_step(t, @"fence");
		glDeleteProgram(prog);
	});
}

static void t_es2_fence(Test *t) { fence_test(t, ES2); }
static void t_es3_fence(Test *t) { fence_test(t, ES3); }

/* es2.finish: how long glFinish takes with nothing to do, and after 100 triangles over a 512x512 framebuffer */
static void
t_es2_finish(Test *t)
{
	with_fbo(t, ES2, 512, 512, 0, nil, ^(FBO *b) {
		GLuint prog = solid_program(t, SH_100);
		CFTimeInterval a, idle, submitted, busy;

		if (prog == 0) {
			return;
		}
		glFinish();
		a = CACurrentMediaTime();
		glFinish();
		idle = CACurrentMediaTime() - a;
		a = CACurrentMediaTime();
		for (int i = 0; i < 100; i++) {
			draw_solid(prog, tri_full, 3, i % 2 ? RED : BLUE);
		}
		submitted = CACurrentMediaTime() - a;
		glFinish();
		busy = CACurrentMediaTime() - a;
		if (gl_step(t, @"draws") && idle < 1 && busy < 1) {
			[t pass:@"glFinish idle %.2f ms; 100 full 512x512 triangles: submitted in %.2f ms, finished after %.2f ms",
			    idle * 1000, submitted * 1000, busy * 1000];
		} else if (idle >= 1 || busy >= 1) {
			[t fail:@"glFinish took %.0f ms idle, %.0f ms after 100 triangles", idle * 1000, busy * 1000];
		}
		glDeleteProgram(prog);
	});
}

/* es2.depth_texture: a depth texture as the depth attachment, a quad drawn at depth 0.5, then sampled: 0.5 */
static const char *const fs_depth =
	"#version 100\n"
	"precision mediump float;\n"
	"uniform sampler2D u_tex;\n"
	"varying vec2 v_uv;\n"
	"void main() { gl_FragColor = vec4(texture2D(u_tex, v_uv).r, 0.0, 0.0, 1.0); }\n";

static void
t_es2_depth_texture(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, @"GL_OES_depth_texture", ^(FBO *b) {
		GLuint solid = solid_program(t, SH_100), sampler = solid != 0 ? program(t, vs_tex, fs_depth) : 0, tex,
		    frame = 0, color = 0;
		NSString *refused;
		GLenum status;
		BOOL ok;

		if (sampler == 0) {
			return;
		}
		tex = new_texture(GL_NEAREST);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, 32, 32, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, NULL);
		refused = gl_errors();
		glGenFramebuffers(1, &frame);
		glBindFramebuffer(GL_FRAMEBUFFER, frame);
		glGenRenderbuffers(1, &color);
		glBindRenderbuffer(GL_RENDERBUFFER, color);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, 32, 32);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, tex, 0);
		status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
		if (refused != nil) {
			[t fail:@"glTexImage2D DEPTH_COMPONENT/UNSIGNED_INT: %@", refused];
		} else if (status != GL_FRAMEBUFFER_COMPLETE) {
			[t fail:@"a depth texture as the depth attachment: %@", fb_status_name(status)];
		} else {
			GLfloat middle[9];

			at_depth(tri_full, 0, middle);
			glClearDepthf(1);
			glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
			glEnable(GL_DEPTH_TEST);
			draw_solid(solid, middle, 3, GREEN);
			glDisable(GL_DEPTH_TEST);
			glBindFramebuffer(GL_FRAMEBUFFER, b->frame);
			glClearColor(0, 0, 1, 1);
			glClear(GL_COLOR_BUFFER_BIT);
			draw_texture(sampler, tex);
			ok = gl_step(t, @"depth drawn, then sampled");
			ok = expect(t, @"the depth sampled (red = depth)", 16, 16, 128, 0, 0, 255, 3) && ok;
			if (ok) {
				[t pass:@"DEPTH_COMPONENT/UNSIGNED_INT texture: written as the depth attachment, sampled back as 0.5"];
			}
		}
		glBindFramebuffer(GL_FRAMEBUFFER, b->frame);
		glDeleteFramebuffers(1, &frame);
		glDeleteRenderbuffers(1, &color);
		glDeleteTextures(1, &tex);
		glDeleteProgram(solid);
		glDeleteProgram(sampler);
	});
}

/* es2.framebuffer_fetch: a fragment shader that reads gl_LastFragData: 1 - (0.8, 0.4, 0.2, 1) = (51, 153, 204, 0) */
static const char *const fs_fetch =
	"#version 100\n"
	"#extension GL_EXT_shader_framebuffer_fetch : require\n"
	"precision mediump float;\n"
	"void main() { gl_FragColor = vec4(1.0) - gl_LastFragData[0]; }\n";

static void
t_es2_framebuffer_fetch(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, @"GL_EXT_shader_framebuffer_fetch", ^(FBO *b) {
		NSString *log = nil;
		GLuint prog = link_program(vs_solid_100, fs_fetch, &log);
		BOOL ok;

		if (prog == 0) {
			[t fail:@"a shader using gl_LastFragData does not build: %@", log];
			return;
		}
		glClearColor(0.8f, 0.4f, 0.2f, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		draw_solid(prog, tri_full, 3, RED);
		ok = gl_step(t, @"draw");
		ok = expect(t, @"1 - what was there", 16, 16, 51, 153, 204, 0, 3) && ok;
		if (ok) {
			[t pass:@"gl_LastFragData compiles and reads the framebuffer: 1 - (204,102,51,255) came out (51,153,204,0)"];
		}
		glDeleteProgram(prog);
	});
}

/* es2.derivatives: dFdx, dFdy and fwidth of a coordinate that goes from 0 to 1 over 32 pixels: 1/32 each */
static const char *const fs_derivatives =
	"#version 100\n"
	"#extension GL_OES_standard_derivatives : enable\n"
	"precision mediump float;\n"
	"varying vec2 v_uv;\n"
	"void main() { gl_FragColor = vec4(dFdx(v_uv.x) * 32.0, dFdy(v_uv.y) * 32.0, fwidth(v_uv.x) * 32.0, 1.0); }\n";

static void
t_es2_derivatives(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, @"GL_OES_standard_derivatives", ^(FBO *b) {
		NSString *log = nil;
		GLuint prog = link_program(vs_tex, fs_derivatives, &log);
		BOOL ok;

		if (prog == 0) {
			[t fail:@"a shader using dFdx/dFdy/fwidth does not build: %@", log];
			return;
		}
		glClearColor(0, 0, 0, 0);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(prog);
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glEnableVertexAttribArray(0);
		glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glDisableVertexAttribArray(0);
		ok = gl_step(t, @"draw");
		ok = expect(t, @"(dFdx, dFdy, fwidth) x 32", 16, 16, 255, 255, 255, 255, 4) && ok;
		if (ok) {
			[t pass:@"dFdx, dFdy and fwidth all 1/32 across 32 pixels, as they should"];
		}
		glDeleteProgram(prog);
	});
}

/*
 * es2.discard / es3.invalidate, off screen: drawn, the depth discarded (the colour must stay), then colour and depth
 * discarded and the next frame drawn (which must come back whole).
 */
static void
discard_test(Test *t, EAGLRenderingAPI api)
{
	BOOL es3 = api == ES3;

	with_fbo(t, api, 64, 64, GL_DEPTH_COMPONENT16, es3 ? nil : @"GL_EXT_discard_framebuffer", ^(FBO *b) {
		static const GLenum depth[1] = { GL_DEPTH_ATTACHMENT }, both[2] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
		GLuint prog = solid_program(t, SH_100);
		BOOL ok;

		if (prog == 0) {
			return;
		}
		glClearColor(0, 0, 1, 1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glEnable(GL_DEPTH_TEST);
		draw_solid(prog, tri_centre, 3, RED);
		if (es3) {
			glInvalidateFramebuffer(GL_FRAMEBUFFER, 1, depth);
		} else {
			glDiscardFramebufferEXT(GL_FRAMEBUFFER, 1, depth);
		}
		ok = gl_step(t, @"draw, discard the depth");
		ok = expect(t, @"after discarding the depth: centre", 32, 32, 255, 0, 0, 255, 2) && ok;
		ok = expect(t, @"after discarding the depth: corner", 1, 1, 0, 0, 255, 255, 2) && ok;
		if (es3) {
			glInvalidateFramebuffer(GL_FRAMEBUFFER, 2, both);
		} else {
			glDiscardFramebufferEXT(GL_FRAMEBUFFER, 2, both);
		}
		glClearColor(0, 1, 0, 1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		draw_solid(prog, tri_centre, 3, RED);
		glDisable(GL_DEPTH_TEST);
		ok = gl_step(t, @"discard colour and depth, draw again") && ok;
		ok = expect(t, @"the next frame: centre", 32, 32, 255, 0, 0, 255, 2) && ok;
		ok = expect(t, @"the next frame: corner", 1, 1, 0, 255, 0, 255, 2) && ok;
		if (ok) {
			[t pass:@"%s: the depth discarded, the colour kept; after colour and depth, the next frame whole",
			    es3 ? "glInvalidateFramebuffer" : "glDiscardFramebufferEXT"];
		}
		glDeleteProgram(prog);
	});
}

static void t_es2_discard(Test *t) { discard_test(t, ES2); }
static void t_es3_invalidate(Test *t) { discard_test(t, ES3); }

#pragma mark drawing on the screen (es*.screen*)

/* a view whose layer is a CAEAGLLayer */
@interface GLLayerView : UIView
@end

@implementation GLLayerView

+ (Class)layerClass
{
	return CAEAGLLayer.class;
}

@end

enum { SCREEN_PLAIN, SCREEN_MSAA, SCREEN_DISCARD };
enum { PRESENT_NOW, PRESENT_AT, PRESENT_AFTER };

/*
 * The on-screen tests: a full-screen CAEAGLLayer (RGBA8, not retained), its renderbuffer from
 * renderbufferStorage:fromDrawable: (which must be the bounds times contentsScale), frames presented from a
 * CADisplayLink, then the last picture left up for SHOW_SECONDS.
 *  plain:    30 frames cycling red, green, blue (frame 30 read back before it is presented), one through
 *            presentRenderbuffer:atTime:, one through afterMinimumDuration:, then the quadrants (read back).
 *  MSAA:     drawn into a 4x multisample framebuffer, resolved into the layer's (ES2: APPLE_framebuffer_multisample,
 *            ES3: glBlitFramebuffer), presented; the triangle's edges must come out mixed.
 *  discard:  every frame: the depth discarded before the present, colour and depth after it (what Minecraft does);
 *            frames 9 and 20 read back; then the quadrants, NOT read back, so the screen shows what the presents carried.
 */
@interface ScreenTest : NSObject
- (instancetype)initWithTest:(Test *)t api:(EAGLRenderingAPI)api mode:(int)mode;
- (void)start;
@end

@implementation ScreenTest {
	Test *_t;
	EAGLRenderingAPI _api;
	int _mode;
	BOOL _es1, _over;
	const FBFuncs *_f;
	EAGLContext *_ctx;
	GLLayerView *_view;
	UILabel *_label;
	CADisplayLink *_link;
	GLuint _frame, _color, _depth;          /* the framebuffer presented: its colour is the layer's */
	GLuint _msFrame, _msColor, _msDepth;    /* MSAA: where it is drawn, resolved into the one above */
	GLint _w, _h, _samples;
	GLuint _prog;
	int _n;
	unsigned _presents, _refused, _mixed;
	CFTimeInterval _firstPresent, _cyclePresent, _longest;
	NSString *_atTime, *_afterDuration, *_summary;
	NSMutableArray<NSString *> *_found;     /* what went wrong, in order */
}

- (instancetype)initWithTest:(Test *)t api:(EAGLRenderingAPI)api mode:(int)mode
{
	self = [super init];
	if (self != nil) {
		_t = t;
		_api = api;
		_mode = mode;
		_es1 = api == ES1;
		_f = _es1 ? &fb_oes : &fb_core;
		_found = [NSMutableArray array];
	}
	return self;
}

- (void)start
{
	UIWindow *window = _t.window;
	CGFloat scale = UIScreen.mainScreen.scale;
	__weak ScreenTest *weak = self;
	CAEAGLLayer *layer;
	GLint wantW, wantH;
	GLenum status;

	_t.async = YES;
	_t.helper = self;
	_t.cleanup = ^{
		[weak teardown];
	};
	if (window == nil) {
		[_t fail:@"no window to show it in"];
		[_t end];
		return;
	}
	_ctx = gl_begin(_t, _api);
	if (_ctx == nil) {
		[_t end];
		return;
	}
	if (_es1) {
		es1_setup();
	}
	if (_mode == SCREEN_MSAA && _api == ES2) {
		need(_t, @"GL_APPLE_framebuffer_multisample");
	}
	if (_mode == SCREEN_DISCARD && _api == ES2) {
		need(_t, @"GL_EXT_discard_framebuffer");
	}
	_view = [[GLLayerView alloc] initWithFrame:window.bounds];
	layer = (CAEAGLLayer *)_view.layer;
	layer.opaque = YES;
	layer.contentsScale = scale;
	layer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking: @NO,
	    kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8 };
	[window addSubview:_view];
	_label = overlay(_view, window, [NSString stringWithFormat:@"%s\nstarting", _t.ident]);

	_f->genFramebuffers(1, &_frame);
	_f->bindFramebuffer(GL_FRAMEBUFFER, _frame);
	_f->genRenderbuffers(1, &_color);
	_f->bindRenderbuffer(GL_RENDERBUFFER, _color);
	if (![_ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) {
		[_t fail:@"renderbufferStorage:fromDrawable: returned NO (%@)", gl_errors() ?: @"no GL error"];
		[self over];
		return;
	}
	_f->getRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_w);
	_f->getRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_h);
	wantW = (GLint)lround(_view.bounds.size.width * scale);
	wantH = (GLint)lround(_view.bounds.size.height * scale);
	[_t note:@"renderbufferStorage:fromDrawable: YES, %dx%d; bounds %.0fx%.0f pt x contentsScale %.0f = %dx%d", _w,
	    _h, _view.bounds.size.width, _view.bounds.size.height, scale, wantW, wantH];
	if (_w != wantW || _h != wantH) {
		[_found addObject:[NSString stringWithFormat:@"drawable %dx%d, want %dx%d", _w, _h, wantW, wantH]];
	}
	if (_w <= 0 || _h <= 0) {
		[_t fail:@"the drawable is %dx%d", _w, _h];
		[self over];
		return;
	}
	_f->framebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _color);
	_f->genRenderbuffers(1, &_depth);
	_f->bindRenderbuffer(GL_RENDERBUFFER, _depth);
	_f->renderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, _w, _h);
	_f->framebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depth);
	status = _f->checkFramebufferStatus(GL_FRAMEBUFFER);
	if (status != GL_FRAMEBUFFER_COMPLETE) {
		[_t fail:@"the layer's framebuffer (+ DEPTH_COMPONENT16): %@", fb_status_name(status)];
		[self over];
		return;
	}
	if (_mode == SCREEN_MSAA && ![self makeMultisample]) {
		[self over];
		return;
	}
	if (!_es1 && (_prog = solid_program(_t, SH_100)) == 0) {
		[self over];
		return;
	}
	if (!gl_step(_t, @"set-up")) {
		[self over];
		return;
	}
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		ScreenTest *me = weak;

		if (me != nil && me->_link != nil && !me->_over) {
			[me->_t fail:@"the display link gave only %d frames in 5 s", me->_n];
			[me over];
		}
	});
}

- (BOOL)makeMultisample
{
	GLint most = 0, given = 0;
	GLenum status;

	glGetIntegerv(_api == ES3 ? GL_MAX_SAMPLES : GL_MAX_SAMPLES_APPLE, &most);
	_samples = MIN(4, most);
	if (_samples < 2) {
		[_t fail:@"GL_MAX_SAMPLES %d: no multisampling", most];
		return NO;
	}
	glGenFramebuffers(1, &_msFrame);
	glBindFramebuffer(GL_FRAMEBUFFER, _msFrame);
	glGenRenderbuffers(1, &_msColor);
	glBindRenderbuffer(GL_RENDERBUFFER, _msColor);
	if (_api == ES3) {
		glRenderbufferStorageMultisample(GL_RENDERBUFFER, _samples, GL_RGBA8, _w, _h);
	} else {
		glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, _samples, GL_RGBA8_OES, _w, _h);
	}
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_SAMPLES, &given);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _msColor);
	glGenRenderbuffers(1, &_msDepth);
	glBindRenderbuffer(GL_RENDERBUFFER, _msDepth);
	if (_api == ES3) {
		glRenderbufferStorageMultisample(GL_RENDERBUFFER, _samples, GL_DEPTH_COMPONENT16, _w, _h);
	} else {
		glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, _samples, GL_DEPTH_COMPONENT16, _w, _h);
	}
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _msDepth);
	status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	[_t note:@"GL_MAX_SAMPLES %d; %d samples asked, the renderbuffer has %d", most, _samples, given];
	if (status != GL_FRAMEBUFFER_COMPLETE) {
		[_t fail:@"the multisample framebuffer: %@", fb_status_name(status)];
		return NO;
	}
	return gl_step(_t, @"multisample set-up");
}

/* every display link frame: the next frame of the mode's sequence */
- (void)tick:(CADisplayLink *)link
{
	if (_over || _link == nil) {
		return;
	}
	[EAGLContext setCurrentContext:_ctx];
	_n++;
	if (_mode == SCREEN_PLAIN) {
		[self plain:link];
	} else if (_mode == SCREEN_MSAA) {
		[self multisampled];
	} else {
		[self discarding];
	}
}

- (void)bind
{
	_f->bindFramebuffer(GL_FRAMEBUFFER, _frame);
	glViewport(0, 0, _w, _h);
}

- (BOOL)present:(int)how at:(CFTimeInterval)when
{
	CFTimeInterval start, took;
	BOOL ok;

	_f->bindRenderbuffer(GL_RENDERBUFFER, _color);
	start = CACurrentMediaTime();
	if (how == PRESENT_AT) {
		ok = [_ctx presentRenderbuffer:GL_RENDERBUFFER atTime:when];
	} else if (how == PRESENT_AFTER) {
		ok = [_ctx presentRenderbuffer:GL_RENDERBUFFER afterMinimumDuration:when];
	} else {
		ok = [_ctx presentRenderbuffer:GL_RENDERBUFFER];
	}
	took = CACurrentMediaTime() - start;
	_longest = MAX(_longest, took);
	_presents++;
	if (!ok) {
		_refused++;
	}
	if (_presents == 1) {
		_firstPresent = start;
	}
	if (_presents == CYCLE_FRAMES) {
		_cyclePresent = start;
	}
	return ok;
}

/* a pixel of the bound framebuffer, at fractions of its size from the bottom left: what is wrong goes on the list */
- (BOOL)probe:(NSString *)what x:(double)fx y:(double)fy r:(int)r g:(int)g b:(int)b
{
	GLubyte p[4];
	int want[4] = { r, g, b, -1 };

	pixel((GLint)(fx * _w), (GLint)(fy * _h), p);
	if (near_px(p, want, 3)) {
		return YES;
	}
	[_found addObject:[NSString stringWithFormat:@"%@ %@, want %@", what, rgba(p), want_text(want)]];
	return NO;
}

- (BOOL)probeQuadrants
{
	BOOL ok = YES;

	for (int q = 0; q < 4; q++) {
		ok = [self probe:[NSString stringWithFormat:@"quadrants: %s", quadrants[q].name] x:quadrants[q].x
		    y:quadrants[q].y r:quadrants[q].rgb[0] g:quadrants[q].rgb[1] b:quadrants[q].rgb[2]] && ok;
	}
	return ok;
}

- (void)plain:(CADisplayLink *)link
{
	static const GLfloat cycle[3][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 } };

	[self bind];
	if (_n <= CYCLE_FRAMES) {
		const GLfloat *c = cycle[(_n - 1) % 3];

		glClearColor(c[0], c[1], c[2], c[3]);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		if (_n == CYCLE_FRAMES) {
			[self probe:@"frame 30 (blue), centre" x:0.5 y:0.5 r:0 g:0 b:255];
		}
		[self present:PRESENT_NOW at:0];
	} else if (_n == CYCLE_FRAMES + 1) {
		glClearColor(1, 1, 0, 1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		if ([_ctx respondsToSelector:@selector(presentRenderbuffer:atTime:)]) {
			_atTime = [self present:PRESENT_AT at:link.targetTimestamp] ? @"YES" : @"NO";
		} else {
			_atTime = @"not there";
			[self present:PRESENT_NOW at:0];
		}
	} else if (_n == CYCLE_FRAMES + 2) {
		glClearColor(0, 1, 1, 1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		if ([_ctx respondsToSelector:@selector(presentRenderbuffer:afterMinimumDuration:)]) {
			_afterDuration = [self present:PRESENT_AFTER at:1.0 / 60] ? @"YES" : @"NO";
		} else {
			_afterDuration = @"not there";
			[self present:PRESENT_NOW at:0];
		}
	} else {
		double rate = _cyclePresent > _firstPresent ? (CYCLE_FRAMES - 1) / (_cyclePresent - _firstPresent) : 0;

		glClear(GL_DEPTH_BUFFER_BIT);
		draw_quadrants(_w, _h);
		[self probeQuadrants];
		(void)gl_step(_t, @"frames");
		[self present:PRESENT_NOW at:0];
		[self hold:[NSString stringWithFormat:@"%d presents at %.1f/s (longest call %.1f ms); atTime: %@, "
		    "afterMinimumDuration: %@; drawable %dx%d; frame 30 and the quadrants read back right", CYCLE_FRAMES, rate,
		    _longest * 1000, _atTime, _afterDuration, _w, _h] picture:@"four quadrants: red top left, green top right, "
		    "blue bottom left, white bottom right"];
	}
}

- (void)multisampled
{
	static const GLfloat orange[4] = { 1, 0.5f, 0, 1 };
	BOOL last = _n == MSAA_FRAMES;

	glBindFramebuffer(GL_FRAMEBUFFER, _msFrame);
	glViewport(0, 0, _w, _h);
	glClearColor(0.1f, 0.1f, 0.1f, 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	draw_solid(_prog, tri_centre, 3, orange);
	if (_api == ES3) {
		glBindFramebuffer(GL_READ_FRAMEBUFFER, _msFrame);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _frame);
		glBlitFramebuffer(0, 0, _w, _h, 0, 0, _w, _h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
	} else {
		glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, _msFrame);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, _frame);
		glResolveMultisampleFramebufferAPPLE();
	}
	glBindFramebuffer(GL_FRAMEBUFFER, _frame);
	if (last) {
		(void)gl_step(_t, @"draw and resolve");
		[self probe:@"resolved: centre" x:0.5 y:0.5 r:255 g:128 b:0];
		[self probe:@"resolved: corner" x:0.02 y:0.02 r:26 g:26 b:26];
		_mixed = [self edgePixels];
	}
	[self present:PRESENT_NOW at:0];
	if (last) {
		if (_mixed == 0) {
			[_found addObject:@"no pixel on the triangle's edges is a mix of orange and grey: nothing antialiased"];
		}
		[self hold:[NSString stringWithFormat:@"%d frames %d x MSAA, resolved through %@ and presented; centre and "
		    "corner right, %u mixed pixels on the edges (8 rows)", MSAA_FRAMES, _samples, _api == ES3 ?
		    @"glBlitFramebuffer" : @"glResolveMultisampleFramebufferAPPLE", _mixed]
		    picture:@"an orange triangle on dark grey, its edges antialiased"];
	}
}

/* pixels in 8 rows across the middle that are neither the background nor the triangle: the antialiased edges */
- (unsigned)edgePixels
{
	GLint rows = 8, y = _h / 2 - 4;
	GLubyte *data = malloc((size_t)_w * (size_t)rows * 4);
	unsigned mixed = 0;

	glReadPixels(0, y, _w, rows, GL_RGBA, GL_UNSIGNED_BYTE, data);
	for (GLint i = 0; i < _w * rows; i++) {
		const GLubyte *p = data + 4 * i;
		BOOL background = abs(p[0] - 26) <= 3 && abs(p[1] - 26) <= 3 && abs(p[2] - 26) <= 3;
		BOOL inside = abs(p[0] - 255) <= 3 && abs(p[1] - 128) <= 3 && p[2] <= 3;

		if (!background && !inside) {
			mixed++;
		}
	}
	free(data);
	return mixed;
}

- (void)discard:(GLsizei)count of:(const GLenum *)attachments
{
	if (_api == ES3) {
		glInvalidateFramebuffer(GL_FRAMEBUFFER, count, attachments);
	} else {
		glDiscardFramebufferEXT(GL_FRAMEBUFFER, count, attachments);
	}
}

- (void)discarding
{
	static const GLenum depth[1] = { GL_DEPTH_ATTACHMENT }, both[2] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };

	[self bind];
	if (_n <= DISCARD_FRAMES) {
		BOOL odd = _n % 2 == 1;

		glClearColor(odd ? 1 : 0, odd ? 0 : 1, 0, 1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glEnable(GL_DEPTH_TEST);
		draw_solid(_prog, tri_centre, 3, BLUE);
		glDisable(GL_DEPTH_TEST);
		[self discard:1 of:depth];          /* before the present: the depth is not needed for it */
		if (_n == 9 || _n == DISCARD_FRAMES) {
			(void)gl_step(_t, [NSString stringWithFormat:@"frame %d", _n]);
			[self probe:[NSString stringWithFormat:@"frame %d: centre", _n] x:0.5 y:0.5 r:0 g:0 b:255];
			[self probe:[NSString stringWithFormat:@"frame %d: corner", _n] x:0.02 y:0.02 r:odd ? 255 : 0
			    g:odd ? 0 : 255 b:0];
		}
		[self present:PRESENT_NOW at:0];
		[self bind];
		[self discard:2 of:both];           /* after the present: what Minecraft does every frame */
	} else {
		glClear(GL_DEPTH_BUFFER_BIT);
		draw_quadrants(_w, _h);             /* (no read-back: the screen shows what the present carried) */
		[self present:PRESENT_NOW at:0];
		[self bind];
		[self discard:2 of:both];
		(void)gl_step(_t, @"frames");
		[self hold:[NSString stringWithFormat:@"%d frames, %@ of the depth before each present and of colour + depth "
		    "after it; frames 9 and 20 read back right", DISCARD_FRAMES + 1, _api == ES3 ? @"glInvalidateFramebuffer" :
		    @"glDiscardFramebufferEXT"] picture:@"four quadrants (red, green / blue, white), presented without a "
		    "read-back: an older frame there means the discard after the present lost it"];
	}
}

/* the last picture stays up: the label says what it is, the console says it is there now */
- (void)hold:(NSString *)summary picture:(NSString *)picture
{
	__weak ScreenTest *weak = self;

	[_link invalidate];
	_link = nil;
	_summary = summary;
	_label.text = [NSString stringWithFormat:@"%s\n%u presents, %u refused", _t.ident, _presents, _refused];
	[_t note:@"on screen now for %.1f s: %@", SHOW_SECONDS, picture];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SHOW_SECONDS * NSEC_PER_SEC)), dispatch_get_main_queue(),
	    ^{
		[weak over];
	});
}

- (void)releaseGL
{
	if (_ctx == nil) {
		return;
	}
	[EAGLContext setCurrentContext:_ctx];
	_f->bindFramebuffer(GL_FRAMEBUFFER, 0);
	if (_frame != 0) {
		_f->deleteFramebuffers(1, &_frame);
	}
	if (_msFrame != 0) {
		glDeleteFramebuffers(1, &_msFrame);
	}
	if (_color != 0) {
		_f->deleteRenderbuffers(1, &_color);
	}
	if (_depth != 0) {
		_f->deleteRenderbuffers(1, &_depth);
	}
	if (_msColor != 0) {
		glDeleteRenderbuffers(1, &_msColor);
	}
	if (_msDepth != 0) {
		glDeleteRenderbuffers(1, &_msDepth);
	}
	if (_prog != 0) {
		glDeleteProgram(_prog);
	}
	gl_end(_t, _ctx);
	_ctx = nil;
}

/* the verdict: what went wrong, or the summary */
- (void)over
{
	if (_over) {
		return;
	}
	_over = YES;
	[_link invalidate];
	_link = nil;
	[self releaseGL];
	if (_refused > 0) {
		[_found addObject:[NSString stringWithFormat:@"%u of %u presentRenderbuffer: calls returned NO", _refused,
		    _presents]];
	}
	if (_found.count > 0) {
		[_t fail:@"%@", [_found componentsJoinedByString:@"; "]];
	} else {
		[_t pass:@"%@", _summary ?: @"done"];
	}
	[_t end];
}

- (void)teardown
{
	_over = YES;
	[_link invalidate];
	_link = nil;
	[self releaseGL];
	[_view removeFromSuperview];
	_view = nil;
}

@end

static void
screen_test(Test *t, EAGLRenderingAPI api, int mode)
{
	[[[ScreenTest alloc] initWithTest:t api:api mode:mode] start];
}

static void t_es1_screen(Test *t) { screen_test(t, ES1, SCREEN_PLAIN); }
static void t_es2_screen(Test *t) { screen_test(t, ES2, SCREEN_PLAIN); }
static void t_es3_screen(Test *t) { screen_test(t, ES3, SCREEN_PLAIN); }
static void t_es2_screen_msaa(Test *t) { screen_test(t, ES2, SCREEN_MSAA); }
static void t_es3_screen_msaa(Test *t) { screen_test(t, ES3, SCREEN_MSAA); }
static void t_es2_screen_discard(Test *t) { screen_test(t, ES2, SCREEN_DISCARD); }
static void t_es3_screen_invalidate(Test *t) { screen_test(t, ES3, SCREEN_DISCARD); }

#pragma mark GLKit (glkit.*)

/* glkit.view: a GLKViewController presented full screen, its GLKView's glkView:drawInRect: counted to 30 */
@interface GLKViewTest : NSObject <GLKViewDelegate>
- (instancetype)initWithTest:(Test *)t;
- (void)start;
@end

@implementation GLKViewTest {
	Test *_t;
	EAGLContext *_ctx;
	GLKViewController *_controller;
	GLKView *_view;
	NSUInteger _draws;
	CFTimeInterval _first, _last;
	GLubyte _seen[4];
	BOOL _over, _presented;
}

- (instancetype)initWithTest:(Test *)t
{
	self = [super init];
	if (self != nil) {
		_t = t;
	}
	return self;
}

- (void)start
{
	UIViewController *presenter = _t.presenter;
	__weak GLKViewTest *weak = self;

	_t.async = YES;
	_t.helper = self;
	_t.cleanup = ^{
		[weak teardown];
	};
	_ctx = gl_begin(_t, ES2);
	if (_ctx == nil || presenter == nil) {
		if (_ctx != nil) {
			[_t fail:@"nothing to present the GLKViewController from"];
		}
		[_t end];
		return;
	}
	[EAGLContext setCurrentContext:nil];
	_view = [[GLKView alloc] initWithFrame:UIScreen.mainScreen.bounds context:_ctx];
	_view.delegate = self;
	_view.drawableDepthFormat = GLKViewDrawableDepthFormat16;
	_controller = [GLKViewController new];
	_controller.view = _view;
	_controller.preferredFramesPerSecond = 60;
	_controller.modalPresentationStyle = UIModalPresentationFullScreen;
	overlay(_view, _t.window, @"glkit.view\nGLKViewController");
	[_t note:@"on screen now (about 0.5 s): GLKViewController cycling red, green, blue"];
	[presenter presentViewController:_controller animated:NO completion:nil];
	_presented = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weak finish];
	});
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
	static const GLfloat cycle[3][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 } };
	CFTimeInterval now = CACurrentMediaTime();
	const GLfloat *c;

	if (_over || _draws >= CYCLE_FRAMES) {
		return;
	}
	_draws++;
	if (_draws == 1) {
		_first = now;
	}
	_last = now;
	c = cycle[(_draws - 1) % 3];
	glClearColor(c[0], c[1], c[2], c[3]);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	if (_draws == CYCLE_FRAMES) {
		__weak GLKViewTest *weak = self;

		pixel((GLint)view.drawableWidth / 2, (GLint)view.drawableHeight / 2, _seen);
		dispatch_async(dispatch_get_main_queue(), ^{
			[weak finish];
		});
	}
}

- (void)finish
{
	CGFloat scale = _view.contentScaleFactor;
	NSInteger wantW = lround(_view.bounds.size.width * scale), wantH = lround(_view.bounds.size.height * scale);
	__weak GLKViewTest *weak = self;
	Test *t = _t;

	if (_over) {
		return;
	}
	_over = YES;
	_controller.paused = YES;
	if (_draws < CYCLE_FRAMES) {
		[t fail:@"%lu glkView:drawInRect: calls in 5 s, want %d", (unsigned long)_draws, CYCLE_FRAMES];
	} else if (_view.drawableWidth != wantW || _view.drawableHeight != wantH) {
		[t fail:@"drawable %ldx%ld, want %ldx%ld", (long)_view.drawableWidth, (long)_view.drawableHeight, (long)wantW,
		    (long)wantH];
	} else if (!near_px(_seen, (int[4]){ 0, 0, 255, -1 }, 3)) {
		[t fail:@"frame 30 read back %@, want blue", rgba(_seen)];
	} else {
		[t pass:@"%d glkView:drawInRect: calls at %.1f/s; framesDisplayed %ld; drawable %ldx%ld; frame 30 blue",
		    CYCLE_FRAMES, _last > _first ? (CYCLE_FRAMES - 1) / (_last - _first) : 0.0,
		    (long)_controller.framesDisplayed, (long)_view.drawableWidth, (long)_view.drawableHeight];
	}
	gl_end(t, _ctx);
	[_controller dismissViewControllerAnimated:NO completion:^{
		GLKViewTest *me = weak;

		if (me != nil) {
			me->_presented = NO;
		}
		[t end];
	}];
}

- (void)teardown
{
	_over = YES;
	_view.delegate = nil;
	if (_presented) {
		_presented = NO;
		[_controller dismissViewControllerAnimated:NO completion:nil];
	}
	[EAGLContext setCurrentContext:nil];
}

@end

static void
t_glkit_view(Test *t)
{
	[[[GLKViewTest alloc] initWithTest:t] start];
}

/* a GLKView's delegate that draws the quadrants */
@interface QuadrantDrawer : NSObject <GLKViewDelegate>
@end

@implementation QuadrantDrawer

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
	draw_quadrants((GLint)view.drawableWidth, (GLint)view.drawableHeight);
}

@end

/* glkit.snapshot: a GLKView drawing the quadrants, its snapshot (a UIImage) read back the way it is shown */
static void
t_glkit_snapshot(Test *t)
{
	EAGLContext *ctx = gl_begin(t, ES2);
	QuadrantDrawer *drawer = [QuadrantDrawer new];
	GLKView *view;
	UIImage *image;
	BOOL ok = YES;

	if (ctx == nil) {
		return;
	}
	view = [[GLKView alloc] initWithFrame:CGRectMake(0, 0, 120, 120) context:ctx];
	view.delegate = drawer;
	[t.window addSubview:view];
	image = upright(view.snapshot);
	[view removeFromSuperview];
	view.delegate = nil;
	if (image == nil) {
		[t fail:@"snapshot returned nil"];
	} else {
		for (int q = 0; q < 4; q++) {
			ok = expect_image(t, [NSString stringWithFormat:@"snapshot: %s", quadrants[q].name], image.CGImage,
			    quadrants[q].x, 1 - quadrants[q].y, quadrants[q].rgb[0], quadrants[q].rgb[1], quadrants[q].rgb[2], 3) &&
			    ok;
		}
		if (ok) {
			[t pass:@"snapshot %.0fx%.0f pt at scale %.0f (%zux%zu px): the quadrants the right way up",
			    image.size.width, image.size.height, image.scale, CGImageGetWidth(image.CGImage),
			    CGImageGetHeight(image.CGImage)];
		}
	}
	gl_end(t, ctx);
}

/* glkit.base_effect: GLKBaseEffect with a constant orange draws the triangle */
static void
t_glkit_base_effect(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, nil, ^(FBO *b) {
		GLKBaseEffect *effect = [GLKBaseEffect new];
		BOOL ok;

		effect.useConstantColor = GL_TRUE;
		effect.constantColor = GLKVector4Make(1, 0.5f, 0, 1);
		glClearColor(0, 0, 1, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		[effect prepareToDraw];
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glEnableVertexAttribArray(GLKVertexAttribPosition);
		glVertexAttribPointer(GLKVertexAttribPosition, 3, GL_FLOAT, GL_FALSE, 0, tri_centre);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glDisableVertexAttribArray(GLKVertexAttribPosition);
		ok = gl_step(t, @"GLKBaseEffect prepareToDraw and draw");
		ok = expect(t, @"centre", 16, 16, 255, 128, 0, 255, 2) && ok;
		ok = expect(t, @"corner", 1, 1, 0, 0, 255, 255, 2) && ok;
		if (ok) {
			[t pass:@"GLKBaseEffect (constant colour): centre orange, corner blue"];
		}
	});
}

/* a 16x16 PNG made here: the top half red, the bottom half blue */
static NSData *
two_color_png(void)
{
	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];

	format.scale = 1;
	format.opaque = YES;
	format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
	return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(16, 16) format:format]
	    PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
		[UIColor.redColor setFill];
		UIRectFill(CGRectMake(0, 0, 16, 8));
		[UIColor.blueColor setFill];
		UIRectFill(CGRectMake(0, 8, 16, 8));
	}];
}

/*
 * The loaded PNG drawn over the bound 32x32 framebuffer. GLKTextureLoader, unless told GLKTextureLoaderOriginBottomLeft,
 * puts the image's top row first (t = 0), which the quad draws at the bottom: red there, blue above.
 */
static void
check_loaded(Test *t, GLKTextureInfo *info, NSString *how)
{
	GLuint prog = program(t, vs_tex, fs_tex);
	GLubyte low[4], high[4];
	BOOL ok;

	if (prog == 0) {
		return;
	}
	glClearColor(0, 0, 0, 0);
	glClear(GL_COLOR_BUFFER_BIT);
	draw_texture(prog, info.name);
	ok = gl_step(t, @"drawing the loaded texture");
	pixel(16, 6, low);
	pixel(16, 26, high);
	if (near_px(low, (int[4]){ 255, 0, 0, 255 }, 4) && near_px(high, (int[4]){ 0, 0, 255, 255 }, 4)) {
		if (ok) {
			[t pass:@"%@: %ux%u PNG as texture %u, the image's top row at t = 0 (GLKit's default), colours right", how,
			    info.width, info.height, info.name];
		}
	} else if (near_px(low, (int[4]){ 0, 0, 255, 255 }, 4) && near_px(high, (int[4]){ 255, 0, 0, 255 }, 4)) {
		[t fail:@"%@: the image came out flipped (its top row at t = 1; GLKit's default is t = 0)", how];
	} else {
		[t fail:@"%@: drawn %@ below and %@ above, want red below and blue above", how, rgba(low), rgba(high)];
	}
	glDeleteProgram(prog);
}

/* glkit.texture_loader: GLKTextureLoader textureWithContentsOfData:, with the context current */
static void
t_glkit_texture_loader(Test *t)
{
	with_fbo(t, ES2, 32, 32, 0, nil, ^(FBO *b) {
		NSError *error = nil;
		GLKTextureInfo *info = [GLKTextureLoader textureWithContentsOfData:two_color_png() options:nil error:&error];
		GLuint name;

		if (info == nil) {
			[t fail:@"textureWithContentsOfData: nil, %@", error.localizedDescription ?: @"no error given"];
			(void)gl_errors();
			return;
		}
		glBindFramebuffer(GL_FRAMEBUFFER, b->frame);
		glViewport(0, 0, 32, 32);
		check_loaded(t, info, @"textureWithContentsOfData:");
		name = info.name;
		glDeleteTextures(1, &name);
	});
}

/* glkit.texture_loader.async: a GLKTextureLoader on the context's sharegroup, its completion on the main queue */
static void
t_glkit_texture_loader_async(Test *t)
{
	EAGLContext *ctx = gl_begin(t, ES2);
	GLKTextureLoader *loader;

	if (ctx == nil) {
		return;
	}
	t.async = YES;
	loader = [[GLKTextureLoader alloc] initWithSharegroup:ctx.sharegroup];
	[EAGLContext setCurrentContext:nil];
	t.helper = loader;
	t.cleanup = ^{
		[EAGLContext setCurrentContext:nil];
	};
	[loader textureWithContentsOfData:two_color_png() options:nil queue:dispatch_get_main_queue()
	    completionHandler:^(GLKTextureInfo *info, NSError *error) {
		FBO b = { NULL, 0, 0, 0, 0, 0 };
		GLuint name;

		if (t.ended) {
			return;
		}
		[EAGLContext setCurrentContext:ctx];
		if (info == nil) {
			[t fail:@"textureWithContentsOfData:...completionHandler: nil, %@", error.localizedDescription ?:
			    @"no error given"];
		} else if (fbo_make(t, &b, NO, 32, 32, 0)) {
			check_loaded(t, info, @"asynchronously, on the sharegroup");
			name = info.name;
			glDeleteTextures(1, &name);
		}
		fbo_free(&b);
		gl_end(t, ctx);
		[t end];
	}];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (!t.ended) {
			[t fail:@"the completion handler did not come in 5 s"];
			[t end];
		}
	});
}

#pragma mark CADisplayLink (displaylink.*)

/* a display link asking for a rate, its frames counted over a second of its own timestamps */
@interface LinkTest : NSObject
- (instancetype)initWithTest:(Test *)t fps:(NSInteger)fps range:(BOOL)range;
- (void)start;
@end

@implementation LinkTest {
	Test *_t;
	NSInteger _fps;
	BOOL _range, _over;
	CADisplayLink *_link;
	CFTimeInterval _first, _last, _duration;
	NSUInteger _frames;
}

- (instancetype)initWithTest:(Test *)t fps:(NSInteger)fps range:(BOOL)range
{
	self = [super init];
	if (self != nil) {
		_t = t;
		_fps = fps;
		_range = range;
	}
	return self;
}

- (void)start
{
	__weak LinkTest *weak = self;

	_t.async = YES;
	_t.helper = self;
	_t.cleanup = ^{
		[weak stop];
	};
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	if (_range) {
		_link.preferredFrameRateRange = CAFrameRateRangeMake((float)_fps, (float)_fps, (float)_fps);
	} else {
		_link.preferredFramesPerSecond = _fps;
	}
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weak finish];
	});
}

- (void)tick:(CADisplayLink *)link
{
	if (_first == 0) {
		_first = link.timestamp;
		return;
	}
	_frames++;
	_last = link.timestamp;
	_duration = link.duration;
	if (_last - _first >= 1.0) {
		[self finish];
	}
}

- (void)finish
{
	NSInteger most = UIScreen.mainScreen.maximumFramesPerSecond;
	double rate = _last > _first ? _frames / (_last - _first) : 0;
	double want = _fps == 0 ? 60 : MIN(_fps, most);
	NSString *asked = _range ? [NSString stringWithFormat:@"preferredFrameRateRange %ld-%ld", (long)_fps, (long)_fps] :
	    [NSString stringWithFormat:@"preferredFramesPerSecond %ld", (long)_fps];

	if (_over) {
		return;
	}
	[self stop];
	if (rate >= 0.9 * want && (_fps != 60 || rate <= 66)) {
		[_t pass:@"%@: %.1f frames/s over %.2f s (screen max %ld, link.duration %.1f ms)", asked, rate, _last - _first,
		    (long)most, _duration * 1000];
	} else {
		[_t fail:@"%@: %.1f frames/s over %.2f s, want %s%.0f (screen max %ld)", asked, rate, _last - _first,
		    _fps == 60 ? "" : "at least ", _fps == 60 ? 60 : 0.9 * want, (long)most];
	}
	[_t end];
}

- (void)stop
{
	_over = YES;
	[_link invalidate];
	_link = nil;
}

@end

static void t_link_0(Test *t) { [[[LinkTest alloc] initWithTest:t fps:0 range:NO] start]; }
static void t_link_60(Test *t) { [[[LinkTest alloc] initWithTest:t fps:60 range:NO] start]; }
static void t_link_120(Test *t) { [[[LinkTest alloc] initWithTest:t fps:120 range:NO] start]; }
static void t_link_range120(Test *t) { [[[LinkTest alloc] initWithTest:t fps:120 range:YES] start]; }

#pragma mark Core Image (coreimage.*)

/* CIColorInvert of a 16x16 red image, rendered by the context into a CGImage: cyan */
static void
core_image_test(Test *t, CIContext *ci, NSString *how)
{
	CIImage *red = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0]]
	    imageByCroppingToRect:CGRectMake(0, 0, 16, 16)];
	CIFilter *invert = [CIFilter filterWithName:@"CIColorInvert"];
	CIImage *inverted;
	CGImageRef image;

	if (ci == nil) {
		[t fail:@"%@ returned nil", how];
		return;
	}
	[t note:@"%@", [ci.description length] > 200 ? [ci.description substringToIndex:200] : ci.description];
	[invert setValue:red forKey:kCIInputImageKey];
	inverted = invert.outputImage;
	image = inverted != nil ? [ci createCGImage:inverted fromRect:CGRectMake(0, 0, 16, 16)] : NULL;
	if (invert == nil || inverted == nil) {
		[t fail:@"no CIColorInvert output"];
	} else if (image == NULL) {
		[t fail:@"createCGImage:fromRect: returned NULL"];
	} else if (expect_image(t, @"inverted red", image, 0.5, 0.5, 0, 255, 255, 3)) {
		[t pass:@"%@: CIColorInvert of red rendered cyan", how];
	}
	CGImageRelease(image);
}

static void
t_coreimage_eagl(Test *t)
{
	EAGLContext *ctx = gl_begin(t, ES2);

	if (ctx == nil) {
		return;
	}
	core_image_test(t, [CIContext contextWithEAGLContext:ctx], @"contextWithEAGLContext:");
	gl_end(t, ctx);
}

static void
t_coreimage_software(Test *t)
{
	core_image_test(t, [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }],
	    @"contextWithOptions: software renderer");
}

static void
t_coreimage_default(Test *t)
{
	core_image_test(t, [CIContext contextWithOptions:nil], @"contextWithOptions:nil (the default: Metal on an iPhone)");
}

#pragma mark Metal (metal.*)

/*
 * Metal is weakly linked and its functions looked up by name: on an iOS without it they are not there, and
 * MTLCopyAllDevices is macOS's (the iOS SDK marks it unavailable), there or not.
 */
static id<MTLDevice>
metal_device(BOOL *found)
{
	CFTypeRef (*create)(void) = (CFTypeRef (*)(void))dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");

	*found = create != NULL;
	return create != NULL ? (__bridge_transfer id<MTLDevice>)create() : nil;
}

static void
t_metal_device(Test *t)
{
	CFArrayRef (*copyAll)(void) = (CFArrayRef (*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
	NSArray *all = copyAll != NULL ? (__bridge_transfer NSArray *)copyAll() : nil;
	BOOL found;
	id<MTLDevice> device = metal_device(&found);

	[t note:@"MTLCreateSystemDefaultDevice: %@", !found ? @"not found (no Metal.framework)" : device == nil ? @"nil" :
	    device.name];
	[t note:@"MTLCopyAllDevices: %@", copyAll == NULL ? @"not exported" :
	    [NSString stringWithFormat:@"%lu device(s)", (unsigned long)all.count]];
	[t note:@"CAMetalLayer: %@", NSClassFromString(@"CAMetalLayer") != nil ? @"the class is there" : @"no such class"];
	if (device == nil) {
		[t fail:@"no Metal device (MTLCreateSystemDefaultDevice returned %@)", found ? @"nil" : @"nothing: no symbol"];
	} else {
		[t note:@"supports MTLGPUFamilyApple4 (A11): %@", [device supportsFamily:MTLGPUFamilyApple4] ? @"YES" : @"NO"];
		[t pass:@"%@", device.name];
	}
}

static NSString *const metal_add_one =
	@"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"kernel void add_one(device float *values [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
	"	values[i] = values[i] + 1.0;\n"
	"}\n";

/* metal.compute: a kernel compiled from source adds 1 to 64 floats */
static void
t_metal_compute(Test *t)
{
	BOOL found;
	id<MTLDevice> device = metal_device(&found);
	id<MTLLibrary> library;
	id<MTLFunction> function;
	id<MTLComputePipelineState> pipeline;
	id<MTLBuffer> buffer;
	id<MTLCommandQueue> queue;
	id<MTLCommandBuffer> commands;
	id<MTLComputeCommandEncoder> encoder;
	NSError *error = nil;
	float values[64];
	int wrong = 0;

	if (device == nil) {
		[t skip:@"no Metal device"];
		return;
	}
	library = [device newLibraryWithSource:metal_add_one options:nil error:&error];
	function = [library newFunctionWithName:@"add_one"];
	pipeline = function != nil ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
	if (pipeline == nil) {
		[t fail:@"the kernel does not build: %@", error.localizedDescription ?: @"no error given"];
		return;
	}
	for (int i = 0; i < 64; i++) {
		values[i] = i;
	}
	buffer = [device newBufferWithBytes:values length:sizeof(values) options:MTLResourceStorageModeShared];
	queue = [device newCommandQueue];
	commands = [queue commandBuffer];
	encoder = [commands computeCommandEncoder];
	[encoder setComputePipelineState:pipeline];
	[encoder setBuffer:buffer offset:0 atIndex:0];
	[encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[encoder endEncoding];
	[commands commit];
	[commands waitUntilCompleted];
	for (int i = 0; i < 64; i++) {
		wrong += ((float *)buffer.contents)[i] != i + 1;
	}
	if (commands.status != MTLCommandBufferStatusCompleted) {
		[t fail:@"the command buffer ended %ld: %@", (long)commands.status, commands.error.localizedDescription];
	} else if (wrong > 0) {
		[t fail:@"%d of 64 values wrong", wrong];
	} else {
		[t pass:@"add_one over 64 floats on %@: all right", device.name];
	}
}

#pragma mark SceneKit and SpriteKit (scenekit.*, spritekit.*)

static NSString *
scn_api_name(SCNRenderingAPI api)
{
	return api == SCNRenderingAPIMetal ? @"Metal" : api == SCNRenderingAPIOpenGLES2 ? @"OpenGL ES 2" :
	    [NSString stringWithFormat:@"API %lu", (unsigned long)api];
}

/*
 * scenekit.*: an SCNView over the screen, a magenta box (constant lighting: one colour whatever its angle) turning,
 * for a second; SceneKit calls renderer:updateAtTime: on its rendering thread, so the count is atomic. The snapshot
 * variant reads the box and the black around it out of -snapshot instead of counting.
 */
@interface SceneTest : NSObject <SCNSceneRendererDelegate>
- (instancetype)initWithTest:(Test *)t options:(NSDictionary *)options snapshot:(BOOL)snapshot;
- (void)start;
@end

@implementation SceneTest {
	Test *_t;
	NSDictionary *_options;
	BOOL _snapshot, _wantGL, _over;
	SCNView *_view;
	atomic_uint _updates;
	CFTimeInterval _start;
}

- (instancetype)initWithTest:(Test *)t options:(NSDictionary *)options snapshot:(BOOL)snapshot
{
	self = [super init];
	if (self != nil) {
		_t = t;
		_options = options;
		_snapshot = snapshot;
		_wantGL = options != nil;
		atomic_init(&_updates, 0);
	}
	return self;
}

- (SCNScene *)scene
{
	SCNScene *scene = [SCNScene scene];
	SCNBox *box = [SCNBox boxWithWidth:1 height:1 length:1 chamferRadius:0.05];
	SCNNode *node, *camera = [SCNNode node];

	box.firstMaterial.diffuse.contents = UIColor.magentaColor;
	box.firstMaterial.lightingModelName = SCNLightingModelConstant;
	node = [SCNNode nodeWithGeometry:box];
	[node runAction:[SCNAction repeatActionForever:[SCNAction rotateByX:0.3 y:M_PI z:0 duration:2]]];
	[scene.rootNode addChildNode:node];
	camera.camera = [SCNCamera camera];
	camera.position = SCNVector3Make(0, 0, 3);
	[scene.rootNode addChildNode:camera];
	return scene;
}

- (void)start
{
	UIWindow *window = _t.window;
	__weak SceneTest *weak = self;

	_t.async = YES;
	_t.helper = self;
	_t.cleanup = ^{
		[weak teardown];
	};
	if (NSClassFromString(@"SCNView") == nil || window == nil) {
		[_t fail:@"%@", window == nil ? @"no window to show it in" : @"no SceneKit (no SCNView class)"];
		[_t end];
		return;
	}
	_view = [[SCNView alloc] initWithFrame:window.bounds options:_options];
	_view.backgroundColor = UIColor.blackColor;
	_view.scene = [self scene];
	_view.pointOfView = [_view.scene.rootNode childNodesPassingTest:^BOOL(SCNNode *child, BOOL *stop) {
		return child.camera != nil;
	}].firstObject;
	_view.delegate = self;
	_view.rendersContinuously = YES;
	_view.showsStatistics = YES;
	[window addSubview:_view];
	overlay(_view, window, [NSString stringWithFormat:@"%s\nSCNView, %@", _t.ident, scn_api_name(_view.renderingAPI)]);
	[_t note:@"renderingAPI %@, eaglContext %@", scn_api_name(_view.renderingAPI), _view.eaglContext != nil ? @"set" :
	    @"nil"];
	[_t note:@"on screen now for 1 s: a magenta box turning on black, SceneKit's statistics at the bottom"];
	_start = CACurrentMediaTime();
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weak finish];
	});
}

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time
{
	atomic_fetch_add(&_updates, 1);
}

- (void)finish
{
	unsigned updates = atomic_load(&_updates);
	double took = CACurrentMediaTime() - _start;
	SCNRenderingAPI api = _view.renderingAPI;

	if (_over) {
		return;
	}
	_over = YES;
	if (_snapshot) {
		UIImage *image = upright([_view snapshot]);
		BOOL ok;

		if (image == nil) {
			[_t fail:@"snapshot returned nil"];
		} else {
			ok = expect_image(_t, @"snapshot: centre (the box)", image.CGImage, 0.5, 0.5, 255, 0, 255, 6);
			ok = expect_image(_t, @"snapshot: corner (black)", image.CGImage, 0.05, 0.05, 0, 0, 0, 6) && ok;
			if (ok) {
				[_t pass:@"%@ snapshot %.0fx%.0f: the magenta box in the middle, black around it", scn_api_name(api),
				    image.size.width, image.size.height];
			}
		}
	} else if (_wantGL && api != SCNRenderingAPIOpenGLES2) {
		[_t fail:@"asked for OpenGL ES 2, rendering with %@ (%u updates)", scn_api_name(api), updates];
	} else if (updates < 30) {
		[_t fail:@"%@: %u renderer:updateAtTime: calls in %.1f s", scn_api_name(api), updates, took];
	} else {
		[_t pass:@"%@: %u renderer:updateAtTime: calls in %.1f s (%.0f/s)", scn_api_name(api), updates, took,
		    updates / took];
	}
	[_t end];
}

- (void)teardown
{
	_over = YES;
	_view.delegate = nil;
	_view.rendersContinuously = NO;
	_view.scene = nil;
	[_view removeFromSuperview];
	_view = nil;
}

@end

static void
t_scenekit_gles2(Test *t)
{
	[[[SceneTest alloc] initWithTest:t options:@{ SCNPreferredRenderingAPIKey: @(SCNRenderingAPIOpenGLES2) }
	    snapshot:NO] start];
}

static void
t_scenekit_gles2_snapshot(Test *t)
{
	[[[SceneTest alloc] initWithTest:t options:@{ SCNPreferredRenderingAPIKey: @(SCNRenderingAPIOpenGLES2) }
	    snapshot:YES] start];
}

static void
t_scenekit_default(Test *t)
{
	[[[SceneTest alloc] initWithTest:t options:nil snapshot:NO] start];
}

/* a scene that counts its update: calls */
@interface CountingScene : SKScene
@property (nonatomic) NSUInteger updates;
@end

@implementation CountingScene

- (void)update:(NSTimeInterval)currentTime
{
	_updates++;
}

@end

/* spritekit.view: an SKView over the screen, an orange square turning in its scene, for a second */
@interface SpriteTest : NSObject
- (instancetype)initWithTest:(Test *)t;
- (void)start;
@end

@implementation SpriteTest {
	Test *_t;
	SKView *_view;
	CountingScene *_scene;
	CFTimeInterval _start;
	BOOL _over;
}

- (instancetype)initWithTest:(Test *)t
{
	self = [super init];
	if (self != nil) {
		_t = t;
	}
	return self;
}

- (void)start
{
	UIWindow *window = _t.window;
	__weak SpriteTest *weak = self;
	SKSpriteNode *square;

	_t.async = YES;
	_t.helper = self;
	_t.cleanup = ^{
		[weak teardown];
	};
	if (NSClassFromString(@"SKView") == nil || window == nil) {
		[_t fail:@"%@", window == nil ? @"no window to show it in" : @"no SpriteKit (no SKView class)"];
		[_t end];
		return;
	}
	_view = [[SKView alloc] initWithFrame:window.bounds];
	_view.showsFPS = YES;
	_view.showsNodeCount = YES;
	[window addSubview:_view];
	_scene = [CountingScene sceneWithSize:_view.bounds.size];
	_scene.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
	square = [SKSpriteNode spriteNodeWithColor:UIColor.orangeColor size:CGSizeMake(160, 160)];
	square.position = CGPointMake(_view.bounds.size.width / 2, _view.bounds.size.height / 2);
	[square runAction:[SKAction repeatActionForever:[SKAction rotateByAngle:M_PI duration:1]]];
	[_scene addChild:square];
	overlay(_view, window, @"spritekit.view\nSKView");
	[_t note:@"on screen now for 1 s: an orange square turning on dark grey, SpriteKit's FPS at the bottom right"];
	[_view presentScene:_scene];
	_start = CACurrentMediaTime();
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weak finish];
	});
}

- (void)finish
{
	double took = CACurrentMediaTime() - _start;
	NSUInteger updates = _scene.updates;

	if (_over) {
		return;
	}
	_over = YES;
	if (updates < 30) {
		[_t fail:@"%lu update: calls in %.1f s", (unsigned long)updates, took];
	} else {
		[_t pass:@"%lu update: calls in %.1f s (%.0f/s)", (unsigned long)updates, took, updates / took];
	}
	[_t end];
}

- (void)teardown
{
	_over = YES;
	_view.paused = YES;
	[_view presentScene:nil];
	[_view removeFromSuperview];
	_view = nil;
	_scene = nil;
}

@end

static void
t_spritekit_view(Test *t)
{
	[[[SpriteTest alloc] initWithTest:t] start];
}

/* spritekit.texture: SKView textureFromNode: renders a magenta sprite into a texture, read back from its CGImage */
static void
t_spritekit_texture(Test *t)
{
	SKView *view;
	SKScene *scene;
	SKSpriteNode *sprite;
	SKTexture *texture;
	CGImageRef image;

	if (NSClassFromString(@"SKView") == nil) {
		[t fail:@"no SpriteKit (no SKView class)"];
		return;
	}
	view = [[SKView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
	scene = [SKScene sceneWithSize:CGSizeMake(100, 100)];
	sprite = [SKSpriteNode spriteNodeWithColor:UIColor.magentaColor size:CGSizeMake(32, 32)];
	sprite.position = CGPointMake(50, 50);
	[scene addChild:sprite];
	[t.window addSubview:view];
	[view presentScene:scene];
	texture = [view textureFromNode:sprite];
	image = texture.CGImage;
	if (texture == nil) {
		[t fail:@"textureFromNode: returned nil"];
	} else if (image == NULL) {
		[t fail:@"the texture has no CGImage"];
	} else if (expect_image(t, @"the sprite's texture", image, 0.5, 0.5, 255, 0, 255, 4)) {
		[t pass:@"textureFromNode: %.0fx%.0f, magenta as drawn", texture.size.width, texture.size.height];
	}
	[view presentScene:nil];
	[view removeFromSuperview];
}

#pragma mark the tests, in the order they run

/* the groups: a section of the table each */
enum { G_CONTEXT, G_OFFSCREEN, G_TEXTURE, G_FEATURE, G_SCREEN, G_GLKIT, G_LINK, G_COREIMAGE, G_METAL, G_SCENE,
	G_COUNT };

static const struct group {
	__unsafe_unretained NSString *title, *footer;
} groups[G_COUNT] = {
	[G_CONTEXT] = { @"OpenGL ES contexts", @"EAGLContext initWithAPI: for ES 1, 2 and 3; glGetString, glGetIntegerv; "
	    "initWithAPI:sharegroup:." },
	[G_OFFSCREEN] = { @"Drawing off screen", @"64x64 framebuffers (ES1: OES_framebuffer_object), RGBA8 with a depth "
	    "renderbuffer; glReadPixels of the centre and a corner, 2 per channel either way." },
	[G_TEXTURE] = { @"Texture formats", @"Each format uploaded as one colour (ES2; ETC2 ES3), drawn over a 32x32 "
	    "framebuffer and read back. Without its extension a format is a SKIP -- but it is uploaded anyway, as games "
	    "do, and the GL error reported." },
	[G_FEATURE] = { @"GL features", @"Extensions and ES3 features engines use; every test also fails on a GL error "
	    "left at its end." },
	[G_SCREEN] = { @"Drawing on the screen", @"A full-screen CAEAGLLayer (RGBA8, retained backing NO), frames from a "
	    "CADisplayLink; the last picture stays up 1.5 s for a screenshot." },
	[G_GLKIT] = { @"GLKit", @"GLKViewController and GLKView, GLKView snapshot, GLKBaseEffect, GLKTextureLoader "
	    "(a PNG made with UIGraphicsImageRenderer)." },
	[G_LINK] = { @"CADisplayLink", @"Frames counted over one second of the link's own timestamps." },
	[G_COREIMAGE] = { @"Core Image", @"CIColorInvert of a red image through CIContext createCGImage:fromRect:." },
	[G_METAL] = { @"Metal", @"MTLCreateSystemDefaultDevice and MTLCopyAllDevices, looked up by name (Metal is weakly "
	    "linked); a compute kernel built from source." },
	[G_SCENE] = { @"SceneKit and SpriteKit", @"Last: the likeliest to take the application down where there is no "
	    "Metal. SCNView asked for OpenGL ES 2, and by default; SKView." },
};

static const struct test {
	const char *ident;
	int group;
	void (*run)(Test *t);
	const char *what;
} tests[] = {
	{ "ctx.es1", G_CONTEXT, t_ctx_es1, "ES1 context: strings, limits, extensions" },
	{ "ctx.es2", G_CONTEXT, t_ctx_es2, "ES2 context: strings, limits, compressed formats, extensions" },
	{ "ctx.es3", G_CONTEXT, t_ctx_es3, "ES3 context: strings, limits, compressed formats, extensions" },
	{ "ctx.sharegroup", G_CONTEXT, t_ctx_sharegroup, "a texture seen from a second context of the same sharegroup" },

	{ "es1.fbo.d16", G_OFFSCREEN, t_es1_fbo_d16, "ES1 fixed function, RGBA8 + DEPTH_COMPONENT16: a triangle" },
	{ "es1.fbo.d24s8", G_OFFSCREEN, t_es1_fbo_d24s8, "ES1, RGBA8 + DEPTH24_STENCIL8_OES: a triangle, the stencil" },
	{ "es1.depth", G_OFFSCREEN, t_es1_depth, "ES1 depth test: a near triangle hides a far one" },
	{ "es1.blend", G_OFFSCREEN, t_es1_blend, "ES1 blending: 50% red over blue" },
	{ "es2.fbo.d16", G_OFFSCREEN, t_es2_fbo_d16, "ES2 #version 100, RGBA8 + DEPTH_COMPONENT16: a triangle" },
	{ "es2.fbo.d24s8", G_OFFSCREEN, t_es2_fbo_d24s8, "ES2, RGBA8 + DEPTH24_STENCIL8_OES: a triangle, the stencil" },
	{ "es2.depth", G_OFFSCREEN, t_es2_depth, "ES2 depth test" },
	{ "es2.blend", G_OFFSCREEN, t_es2_blend, "ES2 blending" },
	{ "es3.fbo.d16", G_OFFSCREEN, t_es3_fbo_d16, "ES3 #version 100, RGBA8 + DEPTH_COMPONENT16: a triangle" },
	{ "es3.fbo.d24s8", G_OFFSCREEN, t_es3_fbo_d24s8, "ES3, RGBA8 + DEPTH24_STENCIL8: a triangle, the stencil" },
	{ "es3.glsl300", G_OFFSCREEN, t_es3_glsl300, "ES3 #version 300 es shaders: a triangle" },
	{ "es3.depth", G_OFFSCREEN, t_es3_depth, "ES3 depth test" },
	{ "es3.blend", G_OFFSCREEN, t_es3_blend, "ES3 blending" },

	{ "tex.rgba8", G_TEXTURE, t_tex_rgba8, "RGBA / UNSIGNED_BYTE" },
	{ "tex.rgb565", G_TEXTURE, t_tex_rgb565, "RGB / UNSIGNED_SHORT_5_6_5" },
	{ "tex.rgba4444", G_TEXTURE, t_tex_rgba4444, "RGBA / UNSIGNED_SHORT_4_4_4_4" },
	{ "tex.rgba5551", G_TEXTURE, t_tex_rgba5551, "RGBA / UNSIGNED_SHORT_5_5_5_1" },
	{ "tex.luminance", G_TEXTURE, t_tex_luminance, "LUMINANCE" },
	{ "tex.alpha", G_TEXTURE, t_tex_alpha, "ALPHA" },
	{ "tex.luminance_alpha", G_TEXTURE, t_tex_luminance_alpha, "LUMINANCE_ALPHA" },
	{ "tex.bgra8", G_TEXTURE, t_tex_bgra8, "BGRA_EXT (APPLE_texture_format_BGRA8888)" },
	{ "tex.half_float", G_TEXTURE, t_tex_half_float, "RGBA / HALF_FLOAT_OES (OES_texture_half_float)" },
	{ "tex.float", G_TEXTURE, t_tex_float, "RGBA / FLOAT (OES_texture_float)" },
	{ "tex.npot", G_TEXTURE, t_tex_npot, "30x18, CLAMP_TO_EDGE, no mipmaps" },
	{ "tex.mipmap", G_TEXTURE, t_tex_mipmap, "glGenerateMipmap: a checkerboard at 1/8 size turns grey" },
	{ "tex.max_size", G_TEXTURE, t_tex_max_size, "GL_MAX_TEXTURE_SIZE wide and tall, 4096x4096, one over refused" },
	{ "tex.pvrtc4.rgb", G_TEXTURE, t_tex_pvrtc4_rgb, "PVRTC RGB 4bpp (IMG_texture_compression_pvrtc)" },
	{ "tex.pvrtc4.rgba", G_TEXTURE, t_tex_pvrtc4_rgba, "PVRTC RGBA 4bpp" },
	{ "tex.pvrtc2.rgb", G_TEXTURE, t_tex_pvrtc2_rgb, "PVRTC RGB 2bpp" },
	{ "tex.pvrtc2.rgba", G_TEXTURE, t_tex_pvrtc2_rgba, "PVRTC RGBA 2bpp" },
	{ "tex.etc1", G_TEXTURE, t_tex_etc1, "ETC1 (OES_compressed_ETC1_RGB8_texture)" },
	{ "tex.etc2.rgb", G_TEXTURE, t_tex_etc2_rgb, "ETC2 RGB8 (ES3 core)" },
	{ "tex.etc2.rgba_eac", G_TEXTURE, t_tex_etc2_rgba, "ETC2 RGBA8 EAC (ES3 core)" },
	{ "tex.astc4x4", G_TEXTURE, t_tex_astc, "ASTC 4x4 LDR (KHR_texture_compression_astc_ldr)" },
	{ "tex.dxt1", G_TEXTURE, t_tex_dxt1, "S3TC DXT1 (EXT_texture_compression_s3tc / dxt1)" },
	{ "tex.dxt5", G_TEXTURE, t_tex_dxt5, "S3TC DXT5 (EXT_texture_compression_s3tc)" },

	{ "es2.rtt", G_FEATURE, t_es2_rtt, "render to a texture, then draw with it" },
	{ "es2.vao", G_FEATURE, t_es2_vao, "OES_vertex_array_object" },
	{ "es3.vao", G_FEATURE, t_es3_vao, "ES3 vertex array objects" },
	{ "es2.mapbuffer", G_FEATURE, t_es2_mapbuffer, "OES_mapbuffer: glMapBufferOES" },
	{ "es3.mapbufferrange", G_FEATURE, t_es3_mapbufferrange, "ES3 glMapBufferRange, write then read" },
	{ "es3.instanced", G_FEATURE, t_es3_instanced, "ES3 glDrawArraysInstanced, glVertexAttribDivisor" },
	{ "es3.mrt", G_FEATURE, t_es3_mrt, "ES3 two colour attachments: glDrawBuffers, glReadBuffer" },
	{ "es2.occlusion", G_FEATURE, t_es2_occlusion, "EXT_occlusion_query_boolean" },
	{ "es3.occlusion", G_FEATURE, t_es3_occlusion, "ES3 ANY_SAMPLES_PASSED queries" },
	{ "es2.fence", G_FEATURE, t_es2_fence, "APPLE_sync: signalled within 1 s of glFlush" },
	{ "es3.fence", G_FEATURE, t_es3_fence, "ES3 glFenceSync / glClientWaitSync" },
	{ "es2.finish", G_FEATURE, t_es2_finish, "glFinish timing" },
	{ "es2.depth_texture", G_FEATURE, t_es2_depth_texture, "OES_depth_texture: written, then sampled" },
	{ "es2.framebuffer_fetch", G_FEATURE, t_es2_framebuffer_fetch, "EXT_shader_framebuffer_fetch: gl_LastFragData" },
	{ "es2.derivatives", G_FEATURE, t_es2_derivatives, "OES_standard_derivatives: dFdx, dFdy, fwidth" },
	{ "es2.discard", G_FEATURE, t_es2_discard, "EXT_discard_framebuffer, off screen" },
	{ "es3.invalidate", G_FEATURE, t_es3_invalidate, "ES3 glInvalidateFramebuffer, off screen" },

	{ "es1.screen", G_SCREEN, t_es1_screen, "ES1 CAEAGLLayer: 30 presents, atTime:, afterMinimumDuration:" },
	{ "es2.screen", G_SCREEN, t_es2_screen, "ES2 CAEAGLLayer: 30 presents, atTime:, afterMinimumDuration:" },
	{ "es3.screen", G_SCREEN, t_es3_screen, "ES3 CAEAGLLayer: 30 presents, atTime:, afterMinimumDuration:" },
	{ "es2.screen.msaa", G_SCREEN, t_es2_screen_msaa, "ES2 4x MSAA (APPLE_framebuffer_multisample), presented" },
	{ "es3.screen.msaa", G_SCREEN, t_es3_screen_msaa, "ES3 4x MSAA resolved by glBlitFramebuffer, presented" },
	{ "es2.screen.discard", G_SCREEN, t_es2_screen_discard, "ES2 glDiscardFramebufferEXT before and after presents" },
	{ "es3.screen.invalidate", G_SCREEN, t_es3_screen_invalidate, "ES3 glInvalidateFramebuffer before and after "
	    "presents" },

	{ "glkit.view", G_GLKIT, t_glkit_view, "GLKViewController + GLKView: 30 glkView:drawInRect:" },
	{ "glkit.snapshot", G_GLKIT, t_glkit_snapshot, "GLKView snapshot" },
	{ "glkit.base_effect", G_GLKIT, t_glkit_base_effect, "GLKBaseEffect draws a triangle" },
	{ "glkit.texture_loader", G_GLKIT, t_glkit_texture_loader, "GLKTextureLoader loads a PNG" },
	{ "glkit.texture_loader.async", G_GLKIT, t_glkit_texture_loader_async, "GLKTextureLoader on a sharegroup, "
	    "asynchronously" },

	{ "displaylink.0", G_LINK, t_link_0, "preferredFramesPerSecond 0 (the default)" },
	{ "displaylink.60", G_LINK, t_link_60, "preferredFramesPerSecond 60" },
	{ "displaylink.120", G_LINK, t_link_120, "preferredFramesPerSecond 120" },
	{ "displaylink.range120", G_LINK, t_link_range120, "preferredFrameRateRange 120-120" },

	{ "coreimage.eagl", G_COREIMAGE, t_coreimage_eagl, "CIContext contextWithEAGLContext:" },
	{ "coreimage.software", G_COREIMAGE, t_coreimage_software, "CIContext with kCIContextUseSoftwareRenderer" },
	{ "coreimage.default", G_COREIMAGE, t_coreimage_default, "CIContext contextWithOptions:nil" },

	{ "metal.device", G_METAL, t_metal_device, "MTLCreateSystemDefaultDevice, MTLCopyAllDevices" },
	{ "metal.compute", G_METAL, t_metal_compute, "a compute kernel adding 1 to 64 floats" },

	{ "scenekit.gles2", G_SCENE, t_scenekit_gles2, "SCNView asked for OpenGL ES 2: a box for 1 s" },
	{ "scenekit.gles2.snapshot", G_SCENE, t_scenekit_gles2_snapshot, "SCNView (OpenGL ES 2) snapshot" },
	{ "spritekit.view", G_SCENE, t_spritekit_view, "SKView: a sprite for 1 s, update: counted" },
	{ "spritekit.texture", G_SCENE, t_spritekit_texture, "SKView textureFromNode:" },
	{ "scenekit.default", G_SCENE, t_scenekit_default, "SCNView by default (Metal on an iPhone): a box for 1 s" },
};
#define TEST_COUNT ((int)(sizeof(tests) / sizeof(tests[0])))

static int
test_index(NSString *ident)
{
	for (int i = 0; i < TEST_COUNT; i++) {
		if (strcmp(tests[i].ident, ident.UTF8String) == 0) {
			return i;
		}
	}
	return -1;
}

#pragma mark crashes and hangs

/*
 * What is running, for the signal handler and the watchdog: the test's index (-1: none), when it started, and which
 * test the watchdog has already called hung. The handler only writes and fsyncs (both safe in a signal handler) to
 * descriptors opened before, then lets the signal take the application down as it would have.
 */
static atomic_int g_running = -1, g_hung = -1;
static _Atomic double g_started;

static const char *
signal_name(int signal)
{
	switch (signal) {
	case SIGSEGV:
		return "SIGSEGV";
	case SIGBUS:
		return "SIGBUS";
	case SIGILL:
		return "SIGILL";
	case SIGFPE:
		return "SIGFPE";
	case SIGABRT:
		return "SIGABRT";
	case SIGTRAP:
		return "SIGTRAP";
	case SIGSYS:
		return "SIGSYS";
	default:
		return "a signal";
	}
}

static void
put(char *line, size_t *at, size_t size, const char *s)
{
	while (*s != '\0' && *at < size - 1) {
		line[(*at)++] = *s++;
	}
}

/* (called by the process's handler, main.m's, which then lets the signal take the application down) */
static void
crash_signal(int signal)
{
	int i = atomic_load(&g_running);
	char line[256];
	size_t n = 0;

	if (i >= 0 && i < TEST_COUNT) {
		put(line, &n, sizeof(line), "crashed\t");
		put(line, &n, sizeof(line), tests[i].ident);
		put(line, &n, sizeof(line), "\t");
		put(line, &n, sizeof(line), signal_name(signal));
		put(line, &n, sizeof(line), "\n");
		if (g_log >= 0) {
			(void)write(g_log, line, n);
			(void)fsync(g_log);
		}
		n = 0;
		put(line, &n, sizeof(line), "gpucheck: ");
		put(line, &n, sizeof(line), tests[i].ident);
		put(line, &n, sizeof(line), " CRASHED ");
		put(line, &n, sizeof(line), signal_name(signal));
		put(line, &n, sizeof(line), " (the next launch marks it and goes on)\n");
		if (g_console >= 0) {
			(void)write(g_console, line, n);
		}
	}
}

static void
crash_exception(NSException *exception)
{
	int i = atomic_load(&g_running);
	NSString *what;

	if (i < 0 || i >= TEST_COUNT) {
		return;
	}
	what = [NSString stringWithFormat:@"exception %@: %@", exception.name, exception.reason];
	if (what.length > 200) {
		what = [[what substringToIndex:200] stringByAppendingString:@"..."];
	}
	record("crashed", tests[i].ident, NULL, what);
	say(@"%s CRASHED %@ (the next launch marks it and goes on)", tests[i].ident, what);
}

static void
watch_for_crashes(void)
{
	check_watch_crashes(crash_signal, crash_exception);
}

/* the watchdog, on a queue of its own: a test that has run HANG_SECONDS is hung (written down at once: nothing on
   the main thread may ever run again) */
static void
watch_for_hangs(void)
{
	static dispatch_source_t timer;

	timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,
	    0));
	dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(timer, ^{
		int i = atomic_load(&g_running);

		if (i < 0 || i >= TEST_COUNT || atomic_load(&g_hung) == i ||
		    CACurrentMediaTime() - atomic_load(&g_started) <= HANG_SECONDS) {
			return;
		}
		atomic_store(&g_hung, i);
		record("hung", tests[i].ident, NULL, [NSString stringWithFormat:@"still running after %.0f s", HANG_SECONDS]);
		say(@"%s HUNG still running after %.0f s (kill the app: the next launch marks it and goes on)", tests[i].ident,
		    HANG_SECONDS);
	});
	dispatch_resume(timer);
}

#pragma mark the table

/* A row: the test's name and status on one line, what it tests, its result, its notes. */
@interface TestCell : UITableViewCell
@property (strong, nonatomic) UILabel *name, *status, *what, *detail, *notes;
@end

@implementation TestCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
{
	UILayoutGuide *margins;
	UIStackView *column;
	NSLayoutConstraint *bottom;

	self = [super initWithStyle:style reuseIdentifier:identifier];
	if (self == nil) {
		return nil;
	}
	self.selectionStyle = UITableViewCellSelectionStyleNone;
	_name = [UILabel new];
	_name.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
	_status = [UILabel new];
	_status.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
	_status.textAlignment = NSTextAlignmentRight;
	_what = [UILabel new];
	_what.font = [UIFont systemFontOfSize:12];
	_what.textColor = UIColor.secondaryLabelColor;
	_what.numberOfLines = 0;
	_detail = [UILabel new];
	_detail.font = [UIFont systemFontOfSize:12.5];
	_detail.numberOfLines = 0;
	_notes = [UILabel new];
	/* (monospaced and small: the extension lists are long) */
	_notes.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
	_notes.textColor = UIColor.secondaryLabelColor;
	_notes.numberOfLines = 0;
	column = [[UIStackView alloc] initWithArrangedSubviews:@[ _what, _detail, _notes ]];
	column.axis = UILayoutConstraintAxisVertical;
	column.spacing = 3;
	for (UIView *view in @[ _name, _status, column ]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[self.contentView addSubview:view];
	}
	[_status setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	[_status setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	margins = self.contentView.layoutMarginsGuide;
	bottom = [column.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor];
	bottom.priority = UILayoutPriorityRequired - 1;
	[NSLayoutConstraint activateConstraints:@[
		[_name.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[_name.topAnchor constraintEqualToAnchor:margins.topAnchor],
		[_status.leadingAnchor constraintGreaterThanOrEqualToAnchor:_name.trailingAnchor constant:8],
		[_status.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[_status.firstBaselineAnchor constraintEqualToAnchor:_name.firstBaselineAnchor],
		[column.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[column.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[column.topAnchor constraintEqualToAnchor:_name.bottomAnchor constant:3],
		bottom,
	]];
	return self;
}

@end

@interface GPUController : UITableViewController
@end

@implementation GPUController {
	int _status[TEST_COUNT];
	NSString *_detail[TEST_COUNT];
	NSMutableArray<NSString *> *_notes[TEST_COUNT];
	int _first[G_COUNT], _count[G_COUNT];
	NSMutableDictionary<NSString *, NSArray<NSString *> *> *_marks;    /* test -> (status, detail) */
	BOOL _started, _running, _runOpen, _waiting, _runWhenShown;
	int _waitingFrom;
	NSString *_resumed;
	Test *_current;
	UILabel *_header;
	UIBarButtonItem *_again;
	CFTimeInterval _runStart;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"GPU Check";
	for (int g = 0; g < G_COUNT; g++) {
		_first[g] = -1;
	}
	for (int i = 0; i < TEST_COUNT; i++) {
		if (_first[tests[i].group] < 0) {
			_first[tests[i].group] = i;
		}
		_count[tests[i].group]++;
	}
	[self.tableView registerClass:TestCell.class forCellReuseIdentifier:@"test"];
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 70;
	self.tableView.allowsSelection = NO;
	_header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
	_header.font = [UIFont systemFontOfSize:12];
	_header.textColor = UIColor.secondaryLabelColor;
	_header.textAlignment = NSTextAlignmentCenter;
	_header.numberOfLines = 2;
	self.tableView.tableHeaderView = _header;
	_again = [[UIBarButtonItem alloc] initWithTitle:@"Run" style:UIBarButtonItemStylePlain target:self
	    action:@selector(runAgain)];
	self.navigationItem.rightBarButtonItem = _again;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:)
	    name:UIApplicationDidBecomeActiveNotification object:nil];
	[self loadLog];
	[self updateHeader];
}

/* (a run asked for before the tab was on the screen starts when it is: the on-screen tests want the window) */
- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	if (_runWhenShown) {
		_runWhenShown = NO;
		[self runAgain];
	}
}

- (void)runWhenShown
{
	if (self.viewIfLoaded.window != nil) {
		[self runAgain];
	} else {
		_runWhenShown = YES;
	}
}

- (void)clearResults
{
	for (int i = 0; i < TEST_COUNT; i++) {
		_status[i] = ST_WAITING;
		_detail[i] = nil;
		_notes[i] = [NSMutableArray array];
	}
}

/*
 * The log as the last launch left it: the marks, and the run it was in the middle of. If a test was running when the
 * application went down, it is that test's doing: CRASHED with the signal or exception the handler wrote, or HUNG if
 * the watchdog had called it hung or nothing at all was written (killed).
 */
- (void)loadLog
{
	NSString *text = [NSString stringWithContentsOfFile:log_path() encoding:NSUTF8StringEncoding error:nil] ?: @"";
	NSMutableDictionary<NSString *, NSString *> *crashed = [NSMutableDictionary dictionary],
	    *hung = [NSMutableDictionary dictionary];
	NSString *running = nil;
	int i;

	_marks = [NSMutableDictionary dictionary];
	_runOpen = NO;
	[self clearResults];
	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
		NSString *kind, *ident;

		if (f.count < 3) {
			continue;
		}
		kind = f[0];
		ident = f[1];
		i = test_index(ident);
		if ([kind isEqualToString:@"run"]) {
			[self clearResults];
			_runOpen = YES;
			running = nil;
			[crashed removeAllObjects];
			[hung removeAllObjects];
		} else if ([kind isEqualToString:@"done"]) {
			_runOpen = NO;
			running = nil;
		} else if ([kind isEqualToString:@"mark"] && f.count >= 4) {
			_marks[ident] = @[ f[2], f[3] ];
		} else if (i < 0) {
			continue;
		} else if ([kind isEqualToString:@"running"]) {
			running = ident;
			[_notes[i] removeAllObjects];
		} else if ([kind isEqualToString:@"note"]) {
			[_notes[i] addObject:f[2]];
		} else if ([kind isEqualToString:@"crashed"]) {
			if (crashed[ident] == nil) {
				crashed[ident] = f[2];
			}
		} else if ([kind isEqualToString:@"hung"]) {
			hung[ident] = f[2];
		} else if ([kind isEqualToString:@"result"] && f.count >= 4) {
			_status[i] = status_from_name(f[2]);
			_detail[i] = f[3];
			if ([running isEqualToString:ident]) {
				running = nil;
			}
		}
	}
	i = running != nil ? test_index(running) : -1;
	if (_runOpen && i >= 0) {
		NSString *c = crashed[running], *h = hung[running], *detail;
		int status = c != nil ? ST_CRASHED : ST_HUNG;

		detail = c != nil ? [NSString stringWithFormat:@"%@: the app died", c] :
		    h != nil ? [NSString stringWithFormat:@"%@, then the app was killed", h] :
		    @"the app died while it ran, with no crash signal: killed (by hand, a watchdog or jetsam)";
		_status[i] = status;
		_detail[i] = detail;
		record("result", tests[i].ident, status_c[status], detail);
		record("mark", tests[i].ident, status_c[status], detail);
		_marks[running] = @[ @(status_c[status]), detail ];
		_resumed = [NSString stringWithFormat:@"resume: the last launch died in %s: %s %@", tests[i].ident,
		    status_c[status], detail];
	}
}

/*
 * A run: a new one unless the last launch died in the middle of one, which then goes on after the test that took it
 * down. Run again also forgets the marks, so that every test runs.
 */
- (void)startRun:(BOOL)again
{
	NSDictionary *info = NSBundle.mainBundle.infoDictionary;

	if (again) {
		[_marks removeAllObjects];
		_runOpen = NO;
		_resumed = nil;
	}
	if (!_runOpen) {
		/* (the log starts again, keeping only the marks) */
		if (g_log >= 0) {
			(void)ftruncate(g_log, 0);
		}
		for (NSString *ident in _marks) {
			record("mark", ident.UTF8String, _marks[ident][0].UTF8String, _marks[ident][1]);
		}
		record("run", "-", NULL, [NSDate date].description);
		[self clearResults];
		_runOpen = YES;
	}
	say(@"start %@ %@ %@", info[@"CFBundleShortVersionString"], machine(), UIDevice.currentDevice.systemVersion);
	say(@"log %@, %d tests, %lu marked from earlier launches", log_path(), TEST_COUNT, (unsigned long)_marks.count);
	if (_resumed != nil) {
		say(@"%@", _resumed);
		_resumed = nil;
	}
	for (int i = 0; i < TEST_COUNT; i++) {
		if (_status[i] >= ST_PASS) {
			say(@"%s %s %@", tests[i].ident, status_c[_status[i]], _detail[i]);
		}
	}
	_running = YES;
	_again.enabled = NO;
	_runStart = CACurrentMediaTime();
	UIApplication.sharedApplication.idleTimerDisabled = YES;
	[self.tableView reloadData];
	[self updateHeader];
	[self runFrom:0];
}

/* Run: the first in a launch goes on with the run the last launch left open, if any, and keeps the marks; Run again
   starts from the top and forgets them */
- (void)runAgain
{
	if (!_running) {
		[self startRun:_started];
		_started = YES;
	}
}

/* the next test that has no result yet; one marked in an earlier launch gets its mark, and is not run */
- (void)runFrom:(int)i
{
	/* (no GL in the background, where iOS kills an application for it: the run waits to be in front again) */
	if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
		_waiting = YES;
		_waitingFrom = i;
		return;
	}
	for (; i < TEST_COUNT; i++) {
		NSArray<NSString *> *mark;

		if (_status[i] >= ST_PASS) {
			continue;
		}
		mark = _marks[@(tests[i].ident)];
		if (mark != nil) {
			_status[i] = status_from_name(mark[0]);
			_detail[i] = [NSString stringWithFormat:@"%@ [in an earlier launch; skipped until Run again]", mark[1]];
			record("result", tests[i].ident, status_c[_status[i]], _detail[i]);
			say(@"%s %s %@", tests[i].ident, status_c[_status[i]], _detail[i]);
			[self showRow:i];
			continue;
		}
		[self runTest:i];
		return;
	}
	[self finishRun];
}

- (void)active:(NSNotification *)notification
{
	if (_waiting) {
		_waiting = NO;
		[self runFrom:_waitingFrom];
	}
}

- (void)runTest:(int)i
{
	Test *t = [[Test alloc] initWithIndex:i ident:tests[i].ident];
	__weak GPUController *weak = self;

	t.window = self.view.window;
	t.presenter = self.navigationController;
	_notes[i] = t.notes;
	_status[i] = ST_RUNNING;
	_detail[i] = nil;
	_current = t;
	[self showRow:i];
	[self.tableView scrollToRowAtIndexPath:[self pathOf:i] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
	record("running", tests[i].ident, NULL, @"");
	atomic_store(&g_hung, -1);
	atomic_store(&g_started, CACurrentMediaTime());
	atomic_store(&g_running, i);
	t.done = ^(Test *test) {
		[weak finished:test];
	};
	@autoreleasepool {
		tests[i].run(t);
	}
	if (!t.async) {
		[t end];
	} else if (!t.ended) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ASYNC_LIMIT * NSEC_PER_SEC)), dispatch_get_main_queue(),
		    ^{
			if (!t.ended) {
				[t fail:@"no verdict after %.1f s, with the main thread free", ASYNC_LIMIT];
				[t end];
			}
		});
	}
}

- (void)finished:(Test *)t
{
	int i = t.index, status = t.status;
	double took = CACurrentMediaTime() - atomic_load(&g_started);
	NSString *detail = t.detail;
	__weak GPUController *weak = self;

	if (atomic_load(&g_hung) == i || took > HANG_SECONDS) {
		detail = [NSString stringWithFormat:@"took %.1f s, more than %.0f on the main thread; then %s: %@", took,
		    HANG_SECONDS, status_c[status], detail];
		status = ST_HUNG;
	}
	atomic_store(&g_running, -1);
	_status[i] = status;
	_detail[i] = detail;
	_current = nil;
	record("result", tests[i].ident, status_c[status], detail);
	say(@"%s %s %@", tests[i].ident, status_c[status], detail);
	[self showRow:i];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weak runFrom:i + 1];
	});
}

- (void)finishRun
{
	int counts[ST_COUNT] = { 0 };
	NSString *summary;

	for (int i = 0; i < TEST_COUNT; i++) {
		counts[_status[i]]++;
	}
	summary = [NSString stringWithFormat:@"%d pass, %d fail, %d crashed, %d hung, %d skipped", counts[ST_PASS],
	    counts[ST_FAIL], counts[ST_CRASHED], counts[ST_HUNG], counts[ST_SKIP]];
	record("done", "-", NULL, summary);
	say(@"done %@ (%d tests, %.1f s)", summary, TEST_COUNT, CACurrentMediaTime() - _runStart);
	_running = NO;
	_runOpen = NO;
	_again.title = @"Run again";
	_again.enabled = YES;
	UIApplication.sharedApplication.idleTimerDisabled = NO;
	[self updateHeader];
}

- (void)updateHeader
{
	NSDictionary *info = NSBundle.mainBundle.infoDictionary;
	int counts[ST_COUNT] = { 0 }, done = 0;

	for (int i = 0; i < TEST_COUNT; i++) {
		counts[_status[i]]++;
		done += _status[i] >= ST_PASS;
	}
	_header.text = [NSString stringWithFormat:@"%@ · iOS %@ · System Check %@ (%@)\n%d of %d · %d pass · %d fail · "
	    "%d crashed · %d hung · %d skip", machine(), UIDevice.currentDevice.systemVersion,
	    info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], done, TEST_COUNT, counts[ST_PASS],
	    counts[ST_FAIL], counts[ST_CRASHED], counts[ST_HUNG], counts[ST_SKIP]];
}

- (NSIndexPath *)pathOf:(int)i
{
	return [NSIndexPath indexPathForRow:i - _first[tests[i].group] inSection:tests[i].group];
}

- (void)showRow:(int)i
{
	[UIView performWithoutAnimation:^{
		[self.tableView reloadRowsAtIndexPaths:@[ [self pathOf:i] ] withRowAnimation:UITableViewRowAnimationNone];
	}];
	[self updateHeader];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table
{
	return G_COUNT;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section
{
	return _count[section];
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section
{
	return groups[section].title;
}

- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section
{
	return groups[section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
	int i = _first[path.section] + (int)path.row;
	TestCell *cell = [table dequeueReusableCellWithIdentifier:@"test" forIndexPath:path];
	NSString *notes = [_notes[i] componentsJoinedByString:@"\n"];

	cell.name.text = @(tests[i].ident);
	cell.status.text = @(status_c[_status[i]]);
	cell.status.textColor = status_color(_status[i]);
	cell.what.text = @(tests[i].what);
	cell.detail.text = _detail[i];
	cell.detail.hidden = _detail[i].length == 0;
	cell.notes.text = notes;
	cell.notes.hidden = notes.length == 0;
	return cell;
}

@end

static GPUController *g_controller;

UIViewController *
gpu_controller(void)
{
	if (g_controller == nil) {
		/* (the record before anything is tested: the console, the log, then whatever may take the application down) */
		g_console = open("/dev/console", O_WRONLY | O_NOCTTY);
		if (g_console < 0) {
			NSLog(@"gpucheck: /dev/console: %s (results go to NSLog and the log only)", strerror(errno));
		}
		g_log = open(log_path().fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
		watch_for_crashes();
		watch_for_hangs();
		g_controller = [[GPUController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	}
	return g_controller;
}

void
gpu_run(void)
{
	[(GPUController *)gpu_controller() runWhenShown];
}
