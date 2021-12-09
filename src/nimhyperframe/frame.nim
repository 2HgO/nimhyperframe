from math import `^`
from options import Option, get, none, some
from struct import pack, unpack, getInt

from defects import InvalidDataDefect, InvalidFrameDefect, newUnknownFrameDefect
from flags import Flag, Flags, add, newFlags, `$`

const
    FRAME_MAX_LENGTH* = 2^14
    FRAME_MAX_ALLOWED_LEN* = FRAME_MAX_LENGTH - 1
    STREAM_ASSOC_HAS_STREAM = "has-stream"
    STREAM_ASSOC_NO_STREAM = "no-stream"
    STREAM_ASSOC_EITHER = "either"

const
    STRUCT_HBBBL: string = ">HBBBL"
    STRUCT_LL: string = ">LL"
    STRUCT_HL: string = ">HL"
    STRUCT_LB: string = ">LB"
    STRUCT_L: string = ">L"
    STRUCT_H: string = ">H"
    STRUCT_B: string = ">B"

type
    FrameType* = enum
        DataFrameType=0x0
        HeadersFrameType=0x1
    Frame* = ref FrameObj
    FrameObj = object of RootObj
        stream_id: int32
        flags: Flags
        defined_flags: seq[Flag]
        typ: Option[FrameType]
        stream_association: Option[string]
        body_len : int64
        name : string

proc newFrame*(stream_id: int32; flags: seq[string] = @[]) : Frame =
    result = Frame(defined_flags: @[], typ: none(FrameType), stream_association: none(string), name: "Frame")
    result.stream_id = stream_id
    result.flags = newFlags(result.defined_flags)
    result.body_len = 0
    for flag in flags:
        result.flags.add(flag)
    if (result.stream_id == 0) and (STREAM_ASSOC_HAS_STREAM == result.stream_association.get("")):
        raise InvalidDataDefect(msg: "Stream ID must be non-zero for " & "")
    if (result.stream_id != 0) and (STREAM_ASSOC_NO_STREAM == result.stream_association.get("")):
        raise InvalidDataDefect(msg: "Stream ID must be zero for " & "" & " with stream_id=" & $result.stream_id)

method parse_body*(f: Frame, data: openArray[byte]) {.base.} = raise newException(NilAccessDefect, "parser not implemented for frame: " & $typeof(f))

method body_repr(f: Frame) : string {.base.} = discard

method `$`*(f: Frame) : string {.base.} =
    result = f.name & "(stream_id=" & $f.stream_id & ", flags=" & $f.flags & "): " & f.body_repr

method parse_flags(f: Frame, flag_byte: int) : Flags {.base, discardable.} =
    for (flag, flag_bit) in f.defined_flags.items:
        if (flag_byte and flag_bit) != 0:
            f.flags.add(flag)
    
    return f.flags

proc parse_from_header*(header: openArray[byte]; strict: bool = false) : tuple[frame: Frame, length: int] =
    let fields = try:
        STRUCT_HBBBL.unpack(cast[string](header))
    except ValueError:
        raise InvalidFrameDefect(msg: "Invalid frame header")
    let length = (fields[0].getInt shl 8) + fields[1].getInt
    let typ = fields[2].getInt
    let flags = fields[3].getInt
    let stream_id = fields[4].getInt and 0x7FFFFFFF
    let frame = case FrameType(typ)
        of HeadersFrameType: newFrame(stream_id)
        else:
            if strict:
                raise newUnknownFrameDefect(typ.int8, length.int8)
            newFrame(stream_id)
    frame.parse_flags(flags)
    return (frame: frame, length: length.int)

proc explain*(data: openArray[byte]) : tuple[frame: Frame, length: int] =
    var (frame, length) = parse_from_header(data[0..9])
    frame.parse_body(data[9..^1])
    echo frame
    return (frame: frame, length: length)

