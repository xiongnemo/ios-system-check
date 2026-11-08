// System Check's Metal tab (what was Metal Check): what an iOS application finds of Metal, tested one at a time, each
// with PASS, FAIL or SKIP -- or CRASHED when it took the application down. Written for the iOS 16.5 port to the Redmi
// K40, where Metal is being built over the port's own GPU driver (an Adreno 650, reached through the kernel's
// HakiosGPU service); on an iPhone it is an ordinary application. The system, the GPU's kernel service and what it
// says, what Metal's discovery finds (the services it looks for, the device it gives), the private parts of Metal the
// port's driver stands on; then, where Metal has no device of its own, the port's driver registered by this
// application, and with it a queue, clears, a triangle and compute, off screen and on (the two squares at the top).
// Run (or systemcheck://metal/run) runs everything in order. Each test is written down in Documents/metalcheck.log
// before it starts and when it ends, so that one that takes the application down is found at the next launch, marked,
// and skipped from then on (until Run again). Every result is also a line on /dev/console ("metalcheck: ...") and in
// NSLog.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <unistd.h>
#import "check.h"

/* IOKit's calls, declared here: the iPhoneOS SDK has IOKit's library but not its headers */
#define IO_OBJECT_NULL  ((io_object_t)0)
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef io_object_t io_iterator_t;
typedef io_object_t io_registry_entry_t;
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern io_service_t IOServiceGetMatchingService(mach_port_t main_port, CFDictionaryRef matching);
extern kern_return_t IOServiceGetMatchingServices(mach_port_t main_port, CFDictionaryRef matching, io_iterator_t *existing);
extern io_object_t IOIteratorNext(io_iterator_t iterator);
extern kern_return_t IOObjectRelease(io_object_t object);
extern kern_return_t IOServiceOpen(io_service_t service, task_port_t owning_task, uint32_t type, io_connect_t *connect);
extern kern_return_t IOServiceClose(io_connect_t connect);
extern kern_return_t IOConnectCallStructMethod(mach_port_t connection, uint32_t selector, const void *input,
    size_t input_size, void *output, size_t *output_size);
extern CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator,
    uint32_t options);
extern kern_return_t IORegistryEntryGetName(io_registry_entry_t entry, char name[128]);
/* dyld's: where the shared cache is (iOS 13 and later) */
extern const void *_dyld_get_shared_cache_range(size_t *length);

#define LINE_BYTES      260     /* a console line, after "metalcheck: ", at most */

/* a test's status, in rising order of severity: a later verdict only counts if it is worse */
enum { ST_WAITING, ST_RUNNING, ST_PASS, ST_SKIP, ST_FAIL, ST_CRASHED, ST_COUNT };

static const char *const status_c[ST_COUNT] = {
	[ST_WAITING] = "-", [ST_RUNNING] = "running", [ST_PASS] = "PASS", [ST_SKIP] = "SKIP", [ST_FAIL] = "FAIL",
	[ST_CRASHED] = "CRASHED",
};

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
	case ST_RUNNING:
		return UIColor.systemBlueColor;
	default:
		return UIColor.secondaryLabelColor;
	}
}

static NSString *
sysctl_string(const char *name)
{
	char value[256] = "";
	size_t size = sizeof(value) - 1;

	return sysctlbyname(name, value, &size, NULL, 0) == 0 ? @(value) : @"?";
}

#pragma mark the record: Documents/metalcheck.log, /dev/console and NSLog

/*
 * The log is a line per event, KIND <tab> TEST <tab> TEXT, appended and flushed to the disk before anything else
 * happens: "run" (a run starts), "running" (a test starts), "note", "result", "crashed" (a signal or an uncaught
 * exception, written by the handler on its way out), "mark" (a test that took the application down: skipped until
 * Run again), "again" (Run again: the marks are forgotten), "done". What the last launch left "running" is what took
 * it down.
 */
static int g_log = -1, g_console = -1;

static NSString *
log_path(void)
{
	NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?:
	    NSTemporaryDirectory();

	[NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil
	    error:nil];
	return [documents stringByAppendingPathComponent:@"metalcheck.log"];
}

static void
record(const char *kind, const char *ident, NSString *text)
{
	NSString *clean = [[text ?: @"" stringByReplacingOccurrencesOfString:@"\t" withString:@" "]
	    stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
	NSData *bytes = [[NSString stringWithFormat:@"%s\t%s\t%@\n", kind, ident, clean]
	    dataUsingEncoding:NSUTF8StringEncoding];

	if (g_log >= 0) {
		(void)write(g_log, bytes.bytes, bytes.length);
		(void)fsync(g_log);
	}
}

/* a line for whoever reads the console, "metalcheck: TEXT", cut into pieces of at most LINE_BYTES; and NSLog */
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
	NSLog(@"metalcheck: %@", text);
	if (g_console < 0) {
		return;
	}
	bytes = [text dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
	p = bytes.bytes;
	left = bytes.length;
	do {
		const char *head = first ? "metalcheck: " : "metalcheck: ... ";
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

#pragma mark a test

/* The one test being run: what it found (notes, each logged and said at once) and its verdict (the worst wins). */
@interface MetalTest : NSObject
@property (readonly, nonatomic) const char *ident;
@property (readonly, nonatomic) int status;
@property (readonly, nonatomic) NSString *detail;
@property (readonly, nonatomic) NSMutableArray<NSString *> *notes;
- (instancetype)initWithIdent:(const char *)ident;
- (void)note:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)pass:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)skip:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)fail:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)verdict:(int)status detail:(NSString *)detail;
@end

@implementation MetalTest

- (instancetype)initWithIdent:(const char *)ident
{
	if ((self = [super init]) != nil) {
		_ident = ident;
		_status = ST_WAITING;
		_detail = @"";
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
	record("note", _ident, text);
	say(@"%s + %@", _ident, text);
}

- (void)verdict:(int)status detail:(NSString *)detail
{
	if (status > _status || _status == ST_RUNNING) {
		_status = status;
		_detail = detail;
	}
}

#define VERDICT(status) \
	va_list arguments; \
	va_start(arguments, format); \
	[self verdict:(status) detail:[[NSString alloc] initWithFormat:format arguments:arguments]]; \
	va_end(arguments)

- (void)pass:(NSString *)format, ...
{
	VERDICT(ST_PASS);
}

- (void)skip:(NSString *)format, ...
{
	VERDICT(ST_SKIP);
}

- (void)fail:(NSString *)format, ...
{
	VERDICT(ST_FAIL);
}

@end

#pragma mark what is looked at

/* a string property of an IOKit service, or nil */
static NSString *
service_string(io_service_t service, NSString *key)
{
	CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
	NSString *text = nil;

	if (value != NULL) {
		if (CFGetTypeID(value) == CFStringGetTypeID()) {
			text = [(__bridge NSString *)value copy];
		}
		CFRelease(value);
	}
	return text;
}

/* the port's GPU service, opened (type 0, as its Mesa opens it), or IO_OBJECT_NULL; the caller closes it */
static io_connect_t
gpu_open(kern_return_t *result, BOOL *found)
{
	io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("HakiosGPU"));
	io_connect_t gpu = IO_OBJECT_NULL;

	*found = service != IO_OBJECT_NULL;
	*result = KERN_FAILURE;
	if (service != IO_OBJECT_NULL) {
		*result = IOServiceOpen(service, mach_task_self(), 0, &gpu);
		IOObjectRelease(service);
	}
	return *result == KERN_SUCCESS ? gpu : IO_OBJECT_NULL;
}

