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
#import <MapKit/MapKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>
#import <SpriteKit/SpriteKit.h>
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

/* Does the main program itself load this library (its load commands, not what others brought in)? (Its header is
   _mh_execute_header: dyld's image 0 is not always the program -- on the K40 port it was not.) */
extern const struct mach_header_64 _mh_execute_header;

static BOOL
main_links(const char *library)
{
	const struct mach_header_64 *header = &_mh_execute_header;
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

#pragma mark our own shaders: alioth-tests.metallib (github.com/xiongnemo/ios-alioth-devtools, metal/alioth-tests.metal)

/*
 * One thing each, with what it must give computed here: a real vertex function, vertex buffers, a texture through a
 * sampler, blending, a viewport, depth, multisampling; compute into buffers, into an RGBA8 texture, through
 * threadgroup memory, with function constants; the blit encoder; and SpriteKit and SceneKit on this device. Built
 * by Xcode's compiler in that repository's CI, for iOS 16, and carried in this application (build.sh fetches it).
 */
static id<MTLLibrary> g_ours;           /* after metal.lib */

/* a command buffer to its end: NO, and why, when it did not complete */
static BOOL
finish(id<MTLCommandBuffer> buffer, NSString **problem)
{
	[buffer commit];
	[buffer waitUntilCompleted];
	if (buffer.status != MTLCommandBufferStatusCompleted) {
		*problem = [NSString stringWithFormat:@"the command buffer ended with status %ld%@", (long)buffer.status,
		    buffer.error != nil ? [NSString stringWithFormat:@": %@", buffer.error.localizedDescription] : @""];
		return NO;
	}
	return YES;
}

/* no device, or no library of ours: SKIP said, NO returned */
static BOOL
ours_ready(MetalTest *t)
{
	if (g_device == nil) {
		[t skip:@"no device"];
		return NO;
	}
	if (g_ours == nil) {
		[t skip:@"no alioth-tests.metallib (metal.lib)"];
		return NO;
	}
	return YES;
}

static void
test_metal_lib(MetalTest *t)
{
	NSString *path = [NSBundle.mainBundle pathForResource:@"alioth-tests" ofType:@"metallib"];
	NSArray<NSString *> *wanted = @[ @"v_fullscreen", @"v_colored", @"f_color", @"f_solid", @"f_texture", @"k_iota",
	    @"k_add", @"k_gradient", @"k_reduce", @"k_constants" ];
	NSMutableArray<NSString *> *missing = [NSMutableArray array];
	NSError *error = nil;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if (path == nil) {
		[t fail:@"no alioth-tests.metallib in the application"];
		return;
	}
	if ((g_ours = [g_device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error]) == nil) {
		[t fail:@"newLibraryWithURL: %@", error.localizedDescription ?: @"nil, no error"];
		return;
	}
	[t note:@"its functions: %@", [g_ours.functionNames componentsJoinedByString:@" "]];
	for (NSString *name in wanted) {
		if (![g_ours.functionNames containsObject:name]) {
			[missing addObject:name];
		}
	}
	if (missing.count > 0) {
		[t fail:@"not in it: %@", [missing componentsJoinedByString:@" "]];
		g_ours = nil;
	} else {
		[t pass:@"alioth-tests.metallib: %lu functions", (unsigned long)g_ours.functionNames.count];
	}
}

#define SIDE 64         /* the render tests' target: SIDE x SIDE, BGRA8 */

/*
 * A SIDE x SIDE BGRA8 target cleared to `clear`, drawn into with a pipeline of our vertex and fragment functions
 * (`setup` may change its descriptor: blending, depth, samples), `draw` making the draws; read back into px
 * (B G R A, rows from the top). NO, and why, when it could not.
 */
static BOOL
render_ours(NSString *vertex, NSString *fragment, MTLClearColor clear, void (^setup)(MTLRenderPipelineDescriptor *),
    void (^pass_setup)(MTLRenderPassDescriptor *), void (^draw)(id<MTLRenderCommandEncoder>), unsigned char *px,
    NSString **problem)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	    width:SIDE height:SIDE mipmapped:NO];
	MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	id<MTLRenderPipelineState> pipeline;
	id<MTLTexture> target;
	id<MTLCommandQueue> queue;
	id<MTLCommandBuffer> buffer;
	id<MTLRenderCommandEncoder> encoder;
	NSError *error = nil;

	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	if ((target = [g_device newTextureWithDescriptor:d]) == nil) {
		*problem = @"no target texture";
		return NO;
	}
	p.vertexFunction = [g_ours newFunctionWithName:vertex];
	p.fragmentFunction = [g_ours newFunctionWithName:fragment];
	p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	if (setup != nil) {
		setup(p);
	}
	if ((pipeline = [g_device newRenderPipelineStateWithDescriptor:p error:&error]) == nil) {
		*problem = [NSString stringWithFormat:@"no pipeline (%@ + %@): %@", vertex, fragment,
		    error.localizedDescription ?: @"nil, no error"];
		return NO;
	}
	pass.colorAttachments[0].texture = target;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = clear;
	if (pass_setup != nil) {
		pass_setup(pass);
	}
	queue = [g_device newCommandQueue];
	buffer = [queue commandBuffer];
	if ((encoder = [buffer renderCommandEncoderWithDescriptor:pass]) == nil) {
		*problem = @"no render encoder";
		return NO;
	}
	[encoder setRenderPipelineState:pipeline];
	draw(encoder);
	[encoder endEncoding];
	if (!finish(buffer, problem)) {
		return NO;
	}
	[target getBytes:px bytesPerRow:SIDE * 4 fromRegion:MTLRegionMake2D(0, 0, SIDE, SIDE) mipmapLevel:0];
	return YES;
}

/* a pixel's expected B G R A against what came back, within tol; its text when wrong */
static BOOL
px_near(const unsigned char *got, unsigned b, unsigned g, unsigned r, unsigned a, unsigned tol)
{
	return abs((int)got[0] - (int)b) <= (int)tol && abs((int)got[1] - (int)g) <= (int)tol &&
	    abs((int)got[2] - (int)r) <= (int)tol && abs((int)got[3] - (int)a) <= (int)tol;
}

static NSString *
px_text(const unsigned char *px, unsigned x, unsigned y)
{
	const unsigned char *p = px + (y * SIDE + x) * 4;

	return [NSString stringWithFormat:@"(%u,%u) %u %u %u %u", x, y, p[0], p[1], p[2], p[3]];
}

