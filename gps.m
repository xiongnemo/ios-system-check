// System Check's GPS tab, after the GPS Status app the owner has on the phone: a sky view of the satellites (where each
// is -- azimuth round the circle, elevation inwards to the zenith -- coloured by its signal, filled when the fix uses
// it, the circle turned with the compass so that the sky lies as it is around the phone), the satellites' signal as
// bars, and the fix: status, satellites in view and used, accuracy, position, altitude, speed, heading, time.
//
// Two sources, shown side by side. iOS's own (CoreLocation: whatever locationd has -- on the K40 port today Wi-Fi
// positioning); and the modem's GNSS as the port's kernel reads it from the modem (sysctl kern.hakios.gnss: the
// Redmi K40's SDX55 over QMI LOC; iOS gives an application no satellites, so this is where they come from; elsewhere
// the sysctl is not there and the tab says so). systemcheck://gps/run draws a DEMO sky (made-up satellites, labelled
// as such) to check the drawing on a phone whose GNSS has none yet. Nothing here writes a position anywhere: the
// console line ("gpscheck: ...") has the counts and the accuracy, never the coordinates.
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#include <sys/sysctl.h>
#import "check.h"

/* the kernel's struct alioth_gnss, version 1 (bsd/dev/alioth_mdm.c of the port): IEEE bits for its numbers */
#define GNSS_SATS 64
struct gnss_sat {
	uint32_t system;
	uint16_t prn;
	uint8_t status, used;
	uint32_t elevation_bits, azimuth_bits, snr_bits;
};
struct gnss {
	uint32_t version, size;
	uint64_t updated_ms;
	uint32_t state, engine_state, session_status, opmode;
	uint32_t reports, fixes, sv_reports, valid;
	uint64_t latitude_bits, longitude_bits;
	uint32_t accuracy_bits, altitude_ellipsoid_bits, altitude_msl_bits, speed_bits, heading_bits, vertical_bits;
	uint64_t utc_ms;
	uint32_t sat_count;
	struct gnss_sat sat[GNSS_SATS];
};
#define GNSS_V_POSITION     (1u << 0)
#define GNSS_V_ACCURACY     (1u << 1)
#define GNSS_V_ALTITUDE_ELL (1u << 2)
#define GNSS_V_ALTITUDE_MSL (1u << 3)
#define GNSS_V_SPEED        (1u << 4)
#define GNSS_V_HEADING      (1u << 5)
#define GNSS_V_VERTICAL     (1u << 6)
#define GNSS_V_UTC          (1u << 7)

static float
f32(uint32_t bits)
{
	float f;

	memcpy(&f, &bits, 4);
	return f;
}

static double
f64(uint64_t bits)
{
	double d;

	memcpy(&d, &bits, 8);
	return d;
}

/* the constellation's letter and name (QMI LOC's numbering) */
static NSString *
system_letter(uint32_t s)
{
	switch (s) {
	case 1: return @"G";
	case 2: return @"E";
	case 3: return @"S";
	case 4: case 6: return @"C";
	case 5: return @"R";
	case 7: return @"J";
	default: return @"?";
	}
}

static NSString *
system_name(uint32_t s)
{
	switch (s) {
	case 1: return @"GPS";
	case 2: return @"Galileo";
	case 3: return @"SBAS";
	case 4: case 6: return @"BeiDou";
	case 5: return @"GLONASS";
	case 7: return @"QZSS";
	default: return @"other";
	}
}

/* GPS Status's scale, by C/N0 in dB-Hz: red weak, orange, yellow, green strong */
static UIColor *
snr_color(float snr)
{
	if (snr < 15) {
		return [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1];
	} else if (snr < 25) {
		return [UIColor colorWithRed:0.95 green:0.55 blue:0.15 alpha:1];
	} else if (snr < 32) {
		return [UIColor colorWithRed:0.90 green:0.80 blue:0.15 alpha:1];
	}
	return [UIColor colorWithRed:0.25 green:0.75 blue:0.30 alpha:1];
}

/* one satellite as the views draw it */
struct sat {
	NSString *__unsafe_unretained letter;
	int prn;
	float elevation, azimuth, snr;
	BOOL used, tracked;
};

#pragma mark the sky

@interface SkyView : UIView
@property (assign) const struct sat *sats;
@property (assign) unsigned count;
@property (assign) double heading;        /* the phone's, degrees from true (or magnetic) north; NAN: not known */
@end

@implementation SkyView