/*
 * One of Linux's msm GET_PARAM requests, which the port's GPU service answers as a call of its user client: a request's
 * number is the call's selector (DRM_COMMAND_BASE 0x40 + MSM_GET_PARAM 0x00), struct msm_param in and out.
 */
static BOOL
gpu_param(io_connect_t gpu, uint32_t which, uint64_t *value)
{
	struct {
		uint32_t pipe, param;
		uint64_t value;
		uint32_t len, pad;
	} request = { 1, which, 0, 0, 0 };              /* (pipe 1: MSM_PIPE_3D0) */
	size_t size = sizeof(request);

	if (IOConnectCallStructMethod(gpu, 0x40, &request, sizeof(request), &request, &size) != KERN_SUCCESS) {
		return NO;
	}
	*value = request.value;
	return YES;
}

/* Does the main program itself load this library (its load commands, not what others brought in)? */
static BOOL
main_links(const char *library)
{
	const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
	const struct load_command *command = (const struct load_command *)(header + 1);

	for (uint32_t i = 0; i < header->ncmds; i++) {
		if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB || command->cmd == LC_REEXPORT_DYLIB) {
			const struct dylib_command *dylib = (const struct dylib_command *)command;
			const char *name = (const char *)command + dylib->dylib.name.offset;

			if (strstr(name, library) != NULL) {
				return YES;
			}
		}
		command = (const struct load_command *)((const char *)command + command->cmdsize);
	}
	return NO;
}

static BOOL
process_has(const char *library)
{
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char *name = _dyld_get_image_name(i);

		if (name != NULL && strstr(name, library) != NULL) {
			return YES;
		}
	}
	return NO;
}

/* The shared cache's slide, and whether this is the cache the K40 port runs (iOS 16.5, 20F66): the addresses below
 * are of that one. MTLCreateSystemDefaultDevice is at 0x181a34b3c in it, the cache starts at 0x180000000. */
#define MTL_CREATE_DEVICE_20F66 0x181a34b3cUL
#define MTL_ADD_DEVICE_20F66    0x181a1875cUL
#define CACHE_BASE              0x180000000UL

static BOOL
cache_is_20f66(uintptr_t *slide)
{
	size_t length = 0;
	const void *start = _dyld_get_shared_cache_range(&length);

	*slide = (uintptr_t)&MTLCreateSystemDefaultDevice - MTL_CREATE_DEVICE_20F66;
	return start != NULL && [sysctl_string("kern.osversion") isEqualToString:@"20F66"] &&
	    (uintptr_t)start - CACHE_BASE == *slide;
}

#pragma mark the tests

static void
test_system(MetalTest *t)
{
	uintptr_t slide = 0;

	[t note:@"iOS %@ (%@), %@ (%@)", UIDevice.currentDevice.systemVersion, sysctl_string("kern.osversion"),
	    sysctl_string("hw.machine"), sysctl_string("hw.model")];
	[t note:@"kernel: %@", [[sysctl_string("kern.version") componentsSeparatedByString:@";"] firstObject]];
	[t note:@"the shared cache: %@", cache_is_20f66(&slide) ? [NSString stringWithFormat:@"20F66's, slide %#lx",
	    slide] : @"not 20F66's (the K40 port's addresses below do not apply)"];
	[t pass:@"iOS %@ (%@) on %@", UIDevice.currentDevice.systemVersion, sysctl_string("kern.osversion"),
	    sysctl_string("hw.machine")];
}

/* On the port, an application gets the GPU's OpenGL ES only when its main program loads OpenGLES. This one does, for
   its GPU tab: what is tested here is Metal next to GL, as in a game that has both. */
static void
test_no_opengles(MetalTest *t)
{
	BOOL linked = main_links("/OpenGLES.framework/"), loaded = process_has("/OpenGLES.framework/");

	[t note:@"OpenGLES.framework in the process: %@", loaded ? (linked ? @"yes (the main program links it)" :
	    @"yes (brought in by another framework)") : @"no"];
	[t note:@"the port's GL library in the process: %@", process_has("libhakios.gl") ? @"YES" : @"no"];
	if (linked) {
		[t skip:@"the main program links OpenGL ES (the GPU tab needs it): Metal is tested next to the port's GL"];
	} else {
		[t pass:@"the main program does not link OpenGL ES: Metal is its only way to draw"];
	}
}

static void
test_gpu_service(MetalTest *t)
{
	kern_return_t result;
	BOOL found;
	io_connect_t gpu = gpu_open(&result, &found);

	if (!found) {
		[t skip:@"no HakiosGPU service: not the K40 port (or its GPU was not started)"];
		return;
	}
	if (gpu == IO_OBJECT_NULL) {
		[t fail:@"HakiosGPU is there but would not open (%#x)", result];
		return;
	}
	IOServiceClose(gpu);
	[t pass:@"HakiosGPU opened (and closed again)"];
}

static void
test_gpu_params(MetalTest *t)
{
	static const struct {
		uint32_t param;
		const char *name;
	} params[] = {
		{ 0x03, "CHIP_ID" }, { 0x02, "GMEM_SIZE" }, { 0x04, "MAX_FREQ" }, { 0x10, "HIGHEST_BANK_BIT" },
		{ 0x09, "FAULTS" }, { 0x05, "TIMESTAMP" },
	};
	kern_return_t result;
	BOOL found;
	io_connect_t gpu = gpu_open(&result, &found);
	uint64_t chip = 0, value;
	unsigned answered = 0;

	if (gpu == IO_OBJECT_NULL) {
		[t skip:@"no HakiosGPU to ask"];
		return;
	}
	for (size_t i = 0; i < sizeof(params) / sizeof(params[0]); i++) {
		if (gpu_param(gpu, params[i].param, &value)) {
			answered++;
			chip = params[i].param == 0x03 ? value : chip;
			[t note:@"%s = %#llx (%llu)", params[i].name, (unsigned long long)value, (unsigned long long)value];
		} else {
			[t note:@"%s: no answer", params[i].name];
		}
	}
	IOServiceClose(gpu);
	if ((uint32_t)chip == 0) {
		[t fail:@"no chip ID (%u of %zu parameters answered)", answered, sizeof(params) / sizeof(params[0])];
		return;
	}
	/* (CHIP_ID: core, major, minor, patch a byte each from the top, the speed bin above them) */
	[t pass:@"Adreno %u%u%u (chip %#llx, speed bin %llu), %u of %zu parameters answered", (unsigned)(chip >> 24) & 0xff,
	    (unsigned)(chip >> 16) & 0xff, (unsigned)(chip >> 8) & 0xff, (unsigned long long)(chip & 0xffffffff),
	    (unsigned long long)(chip >> 32), answered, sizeof(params) / sizeof(params[0])];
}

/*
 * Metal's discovery, as MTLCreateSystemDefaultDevice() goes through it: the services of class "IOAcceleratorES", of
 * each its "MetalPluginName" (a bundle in /System/Library/Extensions) and "MetalPluginClassName". No service, or none
 * with a plug-in's name, and Metal finds no device -- silently.
 */
