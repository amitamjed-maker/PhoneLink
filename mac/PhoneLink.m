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
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.ip = [d stringForKey:@"ip"] ?: @"";
    self.pin = [d stringForKey:@"pin"] ?: @"";
    self.callState = @"idle"; self.callNumber = @""; self.callName = @"";
    self.clipSeq = -1;
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
    [m addItem:[NSMenuItem separatorItem]];
    if ([self.callState isEqualToString:@"ringing"]) {
        [self add:m title:@"✅ কল ধরুন" sel:@selector(answer)];
        [self add:m title:@"❌ কল কেটে দিন" sel:@selector(reject)];
    } else if ([self.callState isEqualToString:@"offhook"]) {
        [self add:m title:@"❌ কল শেষ করুন" sel:@selector(reject)];
    }
    [self add:m title:@"📞 ফোন থেকে কল করুন…" sel:@selector(dial)];
    [self add:m title:@"📋 ক্লিপবোর্ড ফোনে পাঠান" sel:@selector(sendClip)];
    [self add:m title:@"📁 ফাইল ফোনে পাঠান…" sel:@selector(sendFiles)];
    [m addItem:[NSMenuItem separatorItem]];
    [self add:m title:@"⚙️ সেটিংস (আইপি ও পিন)…" sel:@selector(settings)];
    [self add:m title:@"বের হন" sel:@selector(quit)];
}
- (void)add:(NSMenu *)m title:(NSString *)t sel:(SEL)s {
    NSMenuItem *i = [m addItemWithTitle:t action:s keyEquivalent:@""]; i.target = self;
}

#pragma mark - actions

- (void)answer { [self req:@"POST" path:@"/answer" body:nil timeout:5 done:nil]; }
- (void)reject { [self req:@"POST" path:@"/reject" body:nil timeout:5 done:nil]; }
- (void)quit { [NSApp terminate:nil]; }

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
    self.clipSeq = -1;
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
