#!/usr/bin/env python3
"""Produce a reviewable derivative of Apple's pinned MIT sample; no installation."""
from pathlib import Path
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent


def function(source, name, transform):
    match = re.search(r"^static [^\n]+\b" + name + r"\([^;\n]*\)\n\{", source, re.M)
    if not match:
        raise ValueError(f"Definition missing: {name}")
    end = source.index("\n}", match.end()) + 2
    return source[:match.start()] + transform(source[match.start():end]) + source[end:]


def case(body, selector, replacement):
    pattern = r"\t\tcase " + selector + r":.*?(?=\n\t\t(?:case |default:)|\n\t};)"
    result, count = re.subn(pattern, lambda _: "\t\tcase " + selector + ":\n" + replacement + "\n", body, flags=re.S)
    if count != 1:
        raise ValueError(f"Expected one case for {selector}, found {count}")
    return result


def main():
    original = (HERE / "vendor/NullAudio.c").read_bytes()
    pin = json.loads((HERE / 'upstream.json').read_text())
    if hashlib.sha256(original).hexdigest() != pin['sourceSHA256']:
        raise SystemExit('Apple sample differs from the pinned source; review the upstream update first.')
    source = original.decode()
    source = source.replace('#include <CoreAudio/AudioServerPlugIn.h>', '#include <CoreAudio/AudioServerPlugIn.h>\n#include "Loopback.h"')
    source = source.replace('"com.apple.audio.NullAudio"', '"local.localspeak.mic.driver"')
    source = source.replace('"NullAudioBox_UID"', '"local.localspeak.mic.box.v1"')
    source = source.replace('"NullAudioDevice_UID"', '"local.localspeak.mic.device.v1"')
    source = source.replace('"NullAudioDevice_ModelUID"', '"local.localspeak.mic.model.v1"')
    for old, new in [('"DeviceName"', '"Local TTS Mic"'), ('"Null Box"', '"Local TTS Mic"'),
                     ('"ManufacturerName"', '"Local TTS Mic"'), ('"MasterElementName"', '"Main"'),
                     ('"LeftElementName"', '"Left"'), ('"RightElementName"', '"Right"')]:
        source = source.replace(old, new)
    source = source.replace('= 44100.0;', '= 48000.0;')
    source = source.replace('(inChangeAction != 44100) && (inChangeAction != 48000)', '(inChangeAction != 48000)')
    # Only 48 kHz is advertised and accepted. No clock reconfiguration during IO.
    source = source.replace(' != 44100.0)', ' != 48000.0)')
    source = source.replace('case 44100:', 'case 48000:') if 'case 48000:' not in source else source

    def device_sizes(body):
        body = case(body, 'kAudioObjectPropertyOwnedObjects', '\t\t\t*outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeGlobal ? 2 : 1) * sizeof(AudioObjectID);\n\t\t\tbreak;')
        body = case(body, 'kAudioObjectPropertyControlList', '\t\t\t*outDataSize = 0;\n\t\t\tbreak;')
        return case(body, 'kAudioDevicePropertyAvailableNominalSampleRates', '\t\t\t*outDataSize = sizeof(AudioValueRange);\n\t\t\tbreak;')
    source = function(source, 'NullAudio_GetDevicePropertyDataSize', device_sizes)

    def device_data(body):
        body = case(body, 'kAudioObjectPropertyOwnedObjects', '''            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
            UInt32 available = inAddress->mScope == kAudioObjectPropertyScopeGlobal ? 2 : 1;
            if (theNumberItemsToFetch > available) theNumberItemsToFetch = available;
            if (theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = inAddress->mScope == kAudioObjectPropertyScopeOutput ? kObjectID_Stream_Output : kObjectID_Stream_Input;
            if (theNumberItemsToFetch > 1) ((AudioObjectID*)outData)[1] = kObjectID_Stream_Output;
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;''')
        body = case(body, 'kAudioObjectPropertyControlList', '            *outDataSize = 0;\n            break;')
        body = case(body, 'kAudioDevicePropertyAvailableNominalSampleRates', '''            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioValueRange)) {
                ((AudioValueRange*)outData)[0] = (AudioValueRange){48000, 48000};
                *outDataSize = sizeof(AudioValueRange);
            }
            break;''')
        body = case(body, 'kAudioDevicePropertyLatency', '''            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Latency size");
            *((UInt32*)outData) = inAddress->mScope == kAudioObjectPropertyScopeInput ? LSM_DELAY : 0;
            *outDataSize = sizeof(UInt32);
            break;''')
        body = case(body, 'kAudioDevicePropertyDeviceCanBeDefaultDevice', '''            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Default device size");
            *((UInt32*)outData) = inAddress->mScope == kAudioObjectPropertyScopeInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;''')
        # Explicit selection is supported, but system sounds must stay on speakers.
        return case(body, 'kAudioDevicePropertyDeviceCanBeDefaultSystemDevice', '''            FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "Default device size");
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;''')
    source = function(source, 'NullAudio_GetDevicePropertyData', device_data)

    def stream_sizes(body):
        return body.replace('2 * sizeof(AudioStreamRangedDescription)', 'sizeof(AudioStreamRangedDescription)')
    source = function(source, 'NullAudio_GetStreamPropertyDataSize', stream_sizes)

    def stream_data(body):
        # Sample code shares the two available-format case labels.
        start = body.index('\t\tcase kAudioStreamPropertyAvailableVirtualFormats:')
        end = body.index('\n\t\tdefault:', start)
        body = body[:start] + '''        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioStreamRangedDescription)) {
                AudioStreamRangedDescription *range = outData;
                range->mFormat = (AudioStreamBasicDescription){48000, kAudioFormatLinearPCM,
                    kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                    8, 1, 8, 2, 32, 0};
                range->mSampleRateRange = (AudioValueRange){48000, 48000};
                *outDataSize = sizeof(AudioStreamRangedDescription);
            }
            break;
''' + body[end:]
        return body
    source = function(source, 'NullAudio_GetStreamPropertyData', stream_data)
    # Fixed-rate config requests cannot alter the timebase even through direct calls.
    source = function(source, 'NullAudio_PerformDeviceConfigurationChange', lambda b: re.sub(r'case 44100:\s*', '', b))

    def initialize(body):
        start = body.index('\t//\tinitialize the box acquired property')
        end = body.index('\t//\tcalculate the host ticks per frame', start)
        return body[:start] + '\tgBox_Acquired = true;\n\tgBox_Name = CFSTR("Local TTS Mic");\n\tLSMReset();\n\n' + body[end:]
    source = function(source, 'NullAudio_Initialize', initialize)

    source = function(source, 'NullAudio_StartIO', lambda b: b.replace('gDevice_AnchorHostTime = mach_absolute_time();', '''gDevice_AnchorHostTime = mach_absolute_time();
        LSMReset();
        atomic_fetch_add_explicit(&lsmSeed, 1, memory_order_relaxed);
        atomic_store_explicit(&lsmAnchor, gDevice_AnchorHostTime, memory_order_release);'''))

    def clock(body):
        signature = body[:body.index('\n{')]
        return signature + '''
{
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!outSampleTime || !outHostTime || !outSeed) return kAudioHardwareIllegalOperationError;
    uint64_t anchor = atomic_load_explicit(&lsmAnchor, memory_order_acquire);
    uint64_t now = mach_absolute_time();
    double period = gDevice_HostTicksPerFrame * LSM_RING_FRAMES;
    uint64_t cycle = now > anchor && period > 0 ? (uint64_t)((now - anchor) / period) : 0;
    *outSampleTime = (Float64)cycle * LSM_RING_FRAMES;
    *outHostTime = anchor + (uint64_t)((Float64)cycle * period);
    *outSeed = atomic_load_explicit(&lsmSeed, memory_order_acquire);
    return noErr;
}'''
    source = function(source, 'NullAudio_GetZeroTimeStamp', clock)

    def io(body):
        signature = body[:body.index('\n{')]
        return signature + '''
{
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!ioMainBuffer || !inIOCycleInfo || inIOBufferFrameSize > LSM_RING_FRAMES) return kAudioHardwareIllegalOperationError;
    bool reading = inOperationID == kAudioServerPlugInIOOperationReadInput;
    bool writing = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (!reading && !writing) return kAudioHardwareUnsupportedOperationError;
    if (inStreamObjectID != (reading ? kObjectID_Stream_Input : kObjectID_Stream_Output)) return kAudioHardwareBadObjectError;
    double time = reading ? inIOCycleInfo->mInputTime.mSampleTime : inIOCycleInfo->mOutputTime.mSampleTime;
    if (!isfinite(time) || time > 0x1p53) {
        if (reading) memset(ioMainBuffer, 0, inIOBufferFrameSize * 8);
        return kAudioHardwareIllegalOperationError;
    }
    if (time < 0) {
        if (reading) memset(ioMainBuffer, 0, inIOBufferFrameSize * 8);
        return noErr;
    }
    if (reading) LSMRead((uint64_t)time, inIOBufferFrameSize, ioMainBuffer);
    else LSMWrite((uint64_t)time, inIOBufferFrameSize, ioMainBuffer);
    return noErr;
}'''
    source = function(source, 'NullAudio_DoIOOperation', io)
    # Make generated symbols and resource lookups specific to this driver.
    source = source.replace('NullAudio', 'LocalSpeakMic')
    source = re.sub(r'^void\*\s+LocalSpeakMic_Create', '__attribute__((visibility("default"))) void* LocalSpeakMic_Create', source, flags=re.M)
    target = HERE / 'generated/LocalSpeakMic.c'
    target.parent.mkdir(exist_ok=True)
    target.write_text('// Generated by driver/generate.py from Apple MIT sample.\n' + source)
    print(target)


if __name__ == '__main__':
    main()
