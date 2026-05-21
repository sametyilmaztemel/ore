/**
 * captureutil — macOS ScreenCaptureKit + VideoToolbox H.264 encoder.
 *
 * Captures the main display using the modern ScreenCaptureKit API,
 * encodes frames with VideoToolbox hardware encoder, and outputs
 * length-prefixed H.264 NAL units to stdout.
 *
 * Usage: captureutil -fps 30 [-width 1920 -height 1200]
 *
 * Output format (stdout):
 *   [4-byte BIG ENDIAN length][NAL unit data]
 *   Repeated for each encoded NAL unit.
 *
 * Compile:
 *   clang -framework CoreGraphics -framework CoreVideo \
 *         -framework VideoToolbox -framework CoreMedia \
 *         -framework ScreenCaptureKit -framework Foundation \
 *         -o captureutil captureutil.m
 */

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <dispatch/dispatch.h>

// ─── Config ─────────────────────────────────────
static int g_fps = 30;
static int g_targetWidth = 0;
static int g_targetHeight = 0;
static int g_frameCount = 0;
static int g_actualWidth = 0;
static int g_actualHeight = 0;

static VTCompressionSessionRef g_session = NULL;
static dispatch_group_t g_encoderGroup = NULL;
static volatile bool g_running = true;

// ─── VT Output Callback ─────────────────────────
static void compressionOutputCallback(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) return;

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) return;

    size_t lengthAtOffset, totalLength;
    char *dataPointer;
    CMBlockBufferGetDataPointer(dataBuffer, 0, &lengthAtOffset, &totalLength, &dataPointer);
    if (!dataPointer || totalLength == 0) return;

    // Get AVCC-formatted data (length-prefixed NAL units)
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (formatDesc) {
        // Copy the AVCC extradata (SPS/PPS) for the first frame
        size_t spsSize, ppsSize;
        const uint8_t *sps, *pps;
        int spsCount = 0, ppsCount = 0;
        
        if (g_frameCount <= 1) {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &sps, &spsSize, &spsCount, NULL);
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &pps, &ppsSize, &ppsCount, NULL);
            
            if (sps && spsSize > 0) {
                // Write SPS with length prefix
                uint32_t beLen = CFSwapInt32HostToBig((uint32_t)spsSize);
                write(1, &beLen, 4);
                write(1, sps, spsSize);
            }
            if (pps && ppsSize > 0) {
                uint32_t beLen = CFSwapInt32HostToBig((uint32_t)ppsSize);
                write(1, &beLen, 4);
                write(1, pps, ppsSize);
            }
        }
    }

    // Iterate through the sample buffer's NAL units
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) return;

    size_t offset = 0;
    while (offset < totalLength) {
        // Read 4-byte length (AVCC format within sample buffer)
        if (offset + 4 > totalLength) break;
        uint32_t nalLength;
        memcpy(&nalLength, dataPointer + offset, 4);
        nalLength = CFSwapInt32BigToHost(nalLength);
        offset += 4;

        if (offset + nalLength > totalLength) break;

        // Write length-prefixed NAL unit to stdout
        uint32_t beLen = CFSwapInt32HostToBig(nalLength);
        write(1, &beLen, 4);
        write(1, dataPointer + offset, nalLength);
        offset += nalLength;

        g_frameCount++;
    }
}

// ─── Initialize VideoToolbox Encoder ────────────
static int initEncoder(int width, int height) {
    if (g_session) {
        VTCompressionSessionInvalidate(g_session);
        CFRelease(g_session);
        g_session = NULL;
    }

    OSStatus status = VTCompressionSessionCreate(
        NULL, width, height,
        kCMVideoCodecType_H264,
        NULL, NULL, NULL,
        compressionOutputCallback,
        NULL, &g_session
    );
    if (status != noErr) {
        fprintf(stderr, "VTCompressionSessionCreate failed: %d\n", status);
        return -1;
    }

    // Real-time encoding
    VTSessionSetProperty(g_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);

    // Expected frame rate
    CFNumberRef fpsRef = CFNumberCreate(NULL, kCFNumberIntType, &g_fps);
    VTSessionSetProperty(g_session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    // Bitrate based on resolution
    int bitrate = 5000000;
    if (width * height > 1920 * 1080) bitrate = 10000000;
    else if (width * height <= 1280 * 720) bitrate = 3000000;

    CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(g_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // Main profile for compatibility
    CFStringRef profile = CFSTR("H264_Main_AutoLevel");
    VTSessionSetProperty(g_session, kVTCompressionPropertyKey_ProfileLevel, profile);

    // Limit GOP size to ~2 seconds
    int gopSize = g_fps * 2;
    CFNumberRef gopRef = CFNumberCreate(NULL, kCFNumberIntType, &gopSize);
    VTSessionSetProperty(g_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopRef);
    CFRelease(gopRef);

    VTCompressionSessionPrepareToEncodeFrames(g_session);

    g_actualWidth = width;
    g_actualHeight = height;

    return 0;
}

// ─── Encode a CVPixelBuffer ────────────────────
static int encodeFrame(CVPixelBufferRef pixelBuffer) {
    if (!g_session) return -1;

    CMTime pts = CMTimeMake(g_frameCount, g_fps);
    CMTime duration = CMTimeMake(1, g_fps);

    VTEncodeInfoFlags flags;
    OSStatus status = VTCompressionSessionEncodeFrame(
        g_session, pixelBuffer, pts, duration,
        NULL, NULL, &flags
    );

    if (status != noErr) {
        fprintf(stderr, "Encode frame failed: %d\n", status);
        return -2;
    }
    return 0;
}

// ─── SCStream Delegate ──────────────────────────
@interface CaptureDelegate : NSObject <SCStreamOutput>
@end

@implementation CaptureDelegate

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;

    // Get pixel buffer from the stream
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        fprintf(stderr, "No pixel buffer in sample\n");
        return;
    }

    // Encode with VideoToolbox
    encodeFrame(pixelBuffer);
}