static void
test_metal_services(MetalTest *t)
{
	io_iterator_t it = IO_OBJECT_NULL;
	io_service_t service;
	unsigned services = 0, plugins = 0;

	if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOAcceleratorES"), &it) != KERN_SUCCESS) {
		[t fail:@"IOKit would not list IOAcceleratorES services"];
		return;
	}
	while ((service = IOIteratorNext(it)) != IO_OBJECT_NULL) {
		char name[128] = "";
		NSString *plugin = service_string(service, @"MetalPluginName");
		NSString *cls = service_string(service, @"MetalPluginClassName");

		IORegistryEntryGetName(service, name);
		[t note:@"IOAcceleratorES \"%s\": MetalPluginName %@, MetalPluginClassName %@", name, plugin ?: @"(none)",
		    cls ?: @"(none)"];
		services++;
		plugins += plugin != nil;
		IOObjectRelease(service);
	}
	IOObjectRelease(it);
	if (services == 0) {
		[t fail:@"no IOAcceleratorES service: Metal's discovery has nothing to look at"];
	} else if (plugins == 0) {
		[t fail:@"%u IOAcceleratorES service(s), none naming a Metal plug-in: discovery finds no driver", services];
	} else {
		[t pass:@"%u IOAcceleratorES service(s), %u naming a Metal plug-in", services, plugins];
	}
}

/*
 * What a Metal driver over Metal's own private classes stands on (the one the K40 port is to borrow was written for
 * this iOS, 20F66): the base classes and the designated initialisers Apple's own drivers send to super, the ivars it
 * finds by name (the queue's command-buffer semaphore, which it hands back), the protocols it declares.
 */
static void
test_metal_private(MetalTest *t)
{
	static const struct {
		const char *cls, *sel;
	} parts[] = {
		{ "_MTLDevice", "initWithAcceleratorPort:" },
		{ "_MTLObjectWithLabel", "init" },
		{ "_MTLResource", NULL },
		{ "_MTLCommandQueue", "initWithDevice:descriptor:" },
		{ "_MTLCommandBuffer", "initWithQueue:retainedReferences:synchronousDebugMode:" },
		{ "_MTLCommandEncoder", "initWithCommandBuffer:" },
		{ "_MTLComputePipelineState", "initWithDevice:pipelineStateDescriptor:" },
		{ "_MTLRenderPipelineState", "initWithDevice:pipelineStateDescriptor:" },
		{ "_MTLDepthStencilState", "initWithDevice:depthStencilDescriptor:" },
		{ "_MTLSamplerState", "initWithDevice:samplerDescriptor:" },
		{ "_MTLFunction", "bitcodeData" },
		{ "CAMetalLayer", "nextDrawable" },
	};
	static const struct {
		const char *cls, *ivar;
	} ivars[] = {
		{ "_MTLCommandQueue", "_commandBufferSemaphore" },
		{ "_MTLCommandQueue", "_completionQueue" },
		{ "_MTLCommandBuffer", "_needsCommandBufferSemaphoreSignal" },
	};
	static const char *const protocols[] = { "MTLDevice", "MTLDeviceSPI" };
	NSMutableArray<NSString *> *missing = [NSMutableArray array];

	for (size_t i = 0; i < sizeof(parts) / sizeof(parts[0]); i++) {
		Class cls = objc_getClass(parts[i].cls);

		if (cls == Nil) {
			[missing addObject:@(parts[i].cls)];
		} else if (parts[i].sel != NULL && class_getInstanceMethod(cls, sel_registerName(parts[i].sel)) == NULL) {
			[missing addObject:[NSString stringWithFormat:@"-[%s %s]", parts[i].cls, parts[i].sel]];
		}
	}
	for (size_t i = 0; i < sizeof(ivars) / sizeof(ivars[0]); i++) {
		Class cls = objc_getClass(ivars[i].cls);
		Ivar ivar = cls != Nil ? class_getInstanceVariable(cls, ivars[i].ivar) : NULL;

		if (ivar == NULL) {
			[missing addObject:[NSString stringWithFormat:@"%s.%s", ivars[i].cls, ivars[i].ivar]];
		} else {
			[t note:@"%s.%s at +%#tx, %s", ivars[i].cls, ivars[i].ivar, ivar_getOffset(ivar),
			    ivar_getTypeEncoding(ivar) ?: "?"];
		}
	}
	for (size_t i = 0; i < sizeof(protocols) / sizeof(protocols[0]); i++) {
		if (objc_getProtocol(protocols[i]) == NULL) {
			[missing addObject:[NSString stringWithFormat:@"protocol %s", protocols[i]]];
		}
	}
	if (missing.count != 0) {
		[t fail:@"not in this Metal: %@", [missing componentsJoinedByString:@", "]];
	} else {
		[t pass:@"%zu classes and initialisers, %zu ivars, %zu protocols: all there", sizeof(parts) / sizeof(parts[0]),
		    sizeof(ivars) / sizeof(ivars[0]), sizeof(protocols) / sizeof(protocols[0])];
	}
}

/*
 * MTLAddDevice -- the function Metal registers a driver's device with. Its first instructions in 20F66 are compared
 * before it is called by its address (the same bytes at any slide: adrp's page distance does not change when the
 * whole cache moves); the K40 port's dyld finds it by name too, and then that is the one taken.
 */
static const unsigned char add_device_20f66[32] = {
	0xff, 0x03, 0x02, 0xd1, 0xf4, 0x4f, 0x06, 0xa9, 0xfd, 0x7b, 0x07, 0xa9, 0xfd, 0xc3, 0x01, 0x91,
	0xe8, 0xc3, 0x00, 0x91, 0xff, 0x23, 0x03, 0xa9, 0x88, 0x09, 0x00, 0x90, 0x00, 0xd9, 0x41, 0xfd,
};

/* the function, or NULL; how it was found in *how */
static void (*add_device_function(NSString **how))(id)
{
	void *named = dlsym(RTLD_DEFAULT, "MTLAddDevice");
	uintptr_t slide = 0;
	const unsigned char *at;

	if (named != NULL) {
		*how = @"by name";
		return (void (*)(id))named;
	}
	if (!cache_is_20f66(&slide)) {
		*how = @"not by name, and not 20F66's cache: its address is not known here";
		return NULL;
	}
	at = (const unsigned char *)(slide + MTL_ADD_DEVICE_20F66);
	if (memcmp(at, add_device_20f66, sizeof(add_device_20f66)) != 0) {
		*how = [NSString stringWithFormat:@"at %#lx the instructions are not MTLAddDevice's (%02x %02x %02x %02x ...)",
		    MTL_ADD_DEVICE_20F66, at[0], at[1], at[2], at[3]];
		return NULL;
	}
	*how = [NSString stringWithFormat:@"by its 20F66 address %#lx (%p here)", MTL_ADD_DEVICE_20F66, (const void *)at];
	return (void (*)(id))at;
}

