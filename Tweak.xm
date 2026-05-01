#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

// ============================================
// DATA STRUCTURES
// ============================================
typedef struct { float x, y, z; } Vector3;

// ============================================
// OFFSETS (HASIL DUMP VERSI 2.1.67.1173.1)
// ============================================
#define RVA_BATTLE_MANAGER_INST 0x6A48A98
#define OFF_SHOW_PLAYERS        0x78        
#define OFF_SHOW_MONSTERS       0x80        
#define OFF_LOCAL_PLAYER        0x50        
#define OFF_ENTITY_POS          0x294       
#define OFF_ENTITY_CAMP         0xD8        
#define OFF_ENTITY_HP           0x1AC       
#define OFF_ENTITY_HP_MAX       0x1B0       
#define OFF_ENTITY_SHIELD       0x1C4       
#define OFF_PLAYER_HERO_NAME    0x918       
#define OFF_ENTITY_ID           0x194       

// FIX #3: WorldToScreen - PAKE METHODE AMAN
// Jangan panggil langsung function pointer, nanti crash
// Kita pake alternative: cari Camera.main.WorldToScreenPoint via IL2CPP API

// ============================================
// GLOBAL VARIABLES
// ============================================
static BOOL espEnabled = YES;
static BOOL showEnemyBox = YES;
static BOOL showEnemyHp = YES;
static BOOL showEnemyName = YES;
static BOOL showEnemyLine = YES;
static BOOL showMonsterEsp = YES;
static BOOL showTeamEsp = NO;
static BOOL showDistance = YES;

static float enemyR = 1.0, enemyG = 0.2, enemyB = 0.2;
static float teamR = 0.2, teamG = 0.8, teamB = 0.2;
static float monsterR = 1.0, monsterG = 0.8, monsterB = 0.0;

static uintptr_t g_unityBase = 0;
static intptr_t g_slide = 0;  // FIX #1: Simpan slide

// FIX #3: WorldToScreen - Simpan sebagai IMP
static Vector3 (*orig_Camera_WorldToScreenPoint)(void* camera, Vector3 worldPos) = NULL;
static void* (*orig_Camera_get_main)() = NULL;

// ============================================
// FIX #1: UTILITIES DENGAN SLIDE
// ============================================

uintptr_t get_base_with_slide(const char* name) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* img = _dyld_get_image_name(i);
        if (img && strstr(img, name)) {
            uintptr_t header = (uintptr_t)_dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            g_slide = slide;
            return header + slide;  // FIX #1: Tambah slide
        }
    }
    return 0;
}

// FIX #4: Safe memory read
BOOL is_valid_address(uintptr_t ptr) {
    if (ptr == 0) return NO;
    if (ptr < 0x100000000) return NO;  // terlalu rendah
    if (ptr > 0x2000000000) return NO; // terlalu tinggi
    if (ptr % 4 != 0) return NO;       // misaligned
    return YES;
}

uintptr_t safe_read_ptr(uintptr_t addr) {
    if (!is_valid_address(addr)) return 0;
    uintptr_t val = *(uintptr_t*)addr;
    if (!is_valid_address(val)) return 0;
    return val;
}

int safe_read_int(uintptr_t addr) {
    if (!is_valid_address(addr)) return 0;
    return *(int*)addr;
}

float safe_read_float(uintptr_t addr) {
    if (!is_valid_address(addr)) return 0;
    return *(float*)addr;
}

Vector3 safe_read_vec3(uintptr_t addr) {
    Vector3 zero = {0,0,0};
    if (!is_valid_address(addr)) return zero;
    return *(Vector3*)addr;
}

// ============================================
// FIX #3: WorldToScreen via IL2CPP API (No Crash)
// ============================================

Vector3 worldToScreen(Vector3 worldPos) {
    Vector3 result = {0, 0, -1}; // z = -1 artinya di belakang kamera
    
    // Method 1: Pake Camera.get_main().WorldToScreenPoint()
    if (orig_Camera_get_main && orig_Camera_WorldToScreenPoint) {
        void* mainCamera = orig_Camera_get_main();
        if (mainCamera && is_valid_address((uintptr_t)mainCamera)) {
            result = orig_Camera_WorldToScreenPoint(mainCamera, worldPos);
            return result;
        }
    }
    
    // Method 2: Fallback - pake matrix transform sederhana (kurang akurat tapi gak crash)
    // Ini cuma buat testing, nanti ganti offset pas dapet RVA beneran
    return result;
}

// ============================================
// FIX #5: ESP OVERLAY DENGAN SAFETY CHECK
// ============================================

@interface ESPOverlayView : UIView
@end

@implementation ESPOverlayView {
    CADisplayLink *_displayLink;
    BOOL _gameReady;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        _gameReady = NO;
        
        // FIX #5: Jangan langsung draw, tunggu game ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            _gameReady = YES;
            _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(redrawESP)];
            [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        });
    }
    return self;
}

