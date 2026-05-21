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