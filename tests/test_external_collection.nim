import balls
import json
import os
import sequtils
import options
import strutils
import tables

import nimhyperframe

var testcase_paths: seq[string] = toSeq walkPattern(absolutePath("http2-frame-test-case", currentSourcePath.parentDir) / "**" / "**.json")

proc decode_frame(data: seq[byte]) : (Frame, int) =
    var (f, length) = parse_from_header(data[0..<min(9, high(data)+1)])
    f.parse_body(data[min(9, high(data)+1)..<min(9+length, high(data)+1)])
    return (f, length)

proc check_valid_frame(tc: JsonNode, data: seq[byte]) =
    var (frame, length) = decode_frame(data)

    checkpoint frame

    check(tc["frame"]{"length"}.getInt == length)
    check(tc["frame"]["stream_identifier"].getInt.uint32 == frame.stream_id)
    check(FrameType(tc["frame"]["type"].getInt.int8) == frame.typ.get)
    var flags: uint8 = 0
    for flag, flag_bit in frame.defined_flags.items:
        if flag in frame.flags:
            flags = flags or flag_bit
    check(tc["frame"]["flags"].getInt.uint8 == flags)

    let p = tc["frame"]["frame_payload"]
    if "header_block_fragment" in p:
        case frame.typ.get
        of HeadersFrameType: check cast[seq[byte]](p["header_block_fragment"].getStr) == HeadersFrame(frame).data
        of DataFrameType: check(cast[seq[byte]](p["header_block_fragment"].getStr) == DataFrame(frame).data)
        of ContinuationFrameType: check cast[seq[byte]](p["header_block_fragment"].getStr) == ContinuationFrame(frame).data
        of PushPromiseFrameType: check cast[seq[byte]](p["header_block_fragment"].getStr) == PushPromiseFrame(frame).data
        else: check(false, "invalid frame type")
    if "data" in p:
        case frame.typ.get
        of HeadersFrameType: check cast[seq[byte]](p["data"].getStr) == HeadersFrame(frame).data
        of DataFrameType: check(cast[seq[byte]](p["data"].getStr) == DataFrame(frame).data)
        of PushPromiseFrameType: check cast[seq[byte]](p["data"].getStr) == PushPromiseFrame(frame).data
        of ContinuationFrameType: check cast[seq[byte]](p["data"].getStr) == ContinuationFrame(frame).data
        else: check(false, "invalid frame type")
    if "padding" in p:
        # the padding data itself is not retained by hyperframe after parsing
        discard
    if "padding_length" in p and p["padding_length"].kind != JNull:
        case frame.typ.get
        of HeadersFrameType: check p["padding_length"].getInt.uint32 == HeadersFrame(frame).pad_length
        of DataFrameType: check p["padding_length"].getInt.uint32 == DataFrame(frame).pad_length
        of PushPromiseFrameType: check p["padding_length"].getInt.uint32 == PushPromiseFrame(frame).pad_length
        else: check(false, "invalid frame type")
    if "error_code" in p:
        case frame.typ.get
        of RstStreamFrameType: check p["error_code"].getInt.uint32 == RstStreamFrame(frame).error_code
        of GoAwayFrameType: check p["error_code"].getInt.uint32 == GoAwayFrame(frame).error_code
        else: check(false, "invalid frame type")
    if "additional_debug_data" in p:
        check cast[seq[byte]](p["additional_debug_data"].getStr) == GoAwayFrame(frame).additional_data
    if "last_stream_id" in p:
        check p["last_stream_id"].getInt.uint32 == GoAwayFrame(frame).last_stream_id
    if "stream_dependency" in p:
        case frame.typ.get:
        of PriorityFrameType: check(p["stream_dependency"].getInt.uint32 == PriorityFrame(frame).depends_on)
        of HeadersFrameType: check(p["stream_dependency"].getInt.uint32 == HeadersFrame(frame).depends_on)
        else: check(false, "invalid frame type")
    if "weight" in p:
        case frame.typ.get:
        of PriorityFrameType: check(p["weight"].getInt.uint8 == PriorityFrame(frame).stream_weight)
        of HeadersFrameType: check(p["weight"].getInt.uint8 == HeadersFrame(frame).stream_weight)
        else: check(false, "invalid frame type")
    if "exclusive" in p:
        case frame.typ.get:
        of PriorityFrameType: check(p["exclusive"].getBool == PriorityFrame(frame).exclusive)
        of HeadersFrameType: check(p["exclusive"].getBool == HeadersFrame(frame).exclusive)
        else: check(false, "invalid frame type")
    if "opaque_data" in p:
        check cast[seq[byte]](p["opaque_data"].getStr) == PingFrame(frame).opaque_data
    if "promised_stream_id" in p:
        check p["promised_stream_id"].getInt.uint32 == PushPromiseFrame(frame).promised_stream_id
    if "settings" in p:
        check(p["settings"].getElems.len == SettingsFrame(frame).settings.len)
        for entry in p["settings"].getElems:
            check(Settings(entry[0].getInt.uint16) in SettingsFrame(frame).settings)
            check(entry[1].getInt.uint32 == SettingsFrame(frame).settings[Settings(entry[0].getInt.uint16)])
    if "window_size_increment" in p:
        check p["window_size_increment"].getInt.uint32 == WindowUpdateFrame(frame).window_increment

suite "External collection test suite":
    test "Walk paths":
        for path in testcase_paths:
            checkpoint path
            let t = parseFile path
            let data = cast[seq[byte]](t{"wire"}.getStr.parseHexStr)
            if t{"error"}.kind == JNull and t{"frame"}.kind != JNull:
                check_valid_frame(t, data)
            elif t{"error"}.kind != JNull and t{"frame"}.kind == JNull:
                try:
                    var (f, length) = parse_from_header(data[0..<min(9, high(data)+1)], true)
                    f.parse_body(data[min(9, high(data)+1)..<min(9+length, high(data)+1)])
                    check(length == f.body_len)
                    doAssert(false)
                except AssertionDefect:
                    fail("")
                except:
                    check(true)
            # else: fail("unexpected json")