static void
test_metal_adddevice(MetalTest *t)
{
	uintptr_t slide = 0;
	NSString *how = nil;
	void (*add)(id) = add_device_function(&how);

	if (cache_is_20f66(&slide)) {
		const unsigned char *at = (const unsigned char *)(slide + MTL_ADD_DEVICE_20F66);

		[t note:@"at its 20F66 address: %@", memcmp(at, add_device_20f66, sizeof(add_device_20f66)) == 0 ?
		    @"its first 8 instructions" : @"OTHER INSTRUCTIONS"];
	}
	if (add == NULL) {
		[t fail:@"MTLAddDevice not found: %@", how];
	} else {
		[t pass:@"MTLAddDevice found %@ (not called here)", how];
	}
}

static void
test_metal_device(MetalTest *t)
{
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();

	if (device == nil) {
		[t fail:@"no Metal device (MTLCreateSystemDefaultDevice returned nil)"];
		return;
	}
	[t note:@"class %s, registry ID %llu, unified memory %d", class_getName(object_getClass(device)),
	    (unsigned long long)device.registryID, (int)device.hasUnifiedMemory];
	[t pass:@"\"%@\", Apple family 1/4/7 %d/%d/%d", device.name, (int)[device supportsFamily:MTLGPUFamilyApple1],
	    (int)[device supportsFamily:MTLGPUFamilyApple4], (int)[device supportsFamily:MTLGPUFamilyApple7]];
}

#pragma mark the device the application registers itself (0.2), and what it does

static id<MTLDevice> g_device;          /* Metal's device after metal.register: the system's, or this port's own */
static BOOL g_registered_here;          /* ... this application's own, registered at a run of this launch */
static UIView *g_stage;                 /* where an on-screen test puts its layer (above the list) */

#define METAL_DRIVER    "/redwood/lib/libhakios.metal.dylib"    /* the K40 port's driver (its METAL=1 images) */

/*
 * No device from Metal's own discovery: the port's driver registered by this application -- the library loaded, its
 * device class given Metal's IOAcceleratorES service (-initWithAcceleratorPort:, as discovery would), the object handed
 * to MTLAddDevice -- after which MTLCreateSystemDefaultDevice() answers it. Only when Metal had none: Metal aborts a
 * process that has two devices and asks for the default one.
 */
static void
test_metal_register(MetalTest *t)
{
	id<MTLDevice> system = MTLCreateSystemDefaultDevice();
	io_service_t service;
	void *library;
	Class cls;
	id device;
	NSString *how = nil;
	void (*add)(id);

	if (system != nil) {
		g_device = system;
		[t pass:@"\"%@\" (%s), %@", system.name, class_getName(object_getClass(system)), g_registered_here ?
		    @"registered by this application at an earlier run" : @"from Metal's own discovery: nothing registered here"];
		return;
	}
	if (access(METAL_DRIVER, R_OK) != 0) {
		[t skip:@"no %s: not the K40 port, or an image of it built without METAL=1", METAL_DRIVER];
		return;
	}
	if ((library = dlopen(METAL_DRIVER, RTLD_NOW)) == NULL) {
		[t fail:@"%s would not load: %s", METAL_DRIVER, dlerror()];
		return;
	}
	if ((cls = objc_getClass("AliothMetalDevice")) == Nil) {
		[t fail:@"the driver has no AliothMetalDevice class"];
		return;
	}
	[t note:@"class AliothMetalDevice: a _MTLDevice %@", [cls isSubclassOfClass:objc_getClass("_MTLDevice")] ? @"yes" :
	    @"NO"];
	service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOAcceleratorES"));
	if (service == IO_OBJECT_NULL) {
		[t fail:@"no IOAcceleratorES service to hand the device class"];
		return;
	}
	device = ((id (*)(id, SEL, io_service_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"),
	    service);
	if (device == nil) {
		[t fail:@"-initWithAcceleratorPort: gave nil"];
		return;
	}
	if ((add = add_device_function(&how)) == NULL) {
		[t fail:@"a device, and no MTLAddDevice to register it with: %@", how];
		return;
	}
	[t note:@"MTLAddDevice %@", how];
	@try {
		add(device);
	} @catch (NSException *exception) {
		[t fail:@"MTLAddDevice threw %@: %@", exception.name, exception.reason];
		return;
	}
	g_registered_here = YES;
	g_device = MTLCreateSystemDefaultDevice();
	if (g_device == nil) {
		[t fail:@"MTLAddDevice took the device and MTLCreateSystemDefaultDevice() is still nil"];
		return;
	}
	[t note:@"registry ID %llu, unified memory %d, max threadgroup %lu, buffer up to %llu MB",
	    (unsigned long long)g_device.registryID, (int)g_device.hasUnifiedMemory,
	    (unsigned long)g_device.maxThreadsPerThreadgroup.width, (unsigned long long)(g_device.maxBufferLength >> 20)];
	[t pass:@"\"%@\" (%s), registered by this application", g_device.name, class_getName(object_getClass(g_device))];
}

/*
 * 70 command buffers, one after the other, each committed and waited for: a queue lets 64 be outstanding (Metal's own
 * semaphore, -[_MTLCommandQueue initWithDevice:descriptor:]), so a driver that does not give a finished one back
 * blocks the 65th for ever. Asked on a thread of its own, and given 15 s.
 */
static void
test_metal_queue70(MetalTest *t)
{
	id<MTLCommandQueue> queue;
	dispatch_semaphore_t finished;
	__block int done = 0;
	__block NSString *problem = nil;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if ((queue = [g_device newCommandQueue]) == nil) {
		[t fail:@"no command queue"];
		return;
	}
	finished = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		for (int i = 0; i < 70; i++) {
			id<MTLCommandBuffer> buffer = [queue commandBuffer];

			if (buffer == nil) {
				problem = [NSString stringWithFormat:@"command buffer %d: nil", i + 1];
				break;
			}
			[buffer commit];
			[buffer waitUntilCompleted];
			if (buffer.status != MTLCommandBufferStatusCompleted) {
				problem = [NSString stringWithFormat:@"command buffer %d: status %ld", i + 1, (long)buffer.status];
				break;
			}
			done = i + 1;
		}
		dispatch_semaphore_signal(finished);
	});
	if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
		[t fail:@"still waiting after %d of 70 command buffers: the queue's semaphore is not given back", done];
		return;
	}
	if (problem != nil) {
		[t fail:@"%@", problem];
		return;
	}
	[t pass:@"70 command buffers committed and completed, one after the other"];
}

/* A render pass that clears a 64x64 texture to blue and draws nothing, read back. */
static BOOL
clear_texture(id<MTLTexture> texture, MTLClearColor colour, NSString **problem)
{
	id<MTLCommandQueue> queue = [g_device newCommandQueue];
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	id<MTLRenderCommandEncoder> encoder;

	pass.colorAttachments[0].texture = texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = colour;
	if (queue == nil || buffer == nil || (encoder = [buffer renderCommandEncoderWithDescriptor:pass]) == nil) {
		*problem = queue == nil ? @"no command queue" : buffer == nil ? @"no command buffer" : @"no render encoder";
		return NO;
	}
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	if (buffer.status != MTLCommandBufferStatusCompleted) {
		*problem = [NSString stringWithFormat:@"the command buffer ended with status %ld", (long)buffer.status];
		return NO;
	}
	return YES;
}