- (void)drawRect:(CGRect)rect
{
	CGContextRef c = UIGraphicsGetCurrentContext();
	CGSize s = self.bounds.size;
	CGFloat r = MIN(s.width, s.height) / 2 - 22;
	CGPoint o = CGPointMake(s.width / 2, s.height / 2);
	double turn = isnan(self.heading) ? 0 : -self.heading * M_PI / 180;     /* (the sky turned against the phone) */
	UIColor *ink = UIColor.secondaryLabelColor;

	/* the horizon, 30 and 60 degrees up, the cross through the zenith */
	CGContextSetLineWidth(c, 1);
	CGContextSetStrokeColorWithColor(c, ink.CGColor);
	for (int ring = 0; ring < 3; ring++) {
		CGFloat rr = r * (90 - ring * 30) / 90.0;

		CGContextStrokeEllipseInRect(c, CGRectMake(o.x - rr, o.y - rr, 2 * rr, 2 * rr));
	}
	for (int k = 0; k < 4; k++) {
		double a = turn + k * M_PI / 2;

		CGContextMoveToPoint(c, o.x, o.y);
		CGContextAddLineToPoint(c, o.x + r * sin(a), o.y - r * cos(a));
	}
	CGContextStrokePath(c);
	/* N E S W outside the horizon, N in red */
	NSArray<NSString *> *points = @[ @"N", @"E", @"S", @"W" ];
	for (int k = 0; k < 4; k++) {
		double a = turn + k * M_PI / 2;
		NSDictionary *at = @{ NSFontAttributeName : [UIFont boldSystemFontOfSize:14],
			NSForegroundColorAttributeName : k == 0 ? UIColor.systemRedColor : UIColor.labelColor };
		CGSize ts = [points[k] sizeWithAttributes:at];
		CGPoint p = CGPointMake(o.x + (r + 12) * sin(a) - ts.width / 2, o.y - (r + 12) * cos(a) - ts.height / 2);

		[points[k] drawAtPoint:p withAttributes:at];
	}
	/* the satellites */
	for (unsigned i = 0; i < self.count; i++) {
		const struct sat *v = &self.sats[i];
		CGFloat d = r * (90 - MAX(0, MIN(90, v->elevation))) / 90.0;
		double a = turn + v->azimuth * M_PI / 180;
		CGPoint p = CGPointMake(o.x + d * sin(a), o.y - d * cos(a));
		CGRect dot = CGRectMake(p.x - 11, p.y - 11, 22, 22);
		UIColor *col = v->tracked ? snr_color(v->snr) : UIColor.systemGrayColor;

		if (v->used) {
			CGContextSetFillColorWithColor(c, col.CGColor);
			CGContextFillEllipseInRect(c, dot);
		} else {
			CGContextSetStrokeColorWithColor(c, col.CGColor);
			CGContextSetLineWidth(c, 2);
			CGContextStrokeEllipseInRect(c, CGRectInset(dot, 1, 1));
		}
		NSString *name = [NSString stringWithFormat:@"%@%d", v->letter, v->prn];
		NSDictionary *at = @{ NSFontAttributeName : [UIFont boldSystemFontOfSize:9],
			NSForegroundColorAttributeName : v->used ? UIColor.whiteColor : UIColor.labelColor };
		CGSize ts = [name sizeWithAttributes:at];

		[name drawAtPoint:CGPointMake(p.x - ts.width / 2, p.y - ts.height / 2) withAttributes:at];
	}
}

@end

#pragma mark the bars

@interface BarsView : UIView
@property (assign) const struct sat *sats;
@property (assign) unsigned count;
@end

@implementation BarsView

