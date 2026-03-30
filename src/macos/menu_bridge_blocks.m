#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Zig callback exports
extern void zig_menuJoinNetwork(void);
extern void zig_menuJoinNetwork_withId(const char *networkId);
extern void zig_menuShowNetworks(void);
extern void zig_menuShowStatus(void);
extern void zig_menuQuit(void);
extern void zig_menuCopyNodeId(void);
extern void zig_menuNeedsUpdate(void);
extern void zig_leaveNetwork(int index);

// Forward declaration
void showJoinNetworkDialog(void);

// MenuHandler: receives menu item actions and serves as NSMenuDelegate
@interface MenuHandler : NSObject <NSMenuDelegate>
@end

@implementation MenuHandler

- (void)handleAction:(NSMenuItem *)sender {
    long tag = sender.tag;

    // Tags 100+ are "Leave Network" for network at index (tag - 100)
    if (tag >= 100 && tag < 200) {
        zig_leaveNetwork((int)(tag - 100));
        return;
    }

    switch (tag) {
        case 1:
            showJoinNetworkDialog();
            break;
        case 2:
            zig_menuShowNetworks();
            break;
        case 3:
            zig_menuShowStatus();
            break;
        case 4:
            [[NSApplication sharedApplication] terminate:nil];
            break;
        case 5:
            zig_menuCopyNodeId();
            break;
        default:
            break;
    }
}

// NSMenuDelegate: called before the menu is displayed
- (void)menuNeedsUpdate:(NSMenu *)menu {
    zig_menuNeedsUpdate();
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    return YES;
}

@end

// Global handler instance
static MenuHandler *g_handler = nil;

void* createMenuHandler(void) {
    if (!g_handler) {
        g_handler = [[MenuHandler alloc] init];
        [g_handler retain];
    }
    return g_handler;
}

NSMenuItem* createMenuItem(const char *title, int tag) {
    NSString *titleStr = [NSString stringWithUTF8String:title];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titleStr
                                                  action:@selector(handleAction:)
                                           keyEquivalent:@""];
    item.tag = tag;
    item.target = g_handler;
    item.enabled = YES;
    return item;
}

void setMenuDelegate(void *menu, void *handler) {
    [(NSMenu *)menu setDelegate:(MenuHandler *)handler];
}

// Button action handler for the join dialog
@interface JoinDialogHandler : NSObject {
    @public NSTextField *inputField;
    @public NSPanel *panel;
}
- (void)joinClicked:(id)sender;
- (void)cancelClicked:(id)sender;
@end

@implementation JoinDialogHandler
- (void)joinClicked:(id)sender {
    (void)sender;
    [NSApp stopModalWithCode:1];
    [panel orderOut:nil];
}
- (void)cancelClicked:(id)sender {
    (void)sender;
    [NSApp stopModalWithCode:0];
    [panel orderOut:nil];
}
@end

// Join Network dialog using NSPanel for proper keyboard focus
void showJoinNetworkDialog(void) {
    NSApplication *app = [NSApplication sharedApplication];

    // Switch to Regular so we get keyboard focus and a main menu bar
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app activateIgnoringOtherApps:YES];

    // Create a minimal Edit menu so Cmd+V/C/X/A work in the text field
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];
    [app setMainMenu:mainMenu];

    // Create panel
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 340, 150)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [panel setTitle:@"Join ZeroTier Network"];
    [panel setLevel:NSFloatingWindowLevel];
    [panel center];

    NSView *content = [panel contentView];

    // Label
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 300, 20)];
    [label setStringValue:@"Enter the 16-character network ID:"];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [content addSubview:label];

    // Text input
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 65, 300, 24)];
    [input setPlaceholderString:@"e.g. 8056c2e21c000001"];
    [input setEditable:YES];
    [input setSelectable:YES];
    [input setBezeled:YES];
    [input setBezelStyle:NSTextFieldSquareBezel];
    [content addSubview:input];

    // Handler for button actions
    JoinDialogHandler *handler = [[JoinDialogHandler alloc] init];
    handler->inputField = input;
    handler->panel = panel;

    // Join button
    NSButton *joinBtn = [[NSButton alloc] initWithFrame:NSMakeRect(230, 15, 90, 32)];
    [joinBtn setTitle:@"Join"];
    [joinBtn setBezelStyle:NSBezelStyleRounded];
    [joinBtn setTarget:handler];
    [joinBtn setAction:@selector(joinClicked:)];
    [joinBtn setKeyEquivalent:@"\r"]; // Enter key
    [content addSubview:joinBtn];

    // Cancel button
    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(130, 15, 90, 32)];
    [cancelBtn setTitle:@"Cancel"];
    [cancelBtn setBezelStyle:NSBezelStyleRounded];
    [cancelBtn setTarget:handler];
    [cancelBtn setAction:@selector(cancelClicked:)];
    [cancelBtn setKeyEquivalent:@"\033"]; // Escape key
    [content addSubview:cancelBtn];

    // Show panel and set keyboard focus to text field
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:input];

    // Run modal
    NSInteger result = [NSApp runModalForWindow:panel];

    if (result == 1) {
        NSString *networkId = [input.stringValue stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (networkId.length == 16) {
            zig_menuJoinNetwork_withId(networkId.UTF8String);
        } else if (networkId.length > 0) {
            NSAlert *err = [[NSAlert alloc] init];
            err.messageText = @"Invalid Network ID";
            err.informativeText = [NSString stringWithFormat:
                @"Network ID must be exactly 16 hex characters. You entered %lu characters.",
                (unsigned long)networkId.length];
            [err addButtonWithTitle:@"OK"];
            [err runModal];
            [err release];
        }
    }

    // Restore menu-bar-only mode (no dock icon)
    [app setMainMenu:nil];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [mainMenu release];
    [editMenu release];
    [editMenuItem release];
    [handler release];
    [label release];
    [input release];
    [joinBtn release];
    [cancelBtn release];
    [panel release];
}