@end

// ─── Argument Parsing ──────────────────────────
static void parseArgs(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-fps") == 0 && i + 1 < argc) {
            g_fps = atoi(argv[++i]);
            if (g_fps < 1) g_fps = 30;
            if (g_fps > 60) g_fps = 60;
        } else if (strcmp(argv[i], "-width") == 0 && i + 1 < argc) {
            g_targetWidth = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-height") == 0 && i + 1 < argc) {
            g_targetHeight = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            fprintf(stderr, "Usage: %s [-fps N] [-width W -height H]\n", argv[0]);
            exit(0);
        }
    }
}

// ─── Main ────────────────────────────────────
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        parseArgs(argc, argv);

        // Get the main display size
        CGRect displayBounds = CGDisplayBounds(CGMainDisplayID());
        int captureWidth = (int)CGRectGetWidth(displayBounds);
        int captureHeight = (int)CGRectGetHeight(displayBounds);

        if (g_targetWidth > 0 && g_targetHeight > 0) {
            captureWidth = g_targetWidth;
            captureHeight = g_targetHeight;
        }

        // Initialize encoder
        if (initEncoder(captureWidth, captureHeight) != 0) {
            fprintf(stderr, "Failed to initialize H.264 encoder\n");
            return 1;
        }

        // Get the main display
        if (@available(macOS 15.0, *)) {
            // Use ScreenCaptureKit
            [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
                if (error || content.displays.count == 0) {
                    fprintf(stderr, "No displays found: %s\n", error ? error.description.UTF8String : "unknown");
                    g_running = false;
                    return;
                }

                // Get main display
                SCDisplay *display = content.displays[0];

                // Configure stream
                SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
                config.width = captureWidth;
                config.height = captureHeight;
                config.minimumFrameInterval = CMTimeMake(1, g_fps);
                config.pixelFormat = kCVPixelFormatType_32BGRA;
                config.showsCursor = YES;
                config.capturesAudio = NO;

                // Display filter
                SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                                excludingApplications:@[]
                                                                     exceptingWindows:@[]];

                // Create and start stream
                CaptureDelegate *delegate = [[CaptureDelegate alloc] init];
                SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];

                NSError *addErr = nil;
                [stream addStreamOutput:delegate type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&addErr];
                if (addErr) {
                    fprintf(stderr, "Failed to add output: %s\n", addErr.description.UTF8String);
                    g_running = false;
                    return;
                }

                [stream startCaptureWithCompletionHandler:^(NSError *startErr) {
                    if (startErr) {
                        fprintf(stderr, "Failed to start capture: %s\n", startErr.description.UTF8String);
                        g_running = false;
                        return;
                    }
                    fprintf(stderr, "Capture started: %dx%d @ %d fps\n", captureWidth, captureHeight, g_fps);
                }];
            }];

            // Keep running until interrupted
            NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
            while (g_running && [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) {
                // Run until stopped
            }
        } else {
            fprintf(stderr, "macOS 15+ required for ScreenCaptureKit\n");
            return 1;
        }

        // Cleanup
        if (g_session) {
            VTCompressionSessionCompleteFrames(g_session, CMTimeMake(0, 0));
            VTCompressionSessionInvalidate(g_session);
            CFRelease(g_session);
        }

        fprintf(stderr, "Capture stopped\n");
    }
    return 0;
}