- (void)drawRect:(CGRect)rect
{
	CGContextRef c = UIGraphicsGetCurrentContext();
	CGSize s = self.bounds.size;
	CGFloat base = s.height - 14, top = 6, w;
	unsigned n = self.count;

	CGContextSetStrokeColorWithColor(c, UIColor.separatorColor.CGColor);
	CGContextSetLineWidth(c, 1);
	for (int db = 0; db <= 50; db += 10) {          /* a line every 10 dB-Hz, 0..50 */
		CGFloat y = base - (base - top) * db / 50.0;

		CGContextMoveToPoint(c, 0, y);
		CGContextAddLineToPoint(c, s.width, y);
	}
	CGContextStrokePath(c);
	if (n == 0) {
		NSDictionary *at = @{ NSFontAttributeName : [UIFont systemFontOfSize:12], NSForegroundColorAttributeName :
			UIColor.secondaryLabelColor };
		[@"no satellites" drawAtPoint:CGPointMake(8, top + 4) withAttributes:at];
		return;
	}
	w = MIN(26, s.width / n);
	for (unsigned i = 0; i < n; i++) {
		const struct sat *v = &self.sats[i];
		CGFloat h = (base - top) * MIN(50, MAX(0, v->snr)) / 50.0;
		CGRect bar = CGRectMake(i * w + 2, base - h, w - 4, h);
		UIColor *col = v->tracked ? snr_color(v->snr) : UIColor.systemGrayColor;

		if (v->used) {
			CGContextSetFillColorWithColor(c, col.CGColor);
			CGContextFillRect(c, bar);
		} else {
			CGContextSetStrokeColorWithColor(c, col.CGColor);
			CGContextStrokeRect(c, CGRectInset(bar, 0.5, 0.5));
		}
		NSString *name = [NSString stringWithFormat:@"%@%d", v->letter, v->prn];
		NSDictionary *at = @{ NSFontAttributeName : [UIFont systemFontOfSize:8], NSForegroundColorAttributeName :
			UIColor.labelColor };
		[name drawAtPoint:CGPointMake(i * w + 1, base + 1) withAttributes:at];
	}
}

@end

#pragma mark the tab

@interface GpsController : UIViewController <CLLocationManagerDelegate>
@property (strong) CLLocationManager *location;
@property (strong) CLLocation *lastLocation;
@property (assign) double heading;
@property (strong) SkyView *sky;
@property (strong) BarsView *bars;
@property (strong) UILabel *label, *banner;
@property (strong) NSTimer *timer;
@property (assign) BOOL demo;
@property (assign) unsigned ticks;
@end

static GpsController *g_gps;

UIViewController *
gps_controller(void)
{
	g_gps = [GpsController new];
	return g_gps;
}

void
gps_run(void)
{
	g_gps.demo = YES;
}

@implementation GpsController {
	struct sat _sats[GNSS_SATS];
	unsigned _count;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	self.heading = NAN;
	self.sky = [SkyView new];
	self.sky.backgroundColor = UIColor.secondarySystemBackgroundColor;
	self.sky.heading = NAN;
	[self.view addSubview:self.sky];
	self.bars = [BarsView new];
	self.bars.backgroundColor = UIColor.secondarySystemBackgroundColor;
	[self.view addSubview:self.bars];
	self.banner = [UILabel new];
	self.banner.font = [UIFont boldSystemFontOfSize:12];
	self.banner.textAlignment = NSTextAlignmentCenter;
	self.banner.textColor = UIColor.whiteColor;
	self.banner.backgroundColor = UIColor.systemOrangeColor;
	self.banner.text = @"DEMO: made-up satellites (systemcheck://gps/run)";
	self.banner.hidden = YES;
	[self.view addSubview:self.banner];
	self.label = [UILabel new];
	self.label.numberOfLines = 0;
	self.label.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
	[self.view addSubview:self.label];
	self.location = [CLLocationManager new];
	self.location.delegate = self;
	self.location.desiredAccuracy = kCLLocationAccuracyBest;
}

- (void)viewDidLayoutSubviews
{
	CGRect all = self.view.bounds;
	UIEdgeInsets safe = self.view.safeAreaInsets;
	CGFloat top = MAX(safe.top, 20) + 4, w = all.size.width, skyh = MIN(w, all.size.height * 0.42);

	[super viewDidLayoutSubviews];
	self.sky.frame = CGRectMake(0, top, w, skyh);
	self.banner.frame = CGRectMake(0, top, w, 18);
	self.bars.frame = CGRectMake(8, CGRectGetMaxY(self.sky.frame) + 6, w - 16, 92);
	self.label.frame = CGRectMake(14, CGRectGetMaxY(self.bars.frame) + 8, w - 28,
	    all.size.height - safe.bottom - CGRectGetMaxY(self.bars.frame) - 12);
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	if (self.location.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
		[self.location requestWhenInUseAuthorization];
	}
	[self.location startUpdatingLocation];
	if (CLLocationManager.headingAvailable) {
		[self.location startUpdatingHeading];
	}
	self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
	[self tick];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	[self.timer invalidate];
	self.timer = nil;
	[self.location stopUpdatingLocation];
	[self.location stopUpdatingHeading];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
	self.lastLocation = locations.lastObject;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)heading
{
	self.heading = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
}

