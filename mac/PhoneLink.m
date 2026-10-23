#import <Cocoa/Cocoa.h>

static NSString *enc(NSString *s) {
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:ok];
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSUserNotificationCenterDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSString *ip, *pin;
@property (assign) BOOL connected;
@property (strong) NSString *callState, *callNumber, *callName, *lastKey;
@property (assign) NSInteger clipSeq;
@property (assign) NSInteger battery;
@property (assign) BOOL charging, lowNotified, screenOn, showNotifs, looping;
@property (assign) NSInteger notifSeq, frameSeq;
@property (strong) NSWindow *screenWin;
@property (strong) NSImageView *screenView;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.ip = [d stringForKey:@"ip"] ?: @"";
    self.pin = [d stringForKey:@"pin"] ?: @"";
    self.showNotifs = [d objectForKey:@"showNotifs"] ? [d boolForKey:@"showNotifs"] : YES;
    self.callState = @"idle"; self.callNumber = @""; self.callName = @"";
    self.clipSeq = -1; self.notifSeq = -1; self.battery = -1;
    [NSUserNotificationCenter defaultUserNotificationCenter].delegate = self;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title = @"📵";
    NSMenu *m = [NSMenu new]; m.delegate = self; self.item.menu = m;
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    if (self.ip.length == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self settings]; });
    }
}

#pragma mark - network

- (void)req:(NSString *)method path:(NSString *)path body:(NSData *)body timeout:(NSTimeInterval)t done:(void (^)(NSData *, NSInteger))done {
    if (self.ip.length == 0) { if (done) done(nil, 0); return; }
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:8765%@", self.ip, path]];
    if (!u) { if (done) done(nil, 0); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:t];
    r.HTTPMethod = method;
    [r setValue:self.pin forHTTPHeaderField:@"X-Pin"];
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSInteger code = e ? 0 : [(NSHTTPURLResponse *)resp statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(data, code); });
    };
    NSURLSessionTask *task = body
        ? [[NSURLSession sharedSession] uploadTaskWithRequest:r fromData:body completionHandler:h]
        : [[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:h];
    [task resume];
}

- (void)poll {
    [self req:@"GET" path:@"/state" body:nil timeout:2 done:^(NSData *d, NSInteger code) {
        self.connected = (code == 200 && d);
        self.item.button.title = self.connected ? @"📱" : @"📵";
        if (!self.connected) return;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return;

        // call
        NSString *st = j[@"call"] ?: @"idle", *num = j[@"number"] ?: @"", *nm = j[@"name"] ?: @"";
        self.callState = st; self.callNumber = num; self.callName = nm;
        NSString *key = [NSString stringWithFormat:@"%@|%@", st, num];
        if (![key isEqualToString:self.lastKey]) {
            self.lastKey = key;
            if ([st isEqualToString:@"ringing"]) {
                NSString *who = nm.length ? [NSString stringWithFormat:@"%@ (%@)", nm, num] : (num.length ? num : @"অজানা নম্বর");
                [self notify:@"📞 ফোনে কল আসছে" text:who action:@"কল ধরুন"];
            } else if ([st isEqualToString:@"idle"]) {
                [[NSUserNotificationCenter defaultUserNotificationCenter] removeAllDeliveredNotifications];
            }
        }

        // clipboard
        NSInteger seq = [j[@"clipSeq"] integerValue];
        if (self.clipSeq < 0) self.clipSeq = seq;
        else if (seq > self.clipSeq) {
            self.clipSeq = seq;
            NSString *t = j[@"clipText"] ?: @"";
            if (t.length) {
                NSPasteboard *pb = [NSPasteboard generalPasteboard];
                [pb clearContents]; [pb setString:t forType:NSPasteboardTypeString];
                [self notify:@"📋 ফোনের ক্লিপবোর্ড কপি হয়েছে" text:t action:nil];
            }
        }

        // battery
        self.battery = [j[@"battery"] integerValue];
        self.charging = [j[@"charging"] boolValue];
        if (self.battery > 0 && self.battery <= 15 && !self.charging) {
            if (!self.lowNotified) {
                self.lowNotified = YES;
                [self notify:@"🪫 ফোনের ব্যাটারি কম" text:[NSString stringWithFormat:@"%ld%% বাকি", (long)self.battery] action:nil];
            }
        } else if (self.battery > 20 || self.charging) {
            self.lowNotified = NO;
        }

        // screen state
        self.screenOn = [j[@"screen"] boolValue];

        // phone notifications
        NSArray *ns = j[@"notifs"];
        if ([ns isKindOfClass:[NSArray class]]) {
            NSInteger mx = 0;
            for (NSDictionary *o in ns) {
                NSInteger sq = [o[@"seq"] integerValue];
                if (sq > mx) mx = sq;
                if (self.notifSeq >= 0 && sq > self.notifSeq && self.showNotifs) {
                    NSString *t = o[@"title"] ?: @"", *tx = o[@"text"] ?: @"";
                    NSString *body = t.length ? (tx.length ? [NSString stringWithFormat:@"%@: %@", t, tx] : t) : tx;
                    [self notify:[NSString stringWithFormat:@"📲 %@", o[@"app"] ?: @""] text:body action:nil];
                }
            }
            self.notifSeq = mx;
        }
    }];
}

