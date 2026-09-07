#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#include <math.h>

static char *logoJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

/// Renders a mark centered on a screen-sized light or dark canvas and writes
/// it as JPEG 2000, the format the boot logo path expects. Width and height
/// of zero use the main screen's native portrait pixel size.
char *icli_bootlogo_render_json(const char *mark_path, const char *output_path, bool dark, int width, int height, double mark_points) {
    if (!mark_path || !output_path) return logoJSON(@{@"error": @"mark and output paths required"});
    icli_private_init();
    double scale = UIScreen.mainScreen.nativeScale;
    if (width <= 0 || height <= 0) {
        CGSize native = UIScreen.mainScreen.nativeBounds.size;
        width = (int)MIN(native.width, native.height);
        height = (int)MAX(native.width, native.height);
    }
    if (!isfinite(scale) || scale <= 0) scale = icli_screen_metrics().scale ?: 1;
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return logoJSON(@{@"error": @"screen pixel size unavailable; pass --width and --height"});
    double markSide = round((mark_points > 0 ? mark_points : 128) * scale);

    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(mark_path)], NULL);
    CGImageRef mark = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    if (!mark) return logoJSON(@{@"error": @"mark image could not be decoded"});
    size_t markWidth = CGImageGetWidth(mark), markHeight = CGImageGetHeight(mark);
    double maximum = MIN(markSide, MIN(width, height));
    double fit = MIN(maximum / markWidth, maximum / markHeight);
    double fittedWidth = floor(markWidth * fit), fittedHeight = floor(markHeight * fit);
    if (fittedWidth < 1 || fittedHeight < 1) { CGImageRelease(mark); return logoJSON(@{@"error": @"mark image is too small to render"}); }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, (size_t)width * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(colorSpace);
    if (!context) { CGImageRelease(mark); return logoJSON(@{@"error": @"bitmap context allocation failed"}); }
    double background = dark ? 0 : 1;
    CGContextSetRGBFillColor(context, background, background, background, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextDrawImage(context, CGRectMake(floor((width - fittedWidth) / 2), floor((height - fittedHeight) / 2), fittedWidth, fittedHeight), mark);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageRelease(mark);
    if (!image) return logoJSON(@{@"error": @"boot logo could not be rendered"});

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg-2000"), 1, NULL);
    BOOL encoded = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @1.0});
        encoded = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    if (!encoded || data.length == 0) return logoJSON(@{@"error": @"ImageIO could not encode JPEG 2000"});
    NSError *error = nil;
    if (![data writeToFile:@(output_path) options:NSDataWritingAtomic error:&error]) return logoJSON(@{@"error": error.localizedDescription ?: @"boot logo could not be written"});
    return logoJSON(@{@"path": @(output_path), @"width": @(width), @"height": @(height), @"scale": @(scale), @"appearance": dark ? @"dark" : @"light", @"mark_pixels": @[@(fittedWidth), @(fittedHeight)], @"bytes": @(data.length), @"format": @"public.jpeg-2000"});
}