/* made-up satellites for systemcheck://gps/run: three constellations, some used, some weak, one not tracked */
- (void)demoInto:(struct gnss *)g
{
	static const struct { uint32_t system; uint16_t prn; float elevation, azimuth, snr; uint8_t status, used; } d[] = {
		{ 1, 3, 72, 40, 41, 3, 1 }, { 1, 7, 35, 110, 33, 3, 1 }, { 1, 14, 18, 200, 22, 3, 0 }, { 1, 22, 55, 290, 38, 3, 1 },
		{ 5, 9, 48, 330, 29, 3, 1 }, { 5, 21, 12, 150, 14, 3, 0 }, { 4, 11, 66, 250, 36, 3, 1 }, { 4, 24, 28, 60, 19, 2, 0 },
		{ 2, 5, 40, 170, 31, 3, 1 }, { 1, 30, 5, 80, 0, 1, 0 },
	};

	memset(g, 0, sizeof(*g));
	g->version = 1;
	g->size = sizeof(*g);
	g->state = 3;
	g->engine_state = 1;
	g->session_status = 0;
	g->sat_count = sizeof(d) / sizeof(d[0]);
	for (unsigned i = 0; i < g->sat_count; i++) {
		float e = d[i].elevation, a = d[i].azimuth, s = d[i].snr;

		g->sat[i].system = d[i].system;
		g->sat[i].prn = d[i].prn;
		g->sat[i].status = d[i].status;
		g->sat[i].used = d[i].used;
		memcpy(&g->sat[i].elevation_bits, &e, 4);
		memcpy(&g->sat[i].azimuth_bits, &a, 4);
		memcpy(&g->sat[i].snr_bits, &s, 4);
	}
}

static NSString *
state_name(uint32_t s)
{
	switch (s) {
	case 0: return @"not asked (boot-arg mdm_loc=1)";
	case 1: return @"waiting for the modem's LOC";
	case 2: return @"starting";
	case 3: return @"running";
	default: return @"?";
	}
}

static NSString *
session_name(uint32_t s)
{
	switch (s) {
	case 0: return @"FIX";
	case 1: return @"searching";
	case 2: return @"failed";
	case 3: return @"timed out";
	case 7: return @"engine locked";
	case UINT32_MAX: return @"no report";
	default: return [NSString stringWithFormat:@"status %u", s];
	}
}