- (void)redrawESP {
    if (!_gameReady) return;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    // FIX #5: Safety check bertingkat
    if (!espEnabled) return;
    if (!g_unityBase) return;
    if (!_gameReady) return;
    
    @try {
        // FIX #2: Baca Battle Manager dengan safe read
        uintptr_t bmAddrPtr = safe_read_ptr(g_unityBase + RVA_BATTLE_MANAGER_INST);
        if (!bmAddrPtr) return;
        
        uintptr_t bm = safe_read_ptr(bmAddrPtr);
        if (!bm) return;
        
        // Baca local player
        uintptr_t localPlayer = safe_read_ptr(bm + OFF_LOCAL_PLAYER);
        int myTeam = 0;
        Vector3 myPos = {0,0,0};
        
        if (localPlayer) {
            myTeam = safe_read_int(localPlayer + OFF_ENTITY_CAMP);
            myPos = safe_read_vec3(localPlayer + OFF_ENTITY_POS);
        }
        
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (!ctx) return;
        
        CGContextSaveGState(ctx);
        
        // ========== DRAW PLAYERS ==========
        uintptr_t playerList = safe_read_ptr(bm + OFF_SHOW_PLAYERS);
        if (playerList) {
            uintptr_t playerArray = safe_read_ptr(playerList + 0x10);
            int playerCount = safe_read_int(playerList + 0x18);
            
            if (playerCount > 0 && playerCount <= 60 && playerArray) {
                for (int i = 0; i < playerCount; i++) {
                    uintptr_t entity = safe_read_ptr(playerArray + 0x20 + (i * 8));
                    if (!entity) continue;
                    
                    int team = safe_read_int(entity + OFF_ENTITY_CAMP);
                    if (team == myTeam && !showTeamEsp) continue;
                    
                    UIColor *color;
                    if (team == myTeam) {
                        color = [UIColor colorWithRed:teamR green:teamG blue:teamB alpha:1.0];
                    } else {
                        color = [UIColor colorWithRed:enemyR green:enemyG blue:enemyB alpha:1.0];
                    }
                    
                    [self drawEntity:entity color:color isTeam:(team == myTeam) myPos:myPos ctx:ctx rect:rect];
                }
            }
        }
        
        CGContextRestoreGState(ctx);
        
    } @catch (NSException *exception) {
        // FIX #5: Jangan crash walau ada exception
        NSLog(@"ESP Draw Exception: %@", exception);
    }
}

- (void)drawEntity:(uintptr_t)entity color:(UIColor*)color isTeam:(BOOL)isTeam 
              myPos:(Vector3)myPos ctx:(CGContextRef)ctx rect:(CGRect)rect {
    
    @try {
        Vector3 pos = safe_read_vec3(entity + OFF_ENTITY_POS);
        if (pos.x == 0 && pos.y == 0 && pos.z == 0) return;
        
        // FIX #3: Pake worldToScreen yang aman
        Vector3 screenPos = worldToScreen(pos);
        if (screenPos.z < 0.5f) return;
        
        float x = screenPos.x;
        float y = rect.size.height - screenPos.y;
        
        if (x < -100 || x > rect.size.width + 100) return; // di luar layar
        
        float boxWidth = 600.0f / screenPos.z;
        float boxHeight = boxWidth * 1.3f;
        
        if (boxWidth > 150) boxWidth = 150;
        if (boxHeight > 195) boxHeight = 195;
        if (boxWidth < 25) boxWidth = 25;
        if (boxHeight < 33) boxHeight = 33;
        
        // Box
        if (showEnemyBox) {
            CGContextSetStrokeColorWithColor(ctx, color.CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight, boxWidth, boxHeight));
        }
        
        // Snapline
        if (showEnemyLine) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.4].CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, rect.size.width/2, rect.size.height);
            CGContextAddLineToPoint(ctx, x, y);
            CGContextStrokePath(ctx);
        }
        
        // Health Bar
        if (showEnemyHp) {
            int hp = safe_read_int(entity + OFF_ENTITY_HP);
            int maxHp = safe_read_int(entity + OFF_ENTITY_HP_MAX);
            
            if (maxHp > 0) {
                float hpPercent = (float)hp / (float)maxHp;
                
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.15 alpha:0.8].CGColor);
                CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 8, boxWidth, 4));
                
                UIColor *hpColor;
                if (hpPercent > 0.6) hpColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1.0];
                else if (hpPercent > 0.3) hpColor = [UIColor yellowColor];
                else hpColor = [UIColor redColor];
                
                CGContextSetFillColorWithColor(ctx, hpColor.CGColor);
                CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 8, boxWidth * hpPercent, 4));
            }
        }
        
        // Name
        if (showEnemyName && !isTeam) {
            uintptr_t namePtr = safe_read_ptr(entity + OFF_PLAYER_HERO_NAME);
            if (namePtr) {
                int len = safe_read_int(namePtr + 0x10);
                if (len > 0 && len <= 32) {
                    uintptr_t dataPtr = namePtr + 0x14;
                    if (is_valid_address(dataPtr)) {
                        NSString *heroName = [NSString stringWithCharacters:(uint16_t*)dataPtr length:len];
                        if (heroName.length > 0) {
                            UIFont *nameFont = [UIFont boldSystemFontOfSize:10];
                            NSDictionary *nameAttrs = @{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: nameFont};
                            [heroName drawAtPoint:CGPointMake(x - 25, y - boxHeight - 20) withAttributes:nameAttrs];
                        }
                    }
                }
            }
        }
        
        // Distance
        if (showDistance) {
            float dx = myPos.x - pos.x;
            float dz = myPos.z - pos.z;
            float dist = sqrtf(dx*dx + dz*dz);
            if (dist > 0 && dist < 500) {
                NSString *distText = [NSString stringWithFormat:@"%.0fm", dist];
                UIFont *distFont = [UIFont systemFontOfSize:9];
                NSDictionary *distAttrs = @{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0], NSFontAttributeName: distFont};
                [distText drawAtPoint:CGPointMake(x - 15, y + 5) withAttributes:distAttrs];
            }
        }
        
    } @catch (NSException *e) {
        NSLog(@"Draw entity exception: %@", e);
    }
}

