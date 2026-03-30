#import <AppKit/AppKit.h>

// Copy text to clipboard
void copyToClipboard(const char *text) {
    NSString *str = [NSString stringWithUTF8String:text];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:str forType:NSPasteboardTypeString];
    NSLog(@"[Clipboard] Copied to clipboard: %@", str);
}