#pragma mark - notifications

- (void)notify:(NSString *)title text:(NSString *)text action:(NSString *)action {
    NSUserNotification *n = [NSUserNotification new];
    n.title = title; n.informativeText = text;
    n.soundName = NSUserNotificationDefaultSoundName;
    if (action) { n.hasActionButton = YES; n.actionButtonTitle = action; n.userInfo = @{@"answer": @YES}; }
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:n];
}
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)c shouldPresentNotification:(NSUserNotification *)n { return YES; }
- (void)userNotificationCenter:(NSUserNotificationCenter *)c didActivateNotification:(NSUserNotification *)n {
    if (n.userInfo[@"answer"]) [self answer];
}

#pragma mark - menu

- (void)menuNeedsUpdate:(NSMenu *)m {
    [m removeAllItems];
    NSString *head = self.connected ? [NSString stringWithFormat:@"✅ ফোনের সাথে যুক্ত (%@)", self.ip] : @"❌ ফোনের সাথে যুক্ত নেই";
    NSMenuItem *h = [m addItemWithTitle:head action:nil keyEquivalent:@""]; h.enabled = NO;
    if (self.connected && self.battery >= 0) {
        NSString *b = [NSString stringWithFormat:@"🔋 ফোনের ব্যাটারি: %ld%%%@", (long)self.battery, self.charging ? @" ⚡ চার্জ হচ্ছে" : @""];
        NSMenuItem *bi = [m addItemWithTitle:b action:nil keyEquivalent:@""]; bi.enabled = NO;
    }
    [m addItem:[NSMenuItem separatorItem]];
    if ([self.callState isEqualToString:@"ringing"]) {
        [self add:m title:@"✅ কল ধরুন" sel:@selector(answer)];
        [self add:m title:@"❌ কল কেটে দিন" sel:@selector(reject)];
    } else if ([self.callState isEqualToString:@"offhook"]) {
        [self add:m title:@"❌ কল শেষ করুন" sel:@selector(reject)];
    }
    [self add:m title:@"📞 ফোন থেকে কল করুন…" sel:@selector(dial)];
    [self add:m title:@"🖥 ফোনের স্ক্রিন দেখুন" sel:@selector(openScreen)];
    [self add:m title:@"📍 ফোনের লোকেশন দেখুন" sel:@selector(location)];
    [self add:m title:@"📋 ক্লিপবোর্ড ফোনে পাঠান" sel:@selector(sendClip)];
    [self add:m title:@"📁 ফাইল ফোনে পাঠান…" sel:@selector(sendFiles)];
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *tn = [self add:m title:@"📲 ফোনের নোটিফিকেশন দেখানো" sel:@selector(toggleNotifs)];
    tn.state = self.showNotifs ? NSControlStateValueOn : NSControlStateValueOff;
    [self add:m title:@"⚙️ সেটিংস (আইপি ও পিন)…" sel:@selector(settings)];
    [self add:m title:@"বের হন" sel:@selector(quit)];
}
- (NSMenuItem *)add:(NSMenu *)m title:(NSString *)t sel:(SEL)s {
    NSMenuItem *i = [m addItemWithTitle:t action:s keyEquivalent:@""]; i.target = self;
    return i;
}

#pragma mark - actions

- (void)answer { [self req:@"POST" path:@"/answer" body:nil timeout:5 done:nil]; }
- (void)reject { [self req:@"POST" path:@"/reject" body:nil timeout:5 done:nil]; }
- (void)quit { [NSApp terminate:nil]; }

- (void)toggleNotifs {
    self.showNotifs = !self.showNotifs;
    [[NSUserDefaults standardUserDefaults] setBool:self.showNotifs forKey:@"showNotifs"];
}

- (void)dial {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [NSAlert new];
    a.messageText = @"যে নম্বরে কল করবেন";
    a.informativeText = @"কলটি আপনার ফোন থেকে যাবে।";
    [a addButtonWithTitle:@"কল করুন"]; [a addButtonWithTitle:@"বাতিল"];
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    a.accessoryView = f;
    a.window.initialFirstResponder = f;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *num = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!num.length) return;
    [self req:@"POST" path:[NSString stringWithFormat:@"/dial?number=%@", enc(num)] body:nil timeout:5 done:^(NSData *d, NSInteger code) {
        if (code != 200) [self notify:@"কল করা যায়নি" text:@"ফোনের সাথে যুক্ত আছে কিনা দেখুন" action:nil];
    }];
}

- (void)sendClip {
    NSString *t = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!t.length) { [self notify:@"ক্লিপবোর্ড খালি" text:@"" action:nil]; return; }
    [self req:@"POST" path:@"/clip" body:[t dataUsingEncoding:NSUTF8StringEncoding] timeout:10 done:^(NSData *d, NSInteger code) {
        [self notify:(code == 200 ? @"📋 ফোনে পাঠানো হয়েছে" : @"পাঠানো যায়নি") text:@"" action:nil];
    }];
}