/* v_fullscreen + f_solid: a real vertex function (from the vertex index alone), one colour from fragment buffer 0 */
static void
test_metal_vertex(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	if (!render_ours(@"v_fullscreen", @"f_solid", MTLClearColorMake(0, 0, 0, 1), nil, nil,
	    ^(id<MTLRenderCommandEncoder> e) {
		    const float colour[4] = { 0.25f, 0.5f, 0.75f, 1.0f };

		    [e setFragmentBytes:colour length:sizeof(colour) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned i = 0; i < SIDE * SIDE; i++) {
		wrong += !px_near(px + i * 4, 191, 128, 64, 255, 2);
	}
	if (wrong == 0) {
		[t pass:@"every pixel B G R A 191 128 64 255: the vertex function made the triangle, the fragment its colour"];
	} else {
		[t fail:@"%u of %u pixels wrong; %@, %@", wrong, SIDE * SIDE, px_text(px, SIDE / 2, SIDE / 2), px_text(px, 0, 0)];
	}
}

/* v_colored + f_color: positions and colours from vertex buffer 0, the colour interpolated -- red, green, blue corners */
static void
test_metal_vbuffer(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0, inside = 0, outside = 0;
	NSString *first = nil;

	if (!ours_ready(t)) {
		return;
	}
	if (!render_ours(@"v_colored", @"f_color", MTLClearColorMake(0, 0, 0, 1), nil, nil,
	    ^(id<MTLRenderCommandEncoder> e) {
		    /* (struct Vertex { float4 position; float4 color; }: the lower left half, red, green, blue at its corners) */
		    const float v[3][8] = {
			    { -1, -1, 0, 1, 1, 0, 0, 1 }, { 1, -1, 0, 1, 0, 1, 0, 1 }, { -1, 1, 0, 1, 0, 0, 1, 1 },
		    };

		    [e setVertexBytes:v length:sizeof(v) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			/* the pixel's centre in clip space (y up; row 0 is the top), and its weights for the three corners */
			float cx = (x + 0.5f) / SIDE * 2 - 1, cy = 1 - (y + 0.5f) / SIDE * 2;
			float wg = (cx + 1) / 2, wb = (cy + 1) / 2, wr = -(cx + cy) / 2;
			const unsigned char *p = px + (y * SIDE + x) * 4;
			BOOL ok;

			if (fabsf(cx + cy) < 2.0f / SIDE) {
				continue;       /* (the diagonal edge: which pixels it takes is the rasteriser's rule) */
			}
			if (cx + cy < 0) {
				inside++;
				ok = px_near(p, (unsigned)lroundf(wb * 255), (unsigned)lroundf(wg * 255),
				    (unsigned)lroundf(wr * 255), 255, 4);
			} else {
				outside++;
				ok = px_near(p, 0, 0, 0, 255, 0);
			}
			if (!ok) {
				wrong++;
				if (first == nil) {
					first = px_text(px, x, y);
				}
			}
		}
	}
	if (wrong == 0) {
		[t pass:@"%u pixels inside interpolated right, %u outside left as cleared", inside, outside];
	} else {
		[t fail:@"%u of %u pixels wrong, the first %@; the middle of the triangle %@", wrong, inside + outside, first,
		    px_text(px, SIDE / 4, SIDE * 3 / 4)];
	}
}

/* v_fullscreen + f_texture: a 4x4 RGBA8 texture, nearest, over the whole target -- 16x16 blocks of its texels */
static void
test_metal_texture(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	unsigned char texels[4 * 4 * 4];
	MTLTextureDescriptor *d;
	MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];
	__block id<MTLTexture> texture;
	__block id<MTLSamplerState> sampler;
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	for (unsigned j = 0; j < 4; j++) {
		for (unsigned i = 0; i < 4; i++) {
			unsigned char *p = texels + (j * 4 + i) * 4;

			p[0] = (unsigned char)(i * 64 + 32);    /* R */
			p[1] = (unsigned char)(j * 64 + 32);    /* G */
			p[2] = 128;                             /* B */
			p[3] = 255;
		}
	}
	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead;
	if ((texture = [g_device newTextureWithDescriptor:d]) == nil) {
		[t fail:@"no 4x4 RGBA8 texture"];
		return;
	}
	[texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
	s.minFilter = MTLSamplerMinMagFilterNearest;
	s.magFilter = MTLSamplerMinMagFilterNearest;
	s.sAddressMode = MTLSamplerAddressModeClampToEdge;
	s.tAddressMode = MTLSamplerAddressModeClampToEdge;
	if ((sampler = [g_device newSamplerStateWithDescriptor:s]) == nil) {
		[t fail:@"no sampler"];
		return;
	}
	if (!render_ours(@"v_fullscreen", @"f_texture", MTLClearColorMake(0, 0, 0, 1), nil, nil,
	    ^(id<MTLRenderCommandEncoder> e) {
		    [e setFragmentTexture:texture atIndex:0];
		    [e setFragmentSamplerState:sampler atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			unsigned i = x / (SIDE / 4), j = y / (SIDE / 4);

			wrong += !px_near(px + (y * SIDE + x) * 4, 128, j * 64 + 32, i * 64 + 32, 255, 1);
		}
	}
	if (wrong == 0) {
		[t pass:@"16x16 blocks of the texture's 4x4 texels, every pixel right"];
	} else {
		[t fail:@"%u of %u pixels wrong; %@ (texel 0,0: B G R A 128 32 32 255), %@ (texel 3,3: 128 224 224 255)", wrong,
		    SIDE * SIDE, px_text(px, 8, 8), px_text(px, SIDE - 8, SIDE - 8)];
	}
}

/* f_solid at half alpha over blue, blended (source alpha, one minus source alpha) */
static void
test_metal_blend(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	if (!render_ours(@"v_fullscreen", @"f_solid", MTLClearColorMake(0, 0, 1, 1), ^(MTLRenderPipelineDescriptor *p) {
		    p.colorAttachments[0].blendingEnabled = YES;
		    p.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		    p.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		    p.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
		    p.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	    }, nil, ^(id<MTLRenderCommandEncoder> e) {
		    const float colour[4] = { 1, 0, 0, 0.5f };

		    [e setFragmentBytes:colour length:sizeof(colour) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned i = 0; i < SIDE * SIDE; i++) {
		wrong += !px_near(px + i * 4, 128, 0, 128, 255, 2);
	}
	if (wrong == 0) {
		[t pass:@"half red over blue: every pixel B G R A 128 0 128 255"];
	} else {
		[t fail:@"%u of %u pixels wrong; the middle %@ (wanted 128 0 128 255)", wrong, SIDE * SIDE,
		    px_text(px, SIDE / 2, SIDE / 2)];
	}
}

/* a viewport over the top left quarter only: green there, the clear colour elsewhere */
static void
test_metal_viewport(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	if (!render_ours(@"v_fullscreen", @"f_solid", MTLClearColorMake(0, 0, 0, 1), nil, nil,
	    ^(id<MTLRenderCommandEncoder> e) {
		    const float colour[4] = { 0, 1, 0, 1 };
		    MTLViewport quarter = { 0, 0, SIDE / 2, SIDE / 2, 0, 1 };

		    [e setViewport:quarter];
		    [e setFragmentBytes:colour length:sizeof(colour) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			BOOL in = x < SIDE / 2 && y < SIDE / 2;

			wrong += !px_near(px + (y * SIDE + x) * 4, 0, in ? 255 : 0, 0, 255, 1);
		}
	}
	if (wrong == 0) {
		[t pass:@"green in the top left quarter only"];
	} else {
		[t fail:@"%u of %u pixels wrong; %@ (green wanted), %@ (black wanted)", wrong, SIDE * SIDE, px_text(px, 8, 8),
		    px_text(px, SIDE - 8, SIDE - 8)];
	}
}

/* scissor: the full-screen triangle through a scissor of the top left quarter -- green there only */
static void
test_metal_scissor(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	if (!render_ours(@"v_fullscreen", @"f_solid", MTLClearColorMake(0, 0, 0, 1), nil, nil,
	    ^(id<MTLRenderCommandEncoder> e) {
		    const float colour[4] = { 0, 1, 0, 1 };
		    MTLScissorRect quarter = { 0, 0, SIDE / 2, SIDE / 2 };

		    [e setScissorRect:quarter];
		    [e setFragmentBytes:colour length:sizeof(colour) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			BOOL in = x < SIDE / 2 && y < SIDE / 2;

			wrong += !px_near(px + (y * SIDE + x) * 4, 0, in ? 255 : 0, 0, 255, 1);
		}
	}
	if (wrong == 0) {
		[t pass:@"green in the top left quarter only"];
	} else {
		[t fail:@"%u of %u pixels wrong; %@ (green wanted), %@ (black wanted)", wrong, SIDE * SIDE, px_text(px, 8, 8),
		    px_text(px, SIDE - 8, SIDE - 8)];
	}
}

/* (a pixel next to the middle row or column, where a clipped edge may fall either way) */
static BOOL
near_middle(unsigned v)
{
	return v == SIDE / 2 - 1 || v == SIDE / 2;
}

/*
 * clip distances: the whole-target triangle with [[clip_distance]] [1] -- its clip-space x, so green on the right half
 * only -- and with [2], x and y (up), so the top right quarter only (VectorKit's route lines use the first shape)
 */
static void
test_metal_clip(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong1 = 0, wrong2 = 0;
	void (^draw)(id<MTLRenderCommandEncoder>) = ^(id<MTLRenderCommandEncoder> e) {
		const float colour[4] = { 0, 1, 0, 1 };

		[e setFragmentBytes:colour length:sizeof(colour) atIndex:0];
		[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	};

	if (!ours_ready(t)) {
		return;
	}
	if ([g_ours newFunctionWithName:@"v_clip1"] == nil) {
		[t skip:@"this alioth-tests.metallib has no v_clip1 (devtools v3 has it)"];
		return;
	}
	if (!render_ours(@"v_clip1", @"f_solid", MTLClearColorMake(0, 0, 0, 1), nil, nil, draw, px, &problem)) {
		[t fail:@"one distance: %@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			if (!near_middle(x)) {
				wrong1 += !px_near(px + (y * SIDE + x) * 4, 0, x >= SIDE / 2 ? 255 : 0, 0, 255, 1);
			}
		}
	}
	NSString *left = px_text(px, 8, SIDE / 2), *right = px_text(px, SIDE - 8, SIDE / 2);
	if (!render_ours(@"v_clip2", @"f_solid", MTLClearColorMake(0, 0, 0, 1), nil, nil, draw, px, &problem)) {
		[t fail:@"two distances: %@ (one distance: %u pixels wrong)", problem, wrong1];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			if (!near_middle(x) && !near_middle(y)) {
				BOOL in = x >= SIDE / 2 && y < SIDE / 2;

				wrong2 += !px_near(px + (y * SIDE + x) * 4, 0, in ? 255 : 0, 0, 255, 1);
			}
		}
	}
	if (wrong1 == 0 && wrong2 == 0) {
		[t pass:@"[1]: green on the right half only; [2]: the top right quarter only"];
	} else {
		[t fail:@"[1]: %u pixels wrong (left %@, right %@); [2]: %u wrong (top right %@, bottom left %@)", wrong1, left,
		    right, wrong2, px_text(px, SIDE - 8, 8), px_text(px, 8, SIDE - 8)];
	}
}

/*
 * cull mode and winding: a red triangle on the left whose corners run counter-clockwise (Metal's y up) and a green
 * one on the right running clockwise, front faces counter-clockwise. Culling back faces keeps the red one only;
 * culling front faces the green one only. (Metal's winding is GL's sense: a mesh wound counter-clockwise, drawn with
 * counter-clockwise front faces and back faces culled, is what Apple's own samples draw.)
 */
static void
test_metal_cull(MetalTest *t)
{
	static unsigned char px[2][SIDE * SIDE * 4];
	NSString *problem = nil;
	const NSUInteger modes[2] = { MTLCullModeBack, MTLCullModeFront };

	if (!ours_ready(t)) {
		return;
	}
	for (unsigned m = 0; m < 2; m++) {
		const NSUInteger mode = modes[m];

		if (!render_ours(@"v_colored", @"f_color", MTLClearColorMake(0, 0, 1, 1), nil, nil,
		    ^(id<MTLRenderCommandEncoder> e) {
			    const float v[6][8] = {
				    /* left, counter-clockwise: bottom left, bottom right, top */
				    { -0.9f, -0.5f, 0, 1, 1, 0, 0, 1 }, { -0.1f, -0.5f, 0, 1, 1, 0, 0, 1 },
				    { -0.5f, 0.5f, 0, 1, 1, 0, 0, 1 },
				    /* right, clockwise: bottom left, top, bottom right */
				    { 0.1f, -0.5f, 0, 1, 0, 1, 0, 1 }, { 0.5f, 0.5f, 0, 1, 0, 1, 0, 1 },
				    { 0.9f, -0.5f, 0, 1, 0, 1, 0, 1 },
			    };

			    [e setFrontFacingWinding:MTLWindingCounterClockwise];
			    [e setCullMode:mode];
			    [e setVertexBytes:v length:sizeof(v) atIndex:0];
			    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		    }, px[m], &problem)) {
			[t fail:@"%@", problem];
			return;
		}
	}
	/* (BGRA; the triangles' middles at (16, 37) and (48, 37)) */
	BOOL back_ok = px_near(px[0] + (37 * SIDE + 16) * 4, 0, 0, 255, 255, 1) &&
	    px_near(px[0] + (37 * SIDE + 48) * 4, 255, 0, 0, 255, 1);
	BOOL front_ok = px_near(px[1] + (37 * SIDE + 16) * 4, 255, 0, 0, 255, 1) &&
	    px_near(px[1] + (37 * SIDE + 48) * 4, 0, 255, 0, 255, 1);

	if (back_ok && front_ok) {
		[t pass:@"back faces culled: the red (counter-clockwise) kept; front faces culled: the green kept"];
	} else {
		[t fail:@"cull back: left %@ right %@ (red, blue wanted); cull front: left %@ right %@ (blue, green wanted)",
		    px_text(px[0], 16, 37), px_text(px[0], 48, 37), px_text(px[1], 16, 37), px_text(px[1], 48, 37)];
	}
}

/* blend colour: white blended with factor BlendColor against zero, so the target is the encoder's blend colour */
static void
test_metal_blendcolor(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	if (!render_ours(@"v_fullscreen", @"f_solid", MTLClearColorMake(0, 0, 0, 1), ^(MTLRenderPipelineDescriptor *p) {
		    p.colorAttachments[0].blendingEnabled = YES;
		    p.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorBlendColor;
		    p.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorZero;
		    p.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorBlendAlpha;
		    p.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
	    }, nil, ^(id<MTLRenderCommandEncoder> e) {
		    const float white[4] = { 1, 1, 1, 1 };

		    [e setBlendColorRed:0.25f green:0.5f blue:0.75f alpha:1.0f];
		    [e setFragmentBytes:white length:sizeof(white) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned i = 0; i < SIDE * SIDE; i++) {
		wrong += !px_near(px + i * 4, 191, 128, 64, 255, 2);
	}
	if (wrong == 0) {
		[t pass:@"every pixel the blend colour, B G R A 191 128 64 255"];
	} else {
		[t fail:@"%u pixels wrong; %@ (B G R A 191 128 64 255 wanted)", wrong, px_text(px, SIDE / 2, SIDE / 2)];
	}
}

/* indirect: the full-screen triangle drawn from MTLDrawPrimitivesIndirectArguments in a buffer, green; then a red
   one whose arguments say no instances, which must draw nothing */
static void
test_metal_indirect(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	NSString *problem = nil;
	unsigned wrong = 0;
	const uint32_t args[8] = { 3, 1, 0, 0, /* (none:) */ 3, 0, 0, 0 };
	id<MTLBuffer> buffer;

	if (!ours_ready(t)) {
		return;
	}
	buffer = [g_device newBufferWithBytes:args length:sizeof(args) options:MTLResourceStorageModeShared];
	if (!render_ours(@"v_fullscreen", @"f_solid", MTLClearColorMake(0, 0, 0, 1), nil, nil,
	    ^(id<MTLRenderCommandEncoder> e) {
		    const float green[4] = { 0, 1, 0, 1 }, red[4] = { 1, 0, 0, 1 };

		    [e setFragmentBytes:green length:sizeof(green) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:buffer indirectBufferOffset:0];
		    [e setFragmentBytes:red length:sizeof(red) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:buffer indirectBufferOffset:16];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned i = 0; i < SIDE * SIDE; i++) {
		wrong += !px_near(px + i * 4, 0, 255, 0, 255, 1);
	}
	if (wrong == 0) {
		[t pass:@"green everywhere from the buffer's arguments; the no-instances draw drew nothing"];
	} else {
		[t fail:@"%u pixels wrong; %@ (green wanted)", wrong, px_text(px, SIDE / 2, SIDE / 2)];
	}
}

static BOOL dispatch_ours(id<MTLFunction> function, NSUInteger n, NSUInteger group,
    void (^bind)(id<MTLComputeCommandEncoder>), NSString **problem);    /* (with the compute tests, below) */

/* heap: a buffer from an MTLHeap, written by k_iota and read back */
static void
test_metal_heap(MetalTest *t)
{
	MTLHeapDescriptor *d = [MTLHeapDescriptor new];
	id<MTLHeap> heap;
	id<MTLBuffer> buffer;
	NSString *problem = nil;
	unsigned wrong = 0;
	const uint32_t *v;

	if (!ours_ready(t)) {
		return;
	}
	d.size = 1 << 20;
	d.storageMode = MTLStorageModeShared;
	if ((heap = [g_device newHeapWithDescriptor:d]) == nil) {
		[t fail:@"-newHeapWithDescriptor: gave nil"];
		return;
	}
	if ((buffer = [heap newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared]) == nil) {
		[t fail:@"the heap gave no buffer"];
		return;
	}
	memset(buffer.contents, 0xff, 256 * 4);
	if (!dispatch_ours([g_ours newFunctionWithName:@"k_iota"], 256, 64, ^(id<MTLComputeCommandEncoder> e) {
		    [e useHeap:heap];
		    [e setBuffer:buffer offset:0 atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	v = buffer.contents;
	for (unsigned i = 0; i < 256; i++) {
		wrong += v[i] != 3 * i + 1;
	}
	if (wrong == 0) {
		[t pass:@"a buffer of a %lu KB heap written on the GPU, every value right (heap used %lu bytes)",
		    (unsigned long)(heap.size >> 10), (unsigned long)heap.usedSize];
	} else {
		[t fail:@"%u of 256 wrong; d[1] %u (wanted 4)", wrong, v[1]];
	}
}

/* depth: a near red triangle first, then a far blue one over the whole target -- red stays where both are */
static void
test_metal_depth(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
	    width:SIDE height:SIDE mipmapped:NO];
	MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
	__block id<MTLDepthStencilState> state;
	id<MTLTexture> depth;
	NSString *problem = nil;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	d.usage = MTLTextureUsageRenderTarget;
	d.storageMode = MTLStorageModePrivate;
	ds.depthCompareFunction = MTLCompareFunctionLess;
	ds.depthWriteEnabled = YES;
	if ((depth = [g_device newTextureWithDescriptor:d]) == nil || (state = [g_device newDepthStencilStateWithDescriptor:ds])
	    == nil) {
		[t fail:@"%@", depth == nil ? @"no Depth32Float texture" : @"no depth/stencil state"];
		return;
	}
	if (!render_ours(@"v_colored", @"f_color", MTLClearColorMake(0, 0, 0, 1), ^(MTLRenderPipelineDescriptor *p) {
		    p.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	    }, ^(MTLRenderPassDescriptor *pass) {
		    pass.depthAttachment.texture = depth;
		    pass.depthAttachment.loadAction = MTLLoadActionClear;
		    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
		    pass.depthAttachment.clearDepth = 1.0;
	    }, ^(id<MTLRenderCommandEncoder> e) {
		    /* the lower left half at z 0.2, red; then a triangle over everything at z 0.8, blue */
		    const float nearer[3][8] = {
			    { -1, -1, 0.2f, 1, 1, 0, 0, 1 }, { 1, -1, 0.2f, 1, 1, 0, 0, 1 }, { -1, 1, 0.2f, 1, 1, 0, 0, 1 },
		    };
		    const float farther[3][8] = {
			    { -1, -1, 0.8f, 1, 0, 0, 1, 1 }, { 3, -1, 0.8f, 1, 0, 0, 1, 1 }, { -1, 3, 0.8f, 1, 0, 0, 1, 1 },
		    };

		    [e setDepthStencilState:state];
		    [e setVertexBytes:nearer length:sizeof(nearer) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		    [e setVertexBytes:farther length:sizeof(farther) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			float cx = (x + 0.5f) / SIDE * 2 - 1, cy = 1 - (y + 0.5f) / SIDE * 2;

			if (fabsf(cx + cy) < 2.0f / SIDE) {
				continue;
			}
			wrong += !px_near(px + (y * SIDE + x) * 4, cx + cy < 0 ? 0 : 255, 0, cx + cy < 0 ? 255 : 0, 255, 1);
		}
	}
	if (wrong == 0) {
		[t pass:@"the nearer red half kept, the farther blue only where nothing nearer was"];
	} else {
		[t fail:@"%u pixels wrong; %@ (red wanted), %@ (blue wanted)", wrong, px_text(px, 8, SIDE - 8),
		    px_text(px, SIDE - 8, 8)];
	}
}

/* 4x multisampling resolved: the triangle's inside right, its edge between the two colours */
static void
test_metal_msaa(MetalTest *t)
{
	static unsigned char px[SIDE * SIDE * 4];
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	    width:SIDE height:SIDE mipmapped:NO];
	id<MTLTexture> samples;
	NSString *problem = nil;
	unsigned wrong = 0, between = 0;

	if (!ours_ready(t)) {
		return;
	}
	if (![g_device supportsTextureSampleCount:4]) {
		[t note:@"supportsTextureSampleCount:4 says NO; tried anyway"];
	}
	d.textureType = MTLTextureType2DMultisample;
	d.sampleCount = 4;
	d.usage = MTLTextureUsageRenderTarget;
	d.storageMode = MTLStorageModePrivate;
	if ((samples = [g_device newTextureWithDescriptor:d]) == nil) {
		[t fail:@"no 4x multisample texture"];
		return;
	}
	if (!render_ours(@"v_colored", @"f_color", MTLClearColorMake(0, 0, 0, 1), ^(MTLRenderPipelineDescriptor *p) {
		    p.rasterSampleCount = 4;
	    }, ^(MTLRenderPassDescriptor *pass) {
		    pass.colorAttachments[0].resolveTexture = pass.colorAttachments[0].texture;
		    pass.colorAttachments[0].texture = samples;
		    pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	    }, ^(id<MTLRenderCommandEncoder> e) {
		    const float v[3][8] = {
			    { -1, -1, 0, 1, 1, 1, 1, 1 }, { 1, -1, 0, 1, 1, 1, 1, 1 }, { -1, 1, 0, 1, 1, 1, 1, 1 },
		    };

		    [e setVertexBytes:v length:sizeof(v) atIndex:0];
		    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	    }, px, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned y = 0; y < SIDE; y++) {
		for (unsigned x = 0; x < SIDE; x++) {
			float cx = (x + 0.5f) / SIDE * 2 - 1, cy = 1 - (y + 0.5f) / SIDE * 2;
			const unsigned char *p = px + (y * SIDE + x) * 4;

			if (fabsf(cx + cy) < 2.0f / SIDE) {
				between += p[0] > 16 && p[0] < 240;      /* (an edge pixel some samples cover: grey) */
				continue;
			}
			wrong += !px_near(p, cx + cy < 0 ? 255 : 0, cx + cy < 0 ? 255 : 0, cx + cy < 0 ? 255 : 0, 255, 1);
		}
	}
	if (wrong == 0 && between > 0) {
		[t pass:@"resolved: inside white, outside black, %u edge pixels grey", between];
	} else if (wrong == 0) {
		[t fail:@"inside and outside right but no edge pixel in between: not multisampled"];
	} else {
		[t fail:@"%u pixels wrong; %@, %@", wrong, px_text(px, 8, SIDE - 8), px_text(px, SIDE - 8, 8)];
	}
}

/* one compute dispatch of our kernel `name` over n threads in groups of `group`; `bind` sets its arguments */
static BOOL
dispatch_ours(id<MTLFunction> function, NSUInteger n, NSUInteger group, void (^bind)(id<MTLComputeCommandEncoder>),
    NSString **problem)
{
	NSError *error = nil;
	id<MTLComputePipelineState> pipeline;
	id<MTLCommandBuffer> buffer;
	id<MTLComputeCommandEncoder> encoder;

	if (function == nil) {
		*problem = @"no function";
		return NO;
	}
	if ((pipeline = [g_device newComputePipelineStateWithFunction:function error:&error]) == nil) {
		*problem = [NSString stringWithFormat:@"no compute pipeline: %@", error.localizedDescription ?: @"nil, no error"];
		return NO;
	}
	buffer = [[g_device newCommandQueue] commandBuffer];
	if ((encoder = [buffer computeCommandEncoder]) == nil) {
		*problem = @"no compute encoder";
		return NO;
	}
	[encoder setComputePipelineState:pipeline];
	bind(encoder);
	[encoder dispatchThreadgroups:MTLSizeMake(n / group, 1, 1) threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];
	[encoder endEncoding];
	return finish(buffer, problem);
}

/*
 * events: k_iota into a buffer, then -encodeSignalEvent:value:1 in the same command buffer. The value is not set
 * before the commit, a listener hears 1, and when it does the kernel's numbers are already in the buffer (what a
 * renderer that waits for an event before reusing its buffers relies on).
 */
static void
test_metal_event(MetalTest *t)
{
	id<MTLSharedEvent> event;
	id<MTLBuffer> d;
	id<MTLComputePipelineState> pipeline;
	id<MTLCommandBuffer> buffer;
	id<MTLComputeCommandEncoder> encoder;
	MTLSharedEventListener *listener;
	NSError *error = nil;
	CFAbsoluteTime began;
	__block uint64_t heard = 0;
	__block unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	if ((event = [g_device newSharedEvent]) == nil) {
		[t fail:@"-newSharedEvent gave nil"];
		return;
	}
	if ((pipeline = [g_device newComputePipelineStateWithFunction:[g_ours newFunctionWithName:@"k_iota"]
	    error:&error]) == nil) {
		[t fail:@"no compute pipeline: %@", error.localizedDescription ?: @"nil, no error"];
		return;
	}
	d = [g_device newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
	memset(d.contents, 0xff, 256 * 4);
	listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:dispatch_queue_create("metal.event", NULL)];
	if (listener == nil) {
		/* (Metal's own initialiser registers with the GPU's kernel service, and a port without that answers nil) */
		[t fail:@"MTLSharedEventListener -initWithDispatchQueue: gave nil"];
		return;
	}
	[event notifyListener:listener atValue:1 block:^(id<MTLSharedEvent> e, uint64_t value) {
		const uint32_t *v = d.contents;
		unsigned bad = 0;

		(void)e;
		for (unsigned i = 0; i < 256; i++) {
			bad += v[i] != 3 * i + 1;
		}
		wrong = bad;
		__atomic_store_n(&heard, value, __ATOMIC_RELEASE);
	}];
	buffer = [[g_device newCommandQueue] commandBuffer];
	encoder = [buffer computeCommandEncoder];
	[encoder setComputePipelineState:pipeline];
	[encoder setBuffer:d offset:0 atIndex:0];
	[encoder dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[encoder endEncoding];
	[buffer encodeSignalEvent:event value:1];
	if (event.signaledValue != 0) {
		[t fail:@"the value was %llu before the commit", (unsigned long long)event.signaledValue];
		return;
	}
	[buffer commit];
	began = CFAbsoluteTimeGetCurrent();
	while (__atomic_load_n(&heard, __ATOMIC_ACQUIRE) == 0 && CFAbsoluteTimeGetCurrent() - began < 2.0) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	}
	if (__atomic_load_n(&heard, __ATOMIC_ACQUIRE) != 1) {
		[t fail:@"the listener heard %llu in 2 s (1 wanted); signaledValue %llu", (unsigned long long)heard,
		    (unsigned long long)event.signaledValue];
	} else if (wrong != 0) {
		[t fail:@"the listener heard 1 with %u of 256 values not yet written: set before the GPU was done", wrong];
	} else {
		[t pass:@"set after the commit, heard as 1 in %.1f ms, the kernel's 256 values already there",
		    (CFAbsoluteTimeGetCurrent() - began) * 1000];
	}
}

/* k_iota: d[i] = 3i + 1 over 256 threads, nothing in */
static void
test_metal_iota(MetalTest *t)
{
	id<MTLBuffer> d;
	NSString *problem = nil;
	unsigned wrong = 0;
	const uint32_t *v;

	if (!ours_ready(t)) {
		return;
	}
	d = [g_device newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
	memset(d.contents, 0xff, 256 * 4);
	if (!dispatch_ours([g_ours newFunctionWithName:@"k_iota"], 256, 64, ^(id<MTLComputeCommandEncoder> e) {
		    [e setBuffer:d offset:0 atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	v = d.contents;
	for (unsigned i = 0; i < 256; i++) {
		wrong += v[i] != 3 * i + 1;
	}
	if (wrong == 0) {
		[t pass:@"256 values, each 3i + 1"];
	} else {
		[t fail:@"%u of 256 wrong; d[0] %u d[1] %u d[255] %u (wanted 1 4 766)", wrong, v[0], v[1], v[255]];
	}
}

/* k_add: c = a + b, 1024 floats */
static void
test_metal_add(MetalTest *t)
{
	id<MTLBuffer> a, b, c;
	NSString *problem = nil;
	unsigned wrong = 0;
	float *fa, *fb;
	const float *fc;

	if (!ours_ready(t)) {
		return;
	}
	a = [g_device newBufferWithLength:1024 * 4 options:MTLResourceStorageModeShared];
	b = [g_device newBufferWithLength:1024 * 4 options:MTLResourceStorageModeShared];
	c = [g_device newBufferWithLength:1024 * 4 options:MTLResourceStorageModeShared];
	fa = a.contents;
	fb = b.contents;
	for (unsigned i = 0; i < 1024; i++) {
		fa[i] = i * 0.5f;
		fb[i] = 1000.0f - i;
	}
	if (!dispatch_ours([g_ours newFunctionWithName:@"k_add"], 1024, 64, ^(id<MTLComputeCommandEncoder> e) {
		    [e setBuffer:a offset:0 atIndex:0];
		    [e setBuffer:b offset:0 atIndex:1];
		    [e setBuffer:c offset:0 atIndex:2];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	fc = c.contents;
	for (unsigned i = 0; i < 1024; i++) {
		wrong += fc[i] != fa[i] + fb[i];
	}
	if (wrong == 0) {
		[t pass:@"1024 sums right"];
	} else {
		[t fail:@"%u of 1024 wrong; c[1] %g (wanted %g)", wrong, fc[1], fa[1] + fb[1]];
	}
}

/* k_gradient into a 16x16 RGBA8Unorm texture: the store must convert to the texture's format */
static void
test_metal_gradient(MetalTest *t)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16
	    height:16 mipmapped:NO];
	id<MTLTexture> texture;
	NSError *error = nil;
	id<MTLComputePipelineState> pipeline;
	id<MTLCommandBuffer> buffer;
	id<MTLComputeCommandEncoder> e;
	NSString *problem = nil;
	unsigned char out[16 * 16 * 4];
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	d.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
	if ((texture = [g_device newTextureWithDescriptor:d]) == nil) {
		[t fail:@"no 16x16 RGBA8 texture"];
		return;
	}
	if ((pipeline = [g_device newComputePipelineStateWithFunction:[g_ours newFunctionWithName:@"k_gradient"]
	    error:&error]) == nil) {
		[t fail:@"no compute pipeline: %@", error.localizedDescription];
		return;
	}
	buffer = [[g_device newCommandQueue] commandBuffer];
	e = [buffer computeCommandEncoder];
	[e setComputePipelineState:pipeline];
	[e setTexture:texture atIndex:0];
	[e dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	[e endEncoding];
	if (!finish(buffer, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	[texture getBytes:out bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
	for (unsigned y = 0; y < 16; y++) {
		for (unsigned x = 0; x < 16; x++) {
			const unsigned char *p = out + (y * 16 + x) * 4;

			/* (RGBA8: R G B A in memory) */
			wrong += abs((int)p[0] - (int)lroundf(x * 255.0f / 15)) > 1 || abs((int)p[1] - (int)lroundf(y * 255.0f / 15))
			    > 1 || abs((int)p[2] - 128) > 1 || p[3] != 255;
		}
	}
	if (wrong == 0) {
		[t pass:@"the gradient, every texel converted to RGBA8 right"];
	} else {
		[t fail:@"%u of 256 texels wrong; (15,15) R G B A %u %u %u %u (wanted 255 255 128 255), (5,0) %u %u %u %u "
		    "(wanted 85 0 128 255)", wrong, out[(15 * 16 + 15) * 4], out[(15 * 16 + 15) * 4 + 1],
		    out[(15 * 16 + 15) * 4 + 2], out[(15 * 16 + 15) * 4 + 3], out[5 * 4], out[5 * 4 + 1], out[5 * 4 + 2],
		    out[5 * 4 + 3]];
	}
}

/* one 2D dispatch of our kernel over w x h threads in 8x8 groups (v2's kernels, which take k_gradient apart) */
static BOOL
dispatch_ours2d(NSString *name, NSUInteger w, NSUInteger h, void (^bind)(id<MTLComputeCommandEncoder>), NSString **problem)
{
	NSError *error = nil;
	id<MTLFunction> function = [g_ours newFunctionWithName:name];
	id<MTLComputePipelineState> pipeline;
	id<MTLCommandBuffer> buffer;
	id<MTLComputeCommandEncoder> encoder;

	if (function == nil) {
		*problem = [NSString stringWithFormat:@"no %@ in alioth-tests.metallib (v2 has it)", name];
		return NO;
	}
	if ((pipeline = [g_device newComputePipelineStateWithFunction:function error:&error]) == nil) {
		*problem = [NSString stringWithFormat:@"%@: no compute pipeline: %@", name,
		    error.localizedDescription ?: @"nil, no error"];
		return NO;
	}
	buffer = [[g_device newCommandQueue] commandBuffer];
	if ((encoder = [buffer computeCommandEncoder]) == nil) {
		*problem = @"no compute encoder";
		return NO;
	}
	[encoder setComputePipelineState:pipeline];
	bind(encoder);
	[encoder dispatchThreadgroups:MTLSizeMake((w + 7) / 8, (h + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	[encoder endEncoding];
	return finish(buffer, problem);
}

static id<MTLTexture>
texture_ours(MTLPixelFormat format, NSUInteger w, NSUInteger h)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h
	    mipmapped:NO];

	d.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
	return [g_device newTextureWithDescriptor:d];
}

/* texels of a 16x16 RGBA8 gradient (k_gradient's) that are off by more than 1; the first one in *first */
static unsigned
gradient8_wrong(const unsigned char *out, NSString **first)
{
	unsigned wrong = 0;

	for (unsigned y = 0; y < 16; y++) {
		for (unsigned x = 0; x < 16; x++) {
			const unsigned char *p = out + (y * 16 + x) * 4;
			long r = lroundf(x * 255.0f / 15), g = lroundf(y * 255.0f / 15);

			if (labs(p[0] - r) > 1 || labs(p[1] - g) > 1 || abs(p[2] - 128) > 1 || p[3] != 255) {
				if (wrong++ == 0) {
					*first = [NSString stringWithFormat:@"(%u,%u) R G B A %u %u %u %u, wanted %ld %ld 128 255", x, y,
					    p[0], p[1], p[2], p[3], r, g];
				}
			}
		}
	}
	return wrong;
}

/* k_sizes, k_sizes_rw, k_sizes_ro: what get_width / get_height answer on a 16x12 texture, for each way of holding it */
static void
test_metal_sizes(MetalTest *t)
{
	static NSString *const kernels[] = { @"k_sizes", @"k_sizes_rw", @"k_sizes_ro" };
	static const char *const how[] = { "write", "read_write", "read" };
	NSMutableString *got = [NSMutableString string];
	unsigned bad = 0;

	if (!ours_ready(t)) {
		return;
	}
	for (unsigned k = 0; k < 3; k++) {
		id<MTLTexture> texture = texture_ours(MTLPixelFormatRGBA8Unorm, 16, 12);
		id<MTLBuffer> d = [g_device newBufferWithLength:8 options:MTLResourceStorageModeShared];
		NSString *problem = nil;
		const uint32_t *v = d.contents;

		memset(d.contents, 0xee, 8);
		if (!dispatch_ours2d(kernels[k], 16, 12, ^(id<MTLComputeCommandEncoder> e) {
			    [e setTexture:texture atIndex:0];
			    [e setBuffer:d offset:0 atIndex:0];
		    }, &problem)) {
			[got appendFormat:@"%s%s: %@", got.length ? "; " : "", how[k], problem];
			bad++;
			continue;
		}
		bad += v[0] != 16 || v[1] != 12;
		[got appendFormat:@"%s%s %ux%u", got.length ? "; " : "", how[k], v[0], v[1]];
	}
	if (bad == 0) {
		[t pass:@"16x12 every way: %@", got];
	} else {
		[t fail:@"%@ (wanted 16x12; 0xeeeeeeee: not written)", got];
	}
}

/* k_gradient_n: the size from a buffer, no queries; into RGBA8Unorm (converted) and RGBA32Float (not) */
static void
test_metal_gradient_n(MetalTest *t)
{
	const uint32_t n[2] = { 16, 16 };
	id<MTLBuffer> size;
	id<MTLTexture> t8, t32;
	NSString *problem = nil, *first = nil;
	unsigned char out8[16 * 16 * 4];
	float out32[16 * 16 * 4];
	unsigned wrong8, wrong32 = 0;

	if (!ours_ready(t)) {
		return;
	}
	size = [g_device newBufferWithBytes:n length:sizeof(n) options:MTLResourceStorageModeShared];
	t8 = texture_ours(MTLPixelFormatRGBA8Unorm, 16, 16);
	t32 = texture_ours(MTLPixelFormatRGBA32Float, 16, 16);
	if (!dispatch_ours2d(@"k_gradient_n", 16, 16, ^(id<MTLComputeCommandEncoder> e) {
		    [e setTexture:t8 atIndex:0];
		    [e setBuffer:size offset:0 atIndex:0];
	    }, &problem) || !dispatch_ours2d(@"k_gradient_n", 16, 16, ^(id<MTLComputeCommandEncoder> e) {
		    [e setTexture:t32 atIndex:0];
		    [e setBuffer:size offset:0 atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	[t8 getBytes:out8 bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
	[t32 getBytes:out32 bytesPerRow:16 * 16 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
	wrong8 = gradient8_wrong(out8, &first);
	for (unsigned i = 0; i < 16 * 16; i++) {
		const float *p = out32 + i * 4;

		wrong32 += fabsf(p[0] - (i % 16) / 15.0f) > 1e-5f || fabsf(p[1] - (i / 16) / 15.0f) > 1e-5f || p[2] != 0.5f ||
		    p[3] != 1.0f;
	}
	if (wrong8 == 0 && wrong32 == 0) {
		[t pass:@"RGBA8Unorm and RGBA32Float, every texel right"];
	} else {
		[t fail:@"RGBA8Unorm %u of 256 wrong%@%@; RGBA32Float %u of 256 wrong, (15,15) %g %g %g %g (wanted 1 1 0.5 1)", wrong8,
		    first != nil ? @", first " : @"", first ?: @"", wrong32, out32[255 * 4], out32[255 * 4 + 1], out32[255 * 4 + 2],
		    out32[255 * 4 + 3]];
	}
}

/* k_gradient16: halves stored into RGBA8Unorm, converted by the texture's format */
static void
test_metal_gradient16(MetalTest *t)
{
	const uint32_t n[2] = { 16, 16 };
	id<MTLBuffer> size;
	id<MTLTexture> texture;
	NSString *problem = nil, *first = nil;
	unsigned char out[16 * 16 * 4];
	unsigned wrong;

	if (!ours_ready(t)) {
		return;
	}
	size = [g_device newBufferWithBytes:n length:sizeof(n) options:MTLResourceStorageModeShared];
	texture = texture_ours(MTLPixelFormatRGBA8Unorm, 16, 16);
	if (!dispatch_ours2d(@"k_gradient16", 16, 16, ^(id<MTLComputeCommandEncoder> e) {
		    [e setTexture:texture atIndex:0];
		    [e setBuffer:size offset:0 atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	[texture getBytes:out bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
	if ((wrong = gradient8_wrong(out, &first)) == 0) {
		[t pass:@"every texel converted from half to RGBA8 right"];
	} else {
		[t fail:@"%u of 256 texels wrong, first %@", wrong, first];
	}
}

/* k_store_uint: integers into RGBA8Uint, (x, y, 7, 255) */
static void
test_metal_store_uint(MetalTest *t)
{
	id<MTLTexture> texture;
	NSString *problem = nil;
	unsigned char out[16 * 16 * 4];
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	texture = texture_ours(MTLPixelFormatRGBA8Uint, 16, 16);
	if (!dispatch_ours2d(@"k_store_uint", 16, 16, ^(id<MTLComputeCommandEncoder> e) {
		    [e setTexture:texture atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	[texture getBytes:out bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
	for (unsigned i = 0; i < 16 * 16; i++) {
		const unsigned char *p = out + i * 4;

		wrong += p[0] != i % 16 || p[1] != i / 16 || p[2] != 7 || p[3] != 255;
	}
	if (wrong == 0) {
		[t pass:@"every texel (x, y, 7, 255)"];
	} else {
		[t fail:@"%u of 256 texels wrong; (5,3) %u %u %u %u (wanted 5 3 7 255)", wrong, out[(3 * 16 + 5) * 4],
		    out[(3 * 16 + 5) * 4 + 1], out[(3 * 16 + 5) * 4 + 2], out[(3 * 16 + 5) * 4 + 3]];
	}
}

/* k_reduce: 256 values summed through threadgroup memory and barriers (groups of 64), added atomically */
static void
test_metal_reduce(MetalTest *t)
{
	id<MTLBuffer> in, sum;
	NSString *problem = nil;
	uint32_t *v;

	if (!ours_ready(t)) {
		return;
	}
	in = [g_device newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
	sum = [g_device newBufferWithLength:4 options:MTLResourceStorageModeShared];
	v = in.contents;
	for (unsigned i = 0; i < 256; i++) {
		v[i] = i + 1;
	}
	*(uint32_t *)sum.contents = 0;
	if (!dispatch_ours([g_ours newFunctionWithName:@"k_reduce"], 256, 64, ^(id<MTLComputeCommandEncoder> e) {
		    [e setBuffer:in offset:0 atIndex:0];
		    [e setBuffer:sum offset:0 atIndex:1];
		    [e setThreadgroupMemoryLength:64 * 4 atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	if (*(uint32_t *)sum.contents == 32896) {
		[t pass:@"1 + 2 + ... + 256 = 32896, in four groups of 64"];
	} else {
		[t fail:@"the sum came back %u (wanted 32896)", *(uint32_t *)sum.contents];
	}
}

/* k_constants specialised: scale 2, offset on -- d[i] = 2 d[i] + 10 */
static void
test_metal_constants(MetalTest *t)
{
	MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
	float scale = 2.0f;
	BOOL offset = YES;
	NSError *error = nil;
	id<MTLFunction> function;
	id<MTLBuffer> d;
	NSString *problem = nil;
	float *v;
	unsigned wrong = 0;

	if (!ours_ready(t)) {
		return;
	}
	[values setConstantValue:&scale type:MTLDataTypeFloat atIndex:0];
	[values setConstantValue:&offset type:MTLDataTypeBool atIndex:1];
	if ((function = [g_ours newFunctionWithName:@"k_constants" constantValues:values error:&error]) == nil) {
		[t fail:@"newFunctionWithName:constantValues: %@", error.localizedDescription ?: @"nil, no error"];
		return;
	}
	d = [g_device newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
	v = d.contents;
	for (unsigned i = 0; i < 64; i++) {
		v[i] = i;
	}
	if (!dispatch_ours(function, 64, 64, ^(id<MTLComputeCommandEncoder> e) {
		    [e setBuffer:d offset:0 atIndex:0];
	    }, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	for (unsigned i = 0; i < 64; i++) {
		wrong += v[i] != 2.0f * i + 10.0f;
	}
	if (wrong == 0) {
		[t pass:@"specialised: every d[i] = 2i + 10"];
	} else {
		[t fail:@"%u of 64 wrong; d[3] %g (wanted 16; 3 = constants taken as zero... %s)", wrong, v[3],
		    v[3] == 0 ? "scale 0" : v[3] == 6 ? "no offset" : "something else"];
	}
}

/* the blit encoder: fill a buffer, copy it into a texture, the texture back into another buffer */
static void
test_metal_blit(MetalTest *t)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16
	    height:16 mipmapped:NO];
	id<MTLBuffer> a, b;
	id<MTLTexture> texture;
	id<MTLCommandBuffer> buffer;
	id<MTLBlitCommandEncoder> blit;
	NSString *problem = nil;
	const unsigned char *out;
	unsigned wrong = 0;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	a = [g_device newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
	b = [g_device newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
	texture = [g_device newTextureWithDescriptor:d];
	buffer = [[g_device newCommandQueue] commandBuffer];
	if ((blit = [buffer blitCommandEncoder]) == nil) {
		[t fail:@"blitCommandEncoder returned nil: no blit encoder"];
		return;
	}
	[blit fillBuffer:a range:NSMakeRange(0, 16 * 16 * 4) value:0x5a];
	[blit copyFromBuffer:a sourceOffset:0 sourceBytesPerRow:64 sourceBytesPerImage:64 * 16 sourceSize:MTLSizeMake(16, 16, 1)
	    toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
	    sourceSize:MTLSizeMake(16, 16, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:64
	    destinationBytesPerImage:64 * 16];
	[blit endEncoding];
	if (!finish(buffer, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	out = b.contents;
	for (unsigned i = 0; i < 16 * 16 * 4; i++) {
		wrong += out[i] != 0x5a;
	}
	if (wrong == 0) {
		[t pass:@"fill, buffer to texture, texture to buffer: every byte 0x5a"];
	} else {
		[t fail:@"%u of 1024 bytes wrong; the first %#x", wrong, out[0]];
	}
}

/*
 * SpriteKit on this device: SKRenderer, given it, draws a magenta square in the middle of a black 64x64 target, read
 * back. (Not an SKView: that takes MTLCreateSystemDefaultDevice()'s device, which is nil until the system itself finds
 * this driver, and then draws with OpenGL ES -- the GPU tab's spritekit.* tests.)
 */
static void
test_metal_spritekit(MetalTest *t)
{
	SKRenderer *renderer;
	SKScene *scene;
	SKSpriteNode *sprite;
	MTLTextureDescriptor *d;
	MTLRenderPassDescriptor *pass;
	id<MTLTexture> target;
	id<MTLCommandBuffer> buffer;
	NSString *problem = nil;
	static unsigned char px[SIDE * SIDE * 4];

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if (NSClassFromString(@"SKRenderer") == nil) {
		[t skip:@"no SpriteKit"];
		return;
	}
	if (check_gl_spritekit_used) {
		/* SpriteKit settles once a process; its textures are GL ones now, whatever device an SKRenderer gets */
		[t skip:@"the GPU tab's SKViews ran first in this process, on OpenGL ES; run the Metal tab first"];
		return;
	}
	if ((renderer = [SKRenderer rendererWithDevice:g_device]) == nil) {
		[t fail:@"+[SKRenderer rendererWithDevice:] gave nil"];
		return;
	}
	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:SIDE height:SIDE
	    mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	if ((target = [g_device newTextureWithDescriptor:d]) == nil) {
		[t fail:@"no BGRA8 target"];
		return;
	}
	scene = [SKScene sceneWithSize:CGSizeMake(SIDE, SIDE)];
	scene.backgroundColor = UIColor.blackColor;
	sprite = [SKSpriteNode spriteNodeWithColor:UIColor.magentaColor size:CGSizeMake(SIDE / 2, SIDE / 2)];
	sprite.position = CGPointMake(SIDE / 2, SIDE / 2);
	[scene addChild:sprite];
	renderer.scene = scene;
	[renderer updateAtTime:CACurrentMediaTime()];
	pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = target;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	/* black: an SKRenderer draws the nodes and leaves the background to the pass's own clear (d70b004's round: the
	   corner came back as the clear colour, not the scene's backgroundColor) */
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	buffer = [[g_device newCommandQueue] commandBuffer];
	[renderer renderWithViewport:CGRectMake(0, 0, SIDE, SIDE) commandBuffer:buffer renderPassDescriptor:pass];
	if (!finish(buffer, &problem)) {
		[t fail:@"%@", problem];
		return;
	}
	[target getBytes:px bytesPerRow:SIDE * 4 fromRegion:MTLRegionMake2D(0, 0, SIDE, SIDE) mipmapLevel:0];
	/* (BGRA: the middle magenta, a corner the scene's black) */
	if (px_near(px + (SIDE / 2 * SIDE + SIDE / 2) * 4, 255, 0, 255, 255, 40) && px_near(px + (4 * SIDE + 4) * 4, 0, 0, 0, 255,
	    40)) {
		[t pass:@"SKRenderer on this device drew the scene: the middle magenta, a corner black"];
	} else {
		[t fail:@"the middle %@, a corner %@ (B G R A: magenta and black wanted)", px_text(px, SIDE / 2, SIDE / 2),
		    px_text(px, 4, 4)];
	}
}

/* metal.mtkview's delegate: each frame cleared to a colour of its own and presented, counted */
@interface MetalViewCounter : NSObject <MTKViewDelegate>
@property (nonatomic) id<MTLCommandQueue> queue;
@property (nonatomic) unsigned frames, completed, failed;
@property (nonatomic, copy) NSString *problem;
@end

@implementation MetalViewCounter

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
	(void)view;
	(void)size;
}

- (void)drawInMTKView:(MTKView *)view
{
	MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
	id<CAMetalDrawable> drawable = view.currentDrawable;
	id<MTLCommandBuffer> buffer;
	id<MTLRenderCommandEncoder> encoder;

	if (pass == nil || drawable == nil) {
		self.problem = pass == nil ? @"no currentRenderPassDescriptor" : @"no currentDrawable";
		return;
	}
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake((self.frames % 60) / 60.0, 0.3, 0.6, 1);
	buffer = [self.queue commandBuffer];
	encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	[encoder endEncoding];
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (done.status == MTLCommandBufferStatusCompleted) {
				self.completed++;
			} else {
				self.failed++;
			}
		});
	}];
	[buffer presentDrawable:drawable];
	[buffer commit];
	self.frames++;
}

@end

/*
 * MTKView drawing continuously on this device: a 120x120 view for two seconds at the top left, every frame cleared and
 * presented; how many came, how many completed. (The plan's "MTKView 连续画": what a Metal game's loop is.)
 */
static void
test_metal_mtkview(MetalTest *t)
{
	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	MetalViewCounter *counter;
	MTKView *view;
	CFAbsoluteTime began;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if (NSClassFromString(@"MTKView") == nil || window == nil) {
		[t skip:@"%@", window == nil ? @"no window" : @"no MetalKit"];
		return;
	}
	counter = [MetalViewCounter new];
	counter.queue = [g_device newCommandQueue];
	view = [[MTKView alloc] initWithFrame:CGRectMake(0, 120, 120, 120) device:g_device];
	view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	view.preferredFramesPerSecond = 60;
	view.delegate = counter;
	[window addSubview:view];
	began = CFAbsoluteTimeGetCurrent();
	/* (the tests run on the main thread one after the other; the view's display link needs its run loop) */
	while (CFAbsoluteTimeGetCurrent() - began < 2.0 && counter.problem == nil) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	view.paused = YES;
	[view removeFromSuperview];
	/* the last frames' completion handlers */
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	if (counter.problem != nil) {
		[t fail:@"after %u frames: %@", counter.frames, counter.problem];
	} else if (counter.frames >= 60 && counter.failed == 0 && counter.completed + 4 >= counter.frames) {
		[t pass:@"%u frames in 2 s (%.0f a second), %u completed, none failed", counter.frames, counter.frames / 2.0,
		    counter.completed];
	} else {
		[t fail:@"%u frames in 2 s, %u completed, %u failed (60 or more wanted, all completed)", counter.frames,
		    counter.completed, counter.failed];
	}
}

/* SceneKit asked for Metal: what it chose, and a snapshot of a magenta box on black */
static void
test_metal_scenekit(MetalTest *t)
{
	SCNView *view;
	SCNScene *scene;
	SCNNode *box, *camera;
	UIImage *snapshot;
	unsigned char pixel[4] = { 0 };
	CGContextRef context;
	CGColorSpaceRef rgb;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if (NSClassFromString(@"SCNView") == nil) {
		[t skip:@"no SceneKit"];
		return;
	}
	view = [[SCNView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)
	    options:@{ SCNPreferredRenderingAPIKey: @(SCNRenderingAPIMetal), SCNPreferredDeviceKey: g_device }];
	[t note:@"renderingAPI %@, device %@", view.renderingAPI == SCNRenderingAPIMetal ? @"Metal" : @"OpenGL ES",
	    view.device.name ?: @"none"];
	if (view.renderingAPI != SCNRenderingAPIMetal) {
		if (check_gl_scenekit_used) {
			[t skip:@"SceneKit took OpenGL ES: the GPU tab's SCNViews ran first in this process, and SceneKit settles "
			    @"once; run the Metal tab first"];
		} else {
			[t fail:@"SceneKit took OpenGL ES though Metal was asked for"];
		}
		return;
	}
	scene = [SCNScene scene];
	box = [SCNNode nodeWithGeometry:[SCNBox boxWithWidth:1 height:1 length:1 chamferRadius:0]];
	box.geometry.firstMaterial.diffuse.contents = UIColor.magentaColor;
	box.geometry.firstMaterial.lightingModelName = SCNLightingModelConstant;
	[scene.rootNode addChildNode:box];
	camera = [SCNNode node];
	camera.camera = [SCNCamera camera];
	camera.position = SCNVector3Make(0, 0, 3);
	[scene.rootNode addChildNode:camera];
	view.scene = scene;
	view.pointOfView = camera;
	view.backgroundColor = UIColor.blackColor;
	if ((snapshot = [view snapshot]) == nil || snapshot.CGImage == NULL) {
		[t fail:@"snapshot: nothing"];
		return;
	}
	rgb = CGColorSpaceCreateDeviceRGB();
	context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, rgb, kCGImageAlphaPremultipliedLast);
	CGContextDrawImage(context, CGRectMake(-(CGFloat)CGImageGetWidth(snapshot.CGImage) / 2,
	    -(CGFloat)CGImageGetHeight(snapshot.CGImage) / 2, CGImageGetWidth(snapshot.CGImage),
	    CGImageGetHeight(snapshot.CGImage)), snapshot.CGImage);
	CGContextRelease(context);
	CGColorSpaceRelease(rgb);
	if (pixel[0] > 200 && pixel[1] < 60 && pixel[2] > 200) {
		[t pass:@"SceneKit drew the box through this device: R G B %u %u %u in the middle", pixel[0], pixel[1], pixel[2]];
	} else {
		[t fail:@"the middle came back R G B A %u %u %u %u (magenta wanted)", pixel[0], pixel[1], pixel[2], pixel[3]];
	}
}

/* the first layer of a class whose name has `part` in it, under `layer` (itself included) */
static CALayer *
layer_named(CALayer *layer, NSString *part)
{
	if ([NSStringFromClass([layer class]) containsString:part]) {
		return layer;
	}
	for (CALayer *sub in layer.sublayers) {
		CALayer *found = layer_named(sub, part);

		if (found != nil) {
			return found;
		}
	}
	return nil;
}

/*
 * MapKit, whose maps VectorKit draws -- with Metal, on whatever device MTLCreateSystemDefaultDevice() answers: one of
 * the heaviest Metal clients in iOS, here on this device. A whole-window MKMapView for three seconds (what draws it: a
 * CAMetalLayer or not), then an MKMapSnapshotter's picture of the same place: how many colours a 32 x 32 copy of it
 * has. One colour is a map drawn without its tiles (they come from Apple's servers) or not drawn at all.
 */
static void
test_metal_mapkit(MetalTest *t)
{
	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	MKCoordinateRegion region;
	MKMapSnapshotOptions *options;
	MKMapSnapshotter *snapshotter;
	MKMapView *map;
	CALayer *metal;
	CFAbsoluteTime began;
	__block UIImage *picture = nil;
	__block NSError *failure = nil;
	__block BOOL done = NO;
	unsigned char pixels[32 * 32 * 4] = { 0 };
	unsigned colours = 0;
	uint32_t seen[64];
	CGContextRef context;
	CGColorSpaceRef rgb;

	if (g_device == nil) {
		[t skip:@"no device"];
		return;
	}
	if (NSClassFromString(@"MKMapView") == nil || window == nil) {
		[t skip:@"%@", window == nil ? @"no window" : @"no MapKit"];
		return;
	}
	/* (MapKit is linked weakly: its functions only once it is known to be there) */
	region = MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(48.8584, 2.2945), 2000, 2000);
	map = [[MKMapView alloc] initWithFrame:window.bounds];
	[map setRegion:region animated:NO];
	[window addSubview:map];
	began = CFAbsoluteTimeGetCurrent();
	[t note:@"on screen now for 3 s: a map of the Champ de Mars, Paris"];
	while (CFAbsoluteTimeGetCurrent() - began < 3.0) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	metal = layer_named(map.layer, @"MetalLayer");
	[t note:@"drawn into %@", metal != nil ? [NSString stringWithFormat:@"a %@ (%.0f x %.0f drawable)",
	    NSStringFromClass([metal class]), ((CAMetalLayer *)metal).drawableSize.width,
	    ((CAMetalLayer *)metal).drawableSize.height] : @"no CAMetalLayer in the view's layers"];
	[map removeFromSuperview];

	options = [MKMapSnapshotOptions new];
	options.region = region;
	options.size = CGSizeMake(256, 256);
	snapshotter = [[MKMapSnapshotter alloc] initWithOptions:options];
	[snapshotter startWithCompletionHandler:^(MKMapSnapshot *snapshot, NSError *error) {
		picture = snapshot.image;
		failure = error;
		done = YES;
	}];
	began = CFAbsoluteTimeGetCurrent();
	while (!done && CFAbsoluteTimeGetCurrent() - began < 20.0) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	if (!done) {
		[snapshotter cancel];
		[t fail:@"MKMapSnapshotter: no picture in 20 s (%@)", metal != nil ? @"the view drew on a CAMetalLayer" :
		    @"and the view had no CAMetalLayer"];
		return;
	}
	if ((picture == nil || picture.CGImage == NULL) && [failure.domain isEqualToString:MKErrorDomain] &&
	    (failure.code == MKErrorServerFailure || failure.code == MKErrorLoadingThrottled)) {
		/* (no map data came: what the picture would show is not this device's doing either way) */
		[t skip:@"MKMapSnapshotter: no map data from Apple's servers here (MKErrorDomain %ld); the view drew on %@",
		    (long)failure.code, metal != nil ? NSStringFromClass([metal class]) : @"no CAMetalLayer"];
		return;
	}
	if (picture == nil || picture.CGImage == NULL) {
		[t fail:@"MKMapSnapshotter: no picture: %@", failure.localizedDescription ?: @"no error either"];
		return;
	}
	rgb = CGColorSpaceCreateDeviceRGB();
	context = CGBitmapContextCreate(pixels, 32, 32, 8, 32 * 4, rgb, kCGImageAlphaPremultipliedLast);
	CGContextDrawImage(context, CGRectMake(0, 0, 32, 32), picture.CGImage);
	CGContextRelease(context);
	CGColorSpaceRelease(rgb);
	for (unsigned i = 0; i < 32 * 32 && colours < 64; i++) {
		uint32_t c = (uint32_t)(pixels[i * 4] >> 4) << 8 | (uint32_t)(pixels[i * 4 + 1] >> 4) << 4 | pixels[i * 4 + 2] >> 4;
		unsigned k = 0;

		while (k < colours && seen[k] != c) {
			k++;
		}
		if (k == colours) {
			seen[colours++] = c;
		}
	}
	if (colours >= 8) {
		[t pass:@"a %.0f x %.0f picture of %u%s colours (a 32 x 32 copy, 4 bits a channel); the view drew on %@",
		    picture.size.width * picture.scale, picture.size.height * picture.scale, colours, colours >= 64 ? " or more" : "",
		    metal != nil ? NSStringFromClass([metal class]) : @"no CAMetalLayer"];
	} else {
		[t fail:@"the picture has %u colour%s, the middle R G B A %u %u %u %u: tiles not loaded, or nothing drawn",
		    colours, colours == 1 ? "" : "s", pixels[(16 * 32 + 16) * 4], pixels[(16 * 32 + 16) * 4 + 1],
		    pixels[(16 * 32 + 16) * 4 + 2], pixels[(16 * 32 + 16) * 4 + 3]];
	}
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
	{ "metal.lib", test_metal_lib },
	{ "metal.vertex", test_metal_vertex },
	{ "metal.vbuffer", test_metal_vbuffer },
	{ "metal.texture", test_metal_texture },
	{ "metal.blend", test_metal_blend },
	{ "metal.viewport", test_metal_viewport },
	{ "metal.scissor", test_metal_scissor },
	{ "metal.cull", test_metal_cull },
	{ "metal.clip", test_metal_clip },
	{ "metal.blendcolor", test_metal_blendcolor },
	{ "metal.indirect", test_metal_indirect },
	{ "metal.heap", test_metal_heap },
	{ "metal.depth", test_metal_depth },
	{ "metal.msaa", test_metal_msaa },
	{ "metal.iota", test_metal_iota },
	{ "metal.event", test_metal_event },
	{ "metal.add", test_metal_add },
	{ "metal.gradient", test_metal_gradient },
	{ "metal.sizes", test_metal_sizes },
	{ "metal.gradient.n", test_metal_gradient_n },
	{ "metal.gradient16", test_metal_gradient16 },
	{ "metal.store.uint", test_metal_store_uint },
	{ "metal.reduce", test_metal_reduce },
	{ "metal.constants", test_metal_constants },
	{ "metal.blit", test_metal_blit },
	{ "metal.spritekit", test_metal_spritekit },
	{ "metal.scenekit", test_metal_scenekit },
	{ "metal.mtkview", test_metal_mtkview },
	{ "metal.mapkit", test_metal_mapkit },
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
		record("crashed", g_tests[running].ident, [NSString stringWithFormat:@"%@: %@ (%@)", exception.name,
		    exception.reason, check_backtrace(exception)]);
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
	CGFloat _laidOut;               /* the width the header was laid out for */
}

- (instancetype)init
{
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]) != nil) {
		self.navigationItem.title = @"Metal Check";
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Run"
		    style:UIBarButtonItemStylePlain target:self action:@selector(runButton)];
		_marked = [NSMutableSet set];
		_summary = @"Run: the tests, in order (they take a few seconds)";
	}
	return self;
}

/* the on-screen tests' stage: a black square at the top right of the list, the triangle's below it (the test puts it
   there, from the first one's frame), what they are on the left */
- (void)viewDidLoad
{
	UIView *header;
	UILabel *what;

	[super viewDidLoad];
	header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 8 + 120 + 16 + 120 + 8)];
	g_stage = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 120, 120)];
	g_stage.backgroundColor = UIColor.blackColor;
	g_stage.userInteractionEnabled = NO;
	[header addSubview:g_stage];
	what = [UILabel new];
	what.tag = 1;
	what.numberOfLines = 0;
	what.font = [UIFont systemFontOfSize:12];
	what.textColor = UIColor.secondaryLabelColor;
	what.text = @"On the right, what the on-screen tests leave up: the top square cleared to blue "
	    "(metal.clear.layer), the one below it with an orange triangle (metal.triangle.layer). Black: not drawn.";
	[header addSubview:what];
	self.tableView.tableHeaderView = header;
}

/* (the frames once the table has its width; the triangle's stage is only made by its test, after this) */
- (void)viewDidLayoutSubviews
{
	UIView *header = self.tableView.tableHeaderView;
	CGFloat width = self.tableView.bounds.size.width;
	UILabel *what = [header viewWithTag:1];
	CGSize fits;

	[super viewDidLayoutSubviews];
	/* (not the header's own width: the table sets that itself) */
	if (width <= 0 || _laidOut == width) {
		return;
	}
	_laidOut = width;
	header.frame = CGRectMake(0, 0, width, header.frame.size.height);
	g_stage.frame = CGRectMake(width - 136, 8, 120, 120);
	fits = [what sizeThatFits:CGSizeMake(width - 136 - 36, CGFLOAT_MAX)];
	what.frame = CGRectMake(20, 8, width - 136 - 36, fits.height);
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
			/* (an exception the test's calls throw is its FAIL, with where it came from) */
			@try {
				g_tests[i].run(t);
			} @catch (NSException *exception) {
				[t fail:@"exception %@: %@ (%@)", exception.name, exception.reason, check_backtrace(exception)];
			}
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