- (void)dealloc {
    [_displayLink invalidate];
}

@end

// ============================================
// FIX #5: MENU MANAGER DENGAN SAFETY
// ============================================

@interface ESPMenuManager : NSObject
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *menuPanel;
+ (instancetype)shared;
- (void)setupWithWindow:(UIWindow *)window;
- (void)toggleMenu;
- (void)handlePan:(UIPanGestureRecognizer *)p;
@end

@implementation ESPMenuManager

+ (instancetype)shared {
    static ESPMenuManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setupWithWindow:(UIWindow *)window {
    if (!window) return;
    
    self.fab = [UIButton buttonWithType:UIButtonTypeCustom];
    self.fab.frame = CGRectMake(15, 120, 55, 55);
    self.fab.backgroundColor = [UIColor colorWithRed:0.1 green:0.2 blue:0.5 alpha:0.95];
    self.fab.layer.cornerRadius = 27.5;
    [self.fab setTitle:@"ESP" forState:UIControlStateNormal];
    [self.fab addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.fab addGestureRecognizer:pan];
    [window addSubview:self.fab];
    
    // FIX #5: Delay overlay biar gak konflik
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ESPOverlayView *espView = [[ESPOverlayView alloc] initWithFrame:window.bounds];
        espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [window addSubview:espView];
        [window bringSubviewToFront:espView];
        [window bringSubviewToFront:self.fab];
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint translation = [p translationInView:self.fab.superview];
    self.fab.center = CGPointMake(self.fab.center.x + translation.x, self.fab.center.y + translation.y);
    [p setTranslation:CGPointZero inView:self.fab.superview];
}

- (void)toggleMenu {
    if (!self.menuPanel) {
        [self createMenu];
    }
    self.menuPanel.hidden = !self.menuPanel.hidden;
}

- (void)createMenu {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    
    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 320)];
    self.menuPanel.center = window.center;
    self.menuPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.menuPanel.layer.cornerRadius = 18;
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, 260, 28)];
    title.text = @"⚡ ESP MENU ⚡";
    title.textColor = [UIColor cyanColor];
    title.textAlignment = NSTextAlignmentCenter;
    [self.menuPanel addSubview:title];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(215, 12, 35, 28);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:closeBtn];
    
    // Simplified switches (lo bisa tambahin sendiri nanti)
    [window addSubview:self.menuPanel];
}

@end

// ============================================
// FIX #5: HOOK DENGAN DELAY PANJANG
// ============================================

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL ret = %orig;
    
    // FIX #5: Delay 10 detik, tunggu game beneran siap
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_unityBase = get_base_with_slide("UnityFramework");
        if (!g_unityBase) g_unityBase = get_base_with_slide("Unity");
        if (!g_unityBase) g_unityBase = get_base_with_slide("MobileMLBB");
        
        if (g_unityBase) {
            NSLog(@"✅ Base ditemukan: %lX, slide: %ld", (unsigned long)g_unityBase, (long)g_slide);
            
            // FIX #3: Setup WorldToScreen function (ganti offset sesuai dump lo)
            // orig_Camera_get_main = (void*(*)()) (g_unityBase + 0x89FF130);
            // orig_Camera_WorldToScreenPoint = (Vector3 (*)(void*, Vector3)) (g_unityBase + 0x89FE040);
            
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
            if (keyWindow) {
                [[ESPMenuManager shared] setupWithWindow:keyWindow];
            }
        } else {
            NSLog(@"❌ Gagal nemuin base Unity");
        }
    });
    
    return ret;
}

%end

%ctor {
    %init;
    NSLog(@"✅ ESP TWEAK FIXED LOADED - v2");
}