/* the middle pixel of a BGRA8 texture, as B G R A */
static void
middle_bgra(id<MTLTexture> texture, unsigned char bgra[4])
{
	memset(bgra, 0, 4);
	[texture getBytes:bgra bytesPerRow:4 fromRegion:MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1)
	    mipmapLevel:0];
}

static void
test_metal_clear_offscreen(MetalTest *t)
{
	MTLTextureDescriptor *d;
	id<MTLTexture> texture;
	NSString *problem = nil;
	unsigned char p[4];

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64
	    mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	if ((texture = [g_device newTextureWithDescriptor:d]) == nil) {
		[t fail:@"no 64x64 BGRA8 texture"];
		return;
	}
	if (!clear_texture(texture, MTLClearColorMake(0, 0, 1, 1), &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	middle_bgra(texture, p);
	if (p[0] > 240 && p[1] < 16 && p[2] < 16 && p[3] > 240) {
		[t pass:@"cleared to blue and read back: B G R A %u %u %u %u", p[0], p[1], p[2], p[3]];
	} else {
		[t fail:@"cleared to blue, read back B G R A %u %u %u %u", p[0], p[1], p[2], p[3]];
	}
}

/* A CAMetalLayer on the screen, a frame of blue presented in it, the drawable read back; left up for a screenshot. */
static void
test_metal_clear_layer(MetalTest *t)
{
	CAMetalLayer *layer;
	id<CAMetalDrawable> drawable;
	id<MTLCommandQueue> queue;
	id<MTLCommandBuffer> buffer;
	MTLRenderPassDescriptor *pass;
	id<MTLRenderCommandEncoder> encoder;
	unsigned char p[4];

	if (g_device == nil || g_stage == nil) {
		[t skip:@"%@", g_device == nil ? @"no device" : @"nowhere on the screen to put a layer"];
		return;
	}
	layer = [CAMetalLayer layer];
	layer.device = g_device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = NO;                     /* (read back below) */
	layer.frame = g_stage.bounds;
	layer.contentsScale = UIScreen.mainScreen.scale;
	layer.drawableSize = CGSizeMake(g_stage.bounds.size.width * layer.contentsScale,
	    g_stage.bounds.size.height * layer.contentsScale);
	[g_stage.layer addSublayer:layer];
	if ((drawable = [layer nextDrawable]) == nil) {
		[t fail:@"the layer gave no drawable"];
		return;
	}
	[t note:@"drawable %lux%lu, %s", (unsigned long)drawable.texture.width, (unsigned long)drawable.texture.height,
	    class_getName(object_getClass(drawable.texture))];
	queue = [g_device newCommandQueue];
	buffer = [queue commandBuffer];
	pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = drawable.texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
	if ((encoder = [buffer renderCommandEncoderWithDescriptor:pass]) == nil) {
		[t fail:@"no render encoder for the drawable"];
		return;
	}
	[encoder endEncoding];
	[buffer presentDrawable:drawable];
	[buffer commit];
	[buffer waitUntilCompleted];
	middle_bgra(drawable.texture, p);
	if (p[0] > 240 && p[1] < 16 && p[2] < 16 && p[3] > 240) {
		[t pass:@"a blue frame presented (top right of the screen), read back B G R A %u %u %u %u", p[0], p[1], p[2],
		    p[3]];
	} else {
		[t fail:@"presented; the drawable read back B G R A %u %u %u %u, not blue", p[0], p[1], p[2], p[3]];
	}
}

/*
 * A triangle, with nothing of this application's own to compile it from (no Metal compiler here, and none to ship):
 * the fragment stage is Apple's clearFragment01 out of AppleMetalGLRenderer's library -- it fills with the float4 at
 * the start of its buffer 14 -- and there is no vertex stage, which is a driver's cue on the K40 port to supply its
 * full-screen quad; three vertices of that quad, (-1,-1) (1,-1) (-1,1), are the lower left half. On an iPhone a
 * pipeline without a vertex function is refused: then this says so.
 */
#define GL_RENDERER_LIBRARY     "/System/Library/Extensions/AppleMetalGLRenderer.bundle/default.metallib"
static const unsigned char clear_bgra[4] = { 255, 0, 0, 255 }, orange_bgra[4] = { 0, 128, 255, 255 };

static id<MTLRenderPipelineState>
triangle_pipeline(NSString **problem)
{
	static id<MTLRenderPipelineState> made;
	NSData *data;
	dispatch_data_t wrapped;
	id<MTLLibrary> library;
	id<MTLFunction> fragment;
	MTLRenderPipelineDescriptor *d;
	NSError *error = nil;

	if (made != nil) {
		return made;
	}
	if ((data = [NSData dataWithContentsOfFile:@GL_RENDERER_LIBRARY]) == nil) {
		*problem = @"no " GL_RENDERER_LIBRARY;
		return nil;
	}
	wrapped = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	if ((library = [g_device newLibraryWithData:wrapped error:&error]) == nil) {
		*problem = [NSString stringWithFormat:@"-newLibraryWithData: gave nil (%@)", error.localizedDescription];
		return nil;
	}
	if ((fragment = [library newFunctionWithName:@"clearFragment01"]) == nil) {
		*problem = @"no clearFragment01 in AppleMetalGLRenderer's library";
		return nil;
	}
	d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = nil;
	d.fragmentFunction = fragment;
	d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	@try {
		made = [g_device newRenderPipelineStateWithDescriptor:d error:&error];
	} @catch (NSException *exception) {
		*problem = [NSString stringWithFormat:@"the pipeline was refused: %@", exception.reason];
		return nil;
	}
	if (made == nil) {
		*problem = [NSString stringWithFormat:@"no pipeline (%@)", error.localizedDescription];
	}
	return made;
}

/* the triangle drawn over a blue clear into the texture, waited for */
static BOOL
draw_triangle(id<MTLTexture> texture, id<CAMetalDrawable> drawable, NSString **problem)
{
	id<MTLRenderPipelineState> pipeline = triangle_pipeline(problem);
	id<MTLCommandQueue> queue = [g_device newCommandQueue];
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLBuffer> colour = [g_device newBufferWithLength:256 options:0];
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	id<MTLRenderCommandEncoder> encoder;
	float *f;

	if (pipeline == nil) {
		return NO;
	}
	if (colour == nil || (f = colour.contents) == NULL) {
		*problem = @"no buffer for the colour";
		return NO;
	}
	memset(f, 0, 256);
	f[0] = orange_bgra[2] / 255.0f;
	f[1] = orange_bgra[1] / 255.0f;
	f[2] = orange_bgra[0] / 255.0f;
	f[3] = 1.0f;
	pass.colorAttachments[0].texture = texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
	if (buffer == nil || (encoder = [buffer renderCommandEncoderWithDescriptor:pass]) == nil) {
		*problem = @"no render encoder";
		return NO;
	}
	[encoder setRenderPipelineState:pipeline];
	for (NSUInteger i = 0; i < 16; i++) {           /* (the shader's is 14; every index, as a79ff07's does) */
		[encoder setFragmentBuffer:colour offset:0 atIndex:i];
	}
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[encoder endEncoding];
	if (drawable != nil) {
		[buffer presentDrawable:drawable];
	}
	[buffer commit];
	[buffer waitUntilCompleted];
	if (buffer.status != MTLCommandBufferStatusCompleted) {
		*problem = [NSString stringWithFormat:@"the command buffer ended with status %ld", (long)buffer.status];
		return NO;
	}
	return YES;
}

/* every pixel read back against the triangle's own edge, in integers: orange inside, blue outside (one off allowed) */
static NSString *
triangle_mismatches(id<MTLTexture> texture, unsigned *wrong)
{
	NSUInteger w = texture.width, h = texture.height;
	NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
	unsigned char *p = pixels.mutableBytes;
	unsigned inside = 0, outside = 0;

	[texture getBytes:p bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
	*wrong = 0;
	for (NSUInteger y = 0; y < h; y++) {
		for (NSUInteger x = 0; x < w; x++) {
			unsigned long long a = (unsigned long long)(2 * x + 1) * h, b = (unsigned long long)(2 * y + 1) * w;
			const unsigned char *want = a < b ? orange_bgra : clear_bgra, *got = p + (y * w + x) * 4;

			if (a == b) {
				continue;       /* (exactly on the edge: the fill rule's) */
			}
			a < b ? inside++ : outside++;
			for (int c = 0; c < 4; c++) {
				if (abs((int)got[c] - (int)want[c]) > 1) {
					(*wrong)++;
					break;
				}
			}
		}
	}
	return [NSString stringWithFormat:@"%u inside, %u outside, %u wrong; the middle B G R A %u %u %u %u", inside, outside,
	    *wrong, p[(h / 2 * w + w / 2) * 4], p[(h / 2 * w + w / 2) * 4 + 1], p[(h / 2 * w + w / 2) * 4 + 2],
	    p[(h / 2 * w + w / 2) * 4 + 3]];
}

static void
test_metal_triangle_offscreen(MetalTest *t)
{
	MTLTextureDescriptor *d;
	id<MTLTexture> texture;
	NSString *problem = nil, *counts;
	unsigned wrong;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64
	    mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	if ((texture = [g_device newTextureWithDescriptor:d]) == nil) {
		[t fail:@"no 64x64 BGRA8 texture"];
		return;
	}
	if (!draw_triangle(texture, nil, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	counts = triangle_mismatches(texture, &wrong);
	if (wrong == 0) {
		[t pass:@"an orange triangle over blue, every pixel where it belongs: %@", counts];
	} else {
		[t fail:@"%@", counts];
	}
}

/* the same on the screen, below the blue square; read back from the drawable and left up */
static void
test_metal_triangle_layer(MetalTest *t)
{
	static UIView *stage;
	CAMetalLayer *layer;
	id<CAMetalDrawable> drawable;
	NSString *problem = nil, *counts;
	unsigned wrong;

	if (g_device == nil || g_stage == nil) {
		[t skip:@"%@", g_device == nil ? @"no device" : @"nowhere on the screen to put a layer"];
		return;
	}
	if (stage == nil) {
		stage = [[UIView alloc] initWithFrame:CGRectOffset(g_stage.frame, 0, g_stage.frame.size.height + 16)];
		stage.backgroundColor = UIColor.blackColor;
		stage.userInteractionEnabled = NO;
		[g_stage.superview addSubview:stage];
	}
	layer = [CAMetalLayer layer];
	layer.device = g_device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = NO;
	layer.frame = stage.bounds;
	layer.contentsScale = UIScreen.mainScreen.scale;
	layer.drawableSize = CGSizeMake(stage.bounds.size.width * layer.contentsScale,
	    stage.bounds.size.height * layer.contentsScale);
	[stage.layer addSublayer:layer];
	if ((drawable = [layer nextDrawable]) == nil) {
		[t fail:@"the layer gave no drawable"];
		return;
	}
	if (!draw_triangle(drawable.texture, drawable, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	counts = triangle_mismatches(drawable.texture, &wrong);
	if (wrong == 0) {
		[t pass:@"presented (below the blue square): %@", counts];
	} else {
		[t fail:@"presented; read back: %@", counts];
	}
}

/*
 * Compute, again with nothing compiled here: AV1SW.metallib's BlitKernel_Unorm (the system's AV1 decoder ships it) is
 * dst.write(src.read(gid), gid) over texture2d<half> -- dst at texture 0, src at 1 -- bounds-checked against dst while
 * its function constant kNonUniformDispatch is 0, which is what a driver without Metal's compiler takes it to be. A
 * 32x32 pattern copied through it on the GPU must come back the same.
 */
#define AV1SW_LIBRARY   "/System/Library/VideoDecoders/AV1SW.metallib"
static BOOL g_unorm8;                   /* metal.compute.unorm8: the RGBA8Unorm round instead (test_metal_compute8) */

/* (half helpers for the RGBA16Float round: values of k/32, exact in a half) */
static uint16_t
half_of(float f)
{
	__fp16 h = (__fp16)f;
	uint16_t bits;

	memcpy(&bits, &h, sizeof(bits));
	return bits;
}

/*
 * The same kernel over RGBA16Float textures: the half the kernel stores is the texel's own format there, nothing to
 * convert. (On the K40 port, 2026-11-08, the RGBA8Unorm round came back as each half's low byte: a format-less store
 * that the bound format does not convert. This round tells the kernel and the dispatch from that conversion.)
 */
static NSString *
compute_half_round(id<MTLComputePipelineState> pipeline, unsigned *wrong)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:32
	    height:32 mipmapped:NO];
	id<MTLTexture> src, dst;
	id<MTLCommandBuffer> buffer;
	id<MTLComputeCommandEncoder> encoder;
	uint16_t in[32 * 32 * 4], out[32 * 32 * 4];

	*wrong = 0;
	d.usage = MTLTextureUsageShaderRead;
	src = [g_device newTextureWithDescriptor:d];
	d.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
	dst = [g_device newTextureWithDescriptor:d];
	if (src == nil || dst == nil) {
		return @"no RGBA16Float textures";
	}
	for (unsigned y = 0; y < 32; y++) {
		for (unsigned x = 0; x < 32; x++) {
			uint16_t *p = in + (y * 32 + x) * 4;

			p[0] = half_of(x / 32.0f);
			p[1] = half_of(y / 32.0f);
			p[2] = half_of((x + y) / 64.0f);
			p[3] = half_of(1.0f);
		}
	}
	[src replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:in bytesPerRow:32 * 8];
	buffer = [[g_device newCommandQueue] commandBuffer];
	encoder = [buffer computeCommandEncoder];
	[encoder setComputePipelineState:pipeline];
	[encoder setTexture:dst atIndex:0];
	[encoder setTexture:src atIndex:1];
	[encoder dispatchThreadgroups:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	if (buffer.status != MTLCommandBufferStatusCompleted) {
		return [NSString stringWithFormat:@"RGBA16Float: status %ld", (long)buffer.status];
	}
	memset(out, 0, sizeof(out));
	[dst getBytes:out bytesPerRow:32 * 8 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
	for (unsigned i = 0; i < 32 * 32 * 4; i++) {
		*wrong += in[i] != out[i];
	}
	return [NSString stringWithFormat:@"RGBA16Float: %u of %u halves wrong; (5,7) %04x %04x %04x %04x -> %04x %04x %04x %04x",
	    *wrong, 32 * 32 * 4, in[(7 * 32 + 5) * 4], in[(7 * 32 + 5) * 4 + 1], in[(7 * 32 + 5) * 4 + 2], in[(7 * 32 + 5) * 4 + 3],
	    out[(7 * 32 + 5) * 4], out[(7 * 32 + 5) * 4 + 1], out[(7 * 32 + 5) * 4 + 2], out[(7 * 32 + 5) * 4 + 3]];
}

static void
test_metal_compute(MetalTest *t)
{
	NSData *data;
	id<MTLLibrary> library;
	id<MTLFunction> kernel;
	id<MTLComputePipelineState> pipeline;
	MTLTextureDescriptor *d;
	id<MTLTexture> src, dst;
	id<MTLCommandQueue> queue;
	id<MTLCommandBuffer> buffer;
	id<MTLComputeCommandEncoder> encoder;
	NSError *error = nil;
	unsigned char in[32 * 32 * 4], out[32 * 32 * 4];
	unsigned wrong = 0;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if ((data = [NSData dataWithContentsOfFile:@AV1SW_LIBRARY]) == nil) {
		[t skip:@"no " AV1SW_LIBRARY];
		return;
	}
	library = [g_device newLibraryWithData:dispatch_data_create(data.bytes, data.length, NULL,
	    DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&error];
	if (library == nil || (kernel = [library newFunctionWithName:@"BlitKernel_Unorm"]) == nil) {
		[t fail:@"no BlitKernel_Unorm (%@)", error.localizedDescription ?: @"not in the library"];
		return;
	}
	if ((pipeline = [g_device newComputePipelineStateWithFunction:kernel error:&error]) == nil) {
		[t fail:@"no compute pipeline: %@", error.localizedDescription];
		return;
	}
	[t note:@"pipeline: %lu threads a group at most, %lu wide", (unsigned long)pipeline.maxTotalThreadsPerThreadgroup,
	    (unsigned long)pipeline.threadExecutionWidth];
	if (g_unorm8) {
		goto unorm8;
	}
	{
		unsigned half_wrong;
		NSString *half = compute_half_round(pipeline, &half_wrong);

		if (half_wrong != 0) {
			[t fail:@"%@", half];
		} else {
			[t pass:@"BlitKernel_Unorm (the system's AV1 decoder's) copied a 32x32 RGBA16Float pattern on the GPU: %@", half];
		}
		return;
	}
unorm8:
	for (unsigned y = 0; y < 32; y++) {
		for (unsigned x = 0; x < 32; x++) {
			unsigned char *p = in + (y * 32 + x) * 4;

			p[0] = (unsigned char)(x * 8);
			p[1] = (unsigned char)(y * 8);
			p[2] = (unsigned char)((x + y) * 4);
			p[3] = 255;
		}
	}
	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead;
	src = [g_device newTextureWithDescriptor:d];
	d.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
	dst = [g_device newTextureWithDescriptor:d];
	if (src == nil || dst == nil) {
		[t fail:@"no 32x32 RGBA8 textures"];
		return;
	}
	[src replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:in bytesPerRow:32 * 4];
	queue = [g_device newCommandQueue];
	buffer = [queue commandBuffer];
	if ((encoder = [buffer computeCommandEncoder]) == nil) {
		[t fail:@"no compute encoder"];
		return;
	}
	[encoder setComputePipelineState:pipeline];
	[encoder setTexture:dst atIndex:0];
	[encoder setTexture:src atIndex:1];
	[encoder dispatchThreadgroups:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	if (buffer.status != MTLCommandBufferStatusCompleted) {
		[t fail:@"the command buffer ended with status %ld%@", (long)buffer.status, buffer.error != nil ? [NSString
		    stringWithFormat:@": %@", buffer.error.localizedDescription] : @""];
		return;
	}
	memset(out, 0, sizeof(out));
	[dst getBytes:out bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
	for (unsigned i = 0; i < sizeof(in); i++) {
		wrong += abs((int)in[i] - (int)out[i]) > 1;
	}
	if (wrong == 0) {
		[t pass:@"BlitKernel_Unorm (the system's AV1 decoder's) copied a 32x32 pattern on the GPU: every texel back"];
	} else {
		static const unsigned at[][2] = { { 0, 0 }, { 1, 0 }, { 5, 7 }, { 31, 0 }, { 0, 31 }, { 31, 31 } };
		NSMutableString *texels = [NSMutableString string];

		for (size_t i = 0; i < sizeof(at) / sizeof(at[0]); i++) {
			const unsigned char *a = in + (at[i][1] * 32 + at[i][0]) * 4, *b = out + (at[i][1] * 32 + at[i][0]) * 4;

			[texels appendFormat:@"; (%u,%u) %u %u %u %u -> %u %u %u %u", at[i][0], at[i][1], a[0], a[1], a[2], a[3], b[0],
			    b[1], b[2], b[3]];
		}
		[t fail:@"%u of %zu bytes wrong (the half the kernel stores, not converted to the texture's unorm format?)%@", wrong,
		    sizeof(in), texels];
	}
}

/* the same kernel with RGBA8Unorm textures: the half it stores is converted to unorm by the texture's format */
static void
test_metal_compute8(MetalTest *t)
{
	g_unorm8 = YES;
	test_metal_compute(t);
	g_unorm8 = NO;
}

static const struct {
	const char *ident;
	void (*run)(MetalTest *);
} g_tests[] = {
	{ "system", test_system },
	{ "app.no_opengles", test_no_opengles },
	{ "gpu.service", test_gpu_service },
	{ "gpu.params", test_gpu_params },
	{ "metal.services", test_metal_services },
	{ "metal.private", test_metal_private },
	{ "metal.adddevice", test_metal_adddevice },
	{ "metal.device", test_metal_device },
	{ "metal.register", test_metal_register },
	{ "metal.queue70", test_metal_queue70 },
	{ "metal.clear.offscreen", test_metal_clear_offscreen },
	{ "metal.clear.layer", test_metal_clear_layer },
	{ "metal.triangle.offscreen", test_metal_triangle_offscreen },
	{ "metal.triangle.layer", test_metal_triangle_layer },
	{ "metal.compute", test_metal_compute },
	{ "metal.compute.unorm8", test_metal_compute8 },
};
#define TEST_COUNT      (sizeof(g_tests) / sizeof(g_tests[0]))

#pragma mark a crash: written down on the way out

static volatile sig_atomic_t g_running = -1;   /* the test running now, by index; -1: none */

/* (called by the process's handler, main.m's, which then lets the signal take the application down) */
static void
crashed(int signal_number)
{
	static const char *const names[NSIG] = { [SIGSEGV] = "SIGSEGV", [SIGBUS] = "SIGBUS", [SIGILL] = "SIGILL",
	    [SIGABRT] = "SIGABRT", [SIGTRAP] = "SIGTRAP", [SIGFPE] = "SIGFPE" };
	const char *name = signal_number > 0 && signal_number < NSIG && names[signal_number] != NULL ? names[signal_number] :
	    "a signal";
	int running = g_running;

	if (running >= 0 && running < (int)TEST_COUNT) {
		const char *ident = g_tests[running].ident;
		char line[256];
		int n;

		n = snprintf(line, sizeof(line), "crashed\t%s\t%s\n", ident, name);
		if (g_log >= 0 && n > 0) {
			(void)write(g_log, line, (size_t)n);
			(void)fsync(g_log);
		}
		n = snprintf(line, sizeof(line), "metalcheck: %s CRASHED %s (the next launch marks it and goes on)\n", ident,
		    name);
		if (g_console >= 0 && n > 0) {
			(void)write(g_console, line, (size_t)n);
		}
	}
}

static void
uncaught(NSException *exception)
{
	int running = g_running;

	if (running >= 0 && running < (int)TEST_COUNT) {
		record("crashed", g_tests[running].ident, [NSString stringWithFormat:@"%@: %@", exception.name,
		    exception.reason]);
		say(@"%s CRASHED %@: %@ (the next launch marks it and goes on)", g_tests[running].ident, exception.name,
		    exception.reason);
	}
}

#pragma mark the screen

@interface MetalController : UITableViewController
@end

@implementation MetalController {
	NSMutableArray<MetalTest *> *_tests;
	NSMutableSet<NSString *> *_marked;
	NSString *_summary;
	BOOL _ran, _runWhenShown;
}

- (instancetype)init
{
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]) != nil) {
		self.title = @"Metal Check";
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Run"
		    style:UIBarButtonItemStylePlain target:self action:@selector(runButton)];
		_marked = [NSMutableSet set];
		_summary = @"Run: the tests, in order (they take a few seconds)";
	}
	return self;
}

/* the on-screen tests' stage: a black square at the top right of the list, the triangle's below it (the test puts it
   there), what they are on the left */
- (void)viewDidLoad
{
	UIView *header;
	UILabel *what;
	CGFloat width = self.view.bounds.size.width;

	[super viewDidLoad];
	header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 8 + 120 + 16 + 120 + 8)];
	g_stage = [[UIView alloc] initWithFrame:CGRectMake(width - 136, 8, 120, 120)];
	g_stage.backgroundColor = UIColor.blackColor;
	g_stage.userInteractionEnabled = NO;
	g_stage.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	[header addSubview:g_stage];
	what = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, width - 136 - 36, 256)];
	what.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	what.numberOfLines = 0;
	what.font = [UIFont systemFontOfSize:12];
	what.textColor = UIColor.secondaryLabelColor;
	what.text = @"On the right, what the on-screen tests leave up: the top square cleared to blue "
	    "(metal.clear.layer), the one below it with an orange triangle (metal.triangle.layer). Black: not drawn.";
	[header addSubview:what];
	self.tableView.tableHeaderView = header;
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	if (_runWhenShown) {
		_runWhenShown = NO;
		[self runButton];
	}
}

- (void)runWhenShown
{
	if (self.viewIfLoaded.window != nil) {
		[self runButton];
	} else {
		_runWhenShown = YES;
	}
}

/* Run: the first in a launch keeps the marks of earlier launches; Run again forgets them */
- (void)runButton
{
	if (_ran) {
		[self runAgain];
	} else {
		_ran = YES;
		self.navigationItem.rightBarButtonItem.title = @"Run again";
		[self run];
	}
}

/* What the log says of earlier launches: the tests marked since the last Run again, and the one that took the last
 * launch down (it was "running" and has no result), which is marked now. */
- (NSString *)readMarks
{
	NSString *text = [NSString stringWithContentsOfFile:log_path() encoding:NSUTF8StringEncoding error:nil] ?: @"";
	NSString *running = nil;

	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];

		if (f.count < 2) {
			continue;
		}
		if ([f[0] isEqualToString:@"again"]) {
			[_marked removeAllObjects];
		} else if ([f[0] isEqualToString:@"mark"]) {
			[_marked addObject:f[1]];
		} else if ([f[0] isEqualToString:@"running"]) {
			running = f[1];
		} else if ([f[0] isEqualToString:@"result"] || [f[0] isEqualToString:@"run"]) {
			running = nil;
		}
	}
	if (running != nil && ![_marked containsObject:running]) {
		[_marked addObject:running];
		record("mark", running.UTF8String, @"it took the last launch down");
		return running;
	}
	return nil;
}