- (void)tick
{
	struct gnss g;
	size_t len = sizeof(g);
	BOOL have = NO;
	NSMutableString *t = [NSMutableString string];
	unsigned used = 0, tracked = 0;
	NSMutableDictionary<NSString *, NSNumber *> *per = [NSMutableDictionary dictionary];

	memset(&g, 0, sizeof(g));
	if (self.demo) {
		[self demoInto:&g];
		have = YES;
	} else if (sysctlbyname("kern.hakios.gnss", &g, &len, NULL, 0) == 0 && len >= offsetof(struct gnss, sat) &&
	    g.version == 1) {
		have = YES;
	}
	self.banner.hidden = !self.demo;
	_count = 0;
	for (unsigned i = 0; have && i < g.sat_count && i < GNSS_SATS; i++) {
		struct sat *v = &_sats[_count++];

		v->letter = system_letter(g.sat[i].system);
		v->prn = g.sat[i].prn;
		v->elevation = f32(g.sat[i].elevation_bits);
		v->azimuth = f32(g.sat[i].azimuth_bits);
		v->snr = f32(g.sat[i].snr_bits);
		v->used = g.sat[i].used != 0;
		v->tracked = g.sat[i].status == 3;
		used += v->used;
		tracked += v->tracked;
		per[system_name(g.sat[i].system)] = @(per[system_name(g.sat[i].system)].unsignedIntValue + 1);
	}
	self.sky.sats = _sats;
	self.sky.count = _count;
	self.sky.heading = self.heading;
	self.bars.sats = _sats;
	self.bars.count = _count;
	[self.sky setNeedsDisplay];
	[self.bars setNeedsDisplay];

	/* the modem's GNSS */
	[t appendString:@"THE MODEM'S GNSS (kern.hakios.gnss)\n"];
	if (!have) {
		[t appendString:@"  not there: not the K40 port, or no modem session\n"];
	} else {
		BOOL fix = (g.valid & GNSS_V_POSITION) != 0;

		[t appendFormat:@"  %@, engine %@, %@\n", state_name(g.state), g.engine_state == 1 ? @"on" : g.engine_state == 2 ?
		    @"OFF" : @"?", session_name(g.session_status)];
		[t appendFormat:@"  satellites: %u in view, %u tracked, %u used", _count, tracked, used];
		for (NSString *k in [per.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
			[t appendFormat:@"; %@ %@", k, per[k]];
		}
		[t appendFormat:@"\n  reports %u, fixes %u%@\n", g.reports, g.fixes, g.opmode == 3 ? @", modem OFFLINE" :
		    g.opmode == 0 ? @", modem online" : g.opmode == 1 ? @", modem low power" : @""];
		if (fix) {
			[t appendFormat:@"  %.6f, %.6f", f64(g.latitude_bits), f64(g.longitude_bits)];
			if (g.valid & GNSS_V_ACCURACY) {
				[t appendFormat:@"  ±%.0f m", f32(g.accuracy_bits)];
			}
			[t appendString:@"\n"];
			if (g.valid & (GNSS_V_ALTITUDE_MSL | GNSS_V_ALTITUDE_ELL)) {
				[t appendFormat:@"  altitude %.0f m%@", f32((g.valid & GNSS_V_ALTITUDE_MSL) ? g.altitude_msl_bits :
				    g.altitude_ellipsoid_bits), (g.valid & GNSS_V_ALTITUDE_MSL) ? @" (sea level)" : @" (ellipsoid)"];
				if (g.valid & GNSS_V_VERTICAL) {
					[t appendFormat:@" ±%.0f", f32(g.vertical_bits)];
				}
				[t appendString:@"\n"];
			}
			if (g.valid & (GNSS_V_SPEED | GNSS_V_HEADING)) {
				[t appendFormat:@"  speed %.1f km/h, heading %.0f°\n", (g.valid & GNSS_V_SPEED) ? f32(g.speed_bits) * 3.6 : 0.0,
				    (g.valid & GNSS_V_HEADING) ? f32(g.heading_bits) : 0.0];
			}
			if (g.valid & GNSS_V_UTC) {
				NSDateFormatter *f = [NSDateFormatter new];

				f.dateFormat = @"HH:mm:ss 'UTC'";
				f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
				[t appendFormat:@"  time of fix %@\n", [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:g.utc_ms / 1000.0]]];
			}
		} else {
			[t appendString:@"  no position yet\n"];
		}
	}

	/* iOS's own */
	CLLocation *l = self.lastLocation;

	[t appendString:@"\niOS (CoreLocation)\n"];
	if (self.location.authorizationStatus == kCLAuthorizationStatusDenied ||
	    self.location.authorizationStatus == kCLAuthorizationStatusRestricted) {
		[t appendString:@"  location not allowed\n"];
	} else if (l == nil) {
		[t appendString:@"  no location yet\n"];
	} else {
		[t appendFormat:@"  %.6f, %.6f  ±%.0f m, %.0f s ago\n", l.coordinate.latitude, l.coordinate.longitude,
		    l.horizontalAccuracy, -l.timestamp.timeIntervalSinceNow];
		if (l.verticalAccuracy >= 0) {
			[t appendFormat:@"  altitude %.0f m ±%.0f\n", l.altitude, l.verticalAccuracy];
		}
		if (l.speed >= 0) {
			[t appendFormat:@"  speed %.1f km/h, course %.0f°\n", l.speed * 3.6, l.course];
		}
	}
	[t appendFormat:@"  compass %@\n", isnan(self.heading) ? @"-" : [NSString stringWithFormat:@"%.0f°", self.heading]];
	self.label.text = t;

	/* a console line every 5 s for the computer's tests: counts and accuracy, never the position */
	if (self.ticks++ % 5 == 0) {
		NSLog(@"gpscheck: %@modem %@; engine %u; %@; %u satellites, %u tracked, %u used; %u fixes%@; iOS location %@",
		    self.demo ? @"DEMO " : @"", have ? state_name(g.state) : @"not there", g.engine_state,
		    have ? session_name(g.session_status) : @"-", _count, tracked, used, g.fixes,
		    have && (g.valid & GNSS_V_ACCURACY) && (g.valid & GNSS_V_POSITION) ?
		    [NSString stringWithFormat:@", accuracy %.0f m", f32(g.accuracy_bits)] : @"",
		    l != nil ? [NSString stringWithFormat:@"±%.0f m", l.horizontalAccuracy] : @"none");
	}
}

@end