- (void)sendFiles {
    [NSApp activateIgnoringOtherApps:YES];
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = YES;
    if ([p runModal] != NSModalResponseOK) return;
    for (NSURL *u in p.URLs) {
        NSData *data = [NSData dataWithContentsOfURL:u];
        if (!data) continue;
        NSString *name = u.lastPathComponent;
        [self req:@"POST" path:[NSString stringWithFormat:@"/file?name=%@", enc(name)] body:data timeout:900 done:^(NSData *d, NSInteger code) {
            [self notify:(code == 200 ? @"📁 ফাইল পাঠানো হয়েছে" : @"ফাইল পাঠানো যায়নি") text:name action:nil];
        }];
    }
}

- (void)location {
    [self notify:@"📍 লোকেশন খোঁজা হচ্ছে…" text:@"কয়েক সেকেন্ড লাগতে পারে" action:nil];
    [self req:@"GET" path:@"/location" body:nil timeout:15 done:^(NSData *d, NSInteger code) {
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (code == 200 && [j isKindOfClass:[NSDictionary class]] && j[@"lat"]) {
            NSString *url = [NSString stringWithFormat:@"https://www.google.com/maps?q=%@,%@", j[@"lat"], j[@"lon"]];
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
            [self notify:@"📍 ফোনের লোকেশন" text:[NSString stringWithFormat:@"সঠিকতা প্রায় %@ মিটার", j[@"acc"]] action:nil];
        } else {
            [self notify:@"লোকেশন পাওয়া যায়নি" text:@"ফোনে লোকেশন (GPS) চালু ও পারমিশন দেওয়া আছে কিনা দেখুন" action:nil];
        }
    }];
}

#pragma mark - screen

- (void)openScreen {
    if (!self.screenWin) {
        NSRect r = NSMakeRect(0, 0, 360, 640);
        self.screenWin = [[NSWindow alloc] initWithContentRect:r
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
            backing:NSBackingStoreBuffered defer:NO];
        self.screenWin.title = @"ফোনের স্ক্রিন";
        self.screenWin.releasedWhenClosed = NO;
        self.screenView = [[NSImageView alloc] initWithFrame:r];
        self.screenView.imageScaling = NSImageScaleProportionallyUpOrDown;
        self.screenView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.screenWin.contentView = self.screenView;
        [self.screenWin center];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.screenWin makeKeyAndOrderFront:nil];
    self.frameSeq = 0;
    if (!self.looping) { self.looping = YES; [self frameLoop]; }
}

static NSString *headerValue(NSHTTPURLResponse *h, NSString *name) {
    for (NSString *k in h.allHeaderFields) {
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) return [NSString stringWithFormat:@"%@", h.allHeaderFields[k]];
    }
    return @"0";
}

- (void)frameLoop {
    if (!self.screenWin.isVisible) { self.looping = NO; return; }
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:8765/frame?after=%ld", self.ip, (long)self.frameSeq]];
    if (!u) { self.looping = NO; return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
    [r setValue:self.pin forHTTPHeaderField:@"X-Pin"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        NSInteger code = e ? 0 : h.statusCode;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (code == 200 && d) {
                NSImage *img = [[NSImage alloc] initWithData:d];
                if (img) self.screenView.image = img;
                self.frameSeq = [headerValue(h, @"X-Seq") integerValue];
                [self frameLoop];
            } else if (code == 204) {
                [self frameLoop];
            } else if (code == 409) {
                [self.screenWin orderOut:nil];
                self.looping = NO;
                [self notify:@"স্ক্রিন শেয়ার চালু নেই" text:@"ফোনের PhoneLink অ্যাপে 'স্ক্রিন শেয়ার চালু করুন' চাপুন" action:nil];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self frameLoop]; });
            }
        });
    }] resume];
}

#pragma mark - settings

- (void)settings {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [NSAlert new];
    a.messageText = @"ফোনের সাথে যুক্ত করুন";
    a.informativeText = @"ফোনের PhoneLink অ্যাপে দেখানো আইপি ও পিন দিন।";
    [a addButtonWithTitle:@"সেভ"]; [a addButtonWithTitle:@"বাতিল"];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 58)];
    NSTextField *ipf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 34, 260, 24)];
    NSTextField *pinf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    ipf.placeholderString = @"আইপি (যেমন 192.168.0.105)";
    pinf.placeholderString = @"পিন";
    ipf.stringValue = self.ip ?: @""; pinf.stringValue = self.pin ?: @"";
    [v addSubview:ipf]; [v addSubview:pinf];
    a.accessoryView = v;
    a.window.initialFirstResponder = ipf;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    self.ip = [ipf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    self.pin = [pinf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.ip forKey:@"ip"]; [d setObject:self.pin forKey:@"pin"]; [d synchronize];
    self.clipSeq = -1; self.notifSeq = -1;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