- (void)runAgain
{
	record("again", "-", @"the marks forgotten");
	[_marked removeAllObjects];
	[self run];
}

- (void)run
{
	NSString *crashedLast = [self readMarks];
	CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
	int counts[ST_COUNT] = { 0 };

	_tests = [NSMutableArray array];
	record("run", "-", [NSString stringWithFormat:@"%@ %@", UIDevice.currentDevice.systemVersion,
	    sysctl_string("kern.osversion")]);
	say(@"run: %zu tests%@", TEST_COUNT, crashedLast != nil ? [NSString stringWithFormat:@" (%@ took the last launch "
	    "down: marked, skipped until Run again)", crashedLast] : @"");
	for (size_t i = 0; i < TEST_COUNT; i++) {
		MetalTest *t = [[MetalTest alloc] initWithIdent:g_tests[i].ident];

		[_tests addObject:t];
		if ([_marked containsObject:@(t.ident)]) {
			[t verdict:ST_CRASHED detail:@"took the application down at an earlier launch (Run again to try it)"];
		} else {
			record("running", t.ident, @"");
			g_running = (sig_atomic_t)i;
			[t verdict:ST_RUNNING detail:@""];
			g_tests[i].run(t);
			g_running = -1;
		}
		counts[t.status]++;
		record("result", t.ident, [NSString stringWithFormat:@"%s\t%@", status_c[t.status], t.detail]);
		say(@"%s %s %@", t.ident, status_c[t.status], t.detail);
	}
	_summary = [NSString stringWithFormat:@"done %d pass, %d fail, %d crashed, %d skipped (%zu tests, %.1f s)",
	    counts[ST_PASS], counts[ST_FAIL], counts[ST_CRASHED], counts[ST_SKIP], TEST_COUNT,
	    CFAbsoluteTimeGetCurrent() - began];
	record("done", "-", _summary);
	say(@"%@", _summary);
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return (NSInteger)_tests.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return [NSString stringWithFormat:@"iOS %@ (%@), %@", UIDevice.currentDevice.systemVersion,
	    sysctl_string("kern.osversion"), sysctl_string("hw.machine")];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	return _summary;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"test"] ?:
	    [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"test"];
	MetalTest *t = _tests[(NSUInteger)indexPath.row];
	NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:t.detail];

	[lines addObjectsFromArray:t.notes];
	cell.textLabel.text = [NSString stringWithFormat:@"%s  %s", status_c[t.status], t.ident];
	cell.textLabel.textColor = status_color(t.status);
	cell.textLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];
	cell.detailTextLabel.text = [lines componentsJoinedByString:@"\n"];
	cell.detailTextLabel.numberOfLines = 0;
	cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}

@end

#pragma mark the tab

static MetalController *g_controller;

UIViewController *
metal_controller(void)
{
	if (g_controller == nil) {
		g_log = open(log_path().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
		g_console = open("/dev/console", O_WRONLY | O_NOCTTY);
		if (g_console < 0) {
			NSLog(@"metalcheck: /dev/console: %s (results go to NSLog and the log only)", strerror(errno));
		}
		check_watch_crashes(crashed, uncaught);
		g_controller = [MetalController new];
	}
	return g_controller;
}

void
metal_run(void)
{
	[(MetalController *)metal_controller() runWhenShown];
}
