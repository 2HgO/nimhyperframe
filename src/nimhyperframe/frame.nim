from math import `^`
from options import Option, get, none, some
import struct
from unidecode import unidecode
import tables

from errors import ImplementationError, InvalidDataError, InvalidFrameError, InvalidPaddingError, newUnknownFrameError
from flags import Flag, Flags, add, newFlags, `$`, `in`

const
    FRAME_MAX_LENGTH* = 2^14
    FRAME_MAX_ALLOWED_LEN* = FRAME_MAX_LENGTH - 1
    STREAM_ASSOC_HAS_STREAM = "has-stream"
    STREAM_ASSOC_NO_STREAM = "no-stream"
    STREAM_ASSOC_EITHER {.used.} = "either"

const
    STRUCT_HBBBL: string = ">HbbbI"
    STRUCT_LL{.used.}: string = ">II"
    STRUCT_HL{.used.}: string = ">HI"
    STRUCT_LB{.used.}: string = ">Ib"
    STRUCT_L{.used.}: string = ">I"
    STRUCT_H{.used.}: string = ">H"
    STRUCT_B{.used.}: string = ">b"

type
    FrameType* = enum
        DataFrameType=0x00
        HeadersFrameType=0x01
        PriorityFrameType=0x02
        RstStreamFrameType=0x03
        SettingsFrameType=0x04
        PushPromiseFrameType=0x05
        PingFrameType=0x06
    Settings* = enum
        HEADER_TABLE_SIZE = 0x01'u8 ## The byte that signals the SETTINGS_HEADER_TABLE_SIZE setting.
        ENABLE_PUSH = 0x02'u8 ## The byte that signals the SETTINGS_ENABLE_PUSH setting.
        MAX_CONCURRENT_STREAMS = 0x03'u8 ## The byte that signals the SETTINGS_MAX_CONCURRENT_STREAMS setting.
        INITIAL_WINDOW_SIZE = 0x04'u8 ## The byte that signals the SETTINGS_INITIAL_WINDOW_SIZE setting.
        MAX_FRAME_SIZE = 0x05'u8 ## The byte that signals the SETTINGS_MAX_FRAME_SIZE setting.
        MAX_HEADER_LIST_SIZE = 0x06'u8 ## The byte that signals the SETTINGS_MAX_HEADER_LIST_SIZE setting.
        ENABLE_CONNECT_PROTOCOL = 0x08'u8 ## The byte that signals SETTINGS_ENABLE_CONNECT_PROTOCOL setting.
    Frame* = ref FrameObj
    FrameObj = object of RootObj
        stream_id: int32
        flags: Flags
        defined_flags: seq[Flag]
        typ: Option[FrameType]
        stream_association: Option[string]
        body_len : int64
        name : string

proc newDataFrame*(stream_id: int32; data: seq[byte] = @[], pad_length: int = 0; flags: seq[string] = @[]) : Frame
proc newSettingsFrame*(stream_id: int32; settings: TableRef[Settings, int] = newTable[Settings, int](); flags: seq[string] = @[]) : Frame
proc newPushPromiseFrame*(stream_id: int32; promised_stream_id: int32 = 0; data: seq[byte] = @[], pad_length: int = 0; flags: seq[string] = @[]) : Frame
proc newPriorityFrame*(stream_id: int32; depends_on: int = 0, stream_weight: int = 0, exclusive: bool = false; flags: seq[string] = @[]) : Frame
proc newRstStreamFrame*(stream_id: int32; error_code: int = 0; flags: seq[string] = @[]) : Frame
proc newPingFrame*(stream_id: int32; opaque_data: seq[byte] = @[], flags: seq[string] = @[]) : Frame

proc newSetting(f: int) : Settings {.inline.} =
    case f.uint8
    of 0x01..0x06, 0x08: result = Settings(f)
    else: raise newException(ValueError, "Invalid enum value.")

proc raw_data_repr(data: seq[byte]) : string =
    if data.len == 0:
        return "None"
    result = cast[string](data)
    result = unidecode(result)
    if result.len > 20:
        result = result[0..<20] & "..."

proc initFrame*(f: Frame, stream_id: int32; flags: seq[string] = @[]) =
    f.name = if f.name == "": "Frame" else: f.name
    f.stream_id = stream_id
    f.flags = newFlags(f.defined_flags)
    for flag in flags:
        f.flags.add(flag)
    if (f.stream_id == 0) and (STREAM_ASSOC_HAS_STREAM == f.stream_association.get("")):
        raise InvalidDataError(msg: "Stream ID must be non-zero for " & "")
    if (f.stream_id != 0) and (STREAM_ASSOC_NO_STREAM == f.stream_association.get("")):
        raise InvalidDataError(msg: "Stream ID must be zero for " & "" & " with stream_id=" & $f.stream_id)

method serialize_body*(f: Frame) : seq[byte] {.base.} = raise ImplementationError(msg: "serializer not implemented for frame: " & $typeof(f))
method parse_body*(f: Frame, data: seq[byte]) {.base.} = raise ImplementationError(msg: "parser not implemented for frame: " & $typeof(f))

method body_repr(f: Frame) : string {.base, inline.} = result = raw_data_repr(f.serialize_body())

method `$`*(f: Frame) : string {.base.} =
    result = f.name & "(stream_id=" & $f.stream_id & ", flags=" & $f.flags & "): " & f.body_repr

method parse_flags(f: var Frame, flag_byte: int) : Flags {.base, discardable.} =
    for (flag, flag_bit) in f.defined_flags.items:
        if (flag_byte and flag_bit) != 0:
            f.flags.add(flag)
    
    return f.flags

proc parse_from_header*(header: seq[byte]; strict: bool = false) : tuple[frame: Frame, length: int] =
    let fields = try:
        STRUCT_HBBBL.unpack(cast[string](header))
    except ValueError:
        raise InvalidFrameError(msg: "Invalid frame header")
    let length = ((fields[0].getUShort shl 8) + fields[1].getChar.uint16).int32
    let typ = fields[2].getChar
    let flags = fields[3].getChar.int32
    let stream_id = (fields[4].getUInt and 0x7FFFFFFF).int32
    var frame = case FrameType(typ)
    of DataFrameType: newDataFrame(stream_id)
    of PingFrameType: newPingFrame(stream_id)
    of PriorityFrameType: newPriorityFrame(stream_id)
    of RstStreamFrameType: newRstStreamFrame(stream_id)
    of SettingsFrameType: newSettingsFrame(stream_id)
    of PushPromiseFrameType: newDataFrame(stream_id)
    else:
        if strict:
            raise newUnknownFrameError(typ.int8, length.int8)
        Frame()
    frame.parse_flags(flags)
    return (frame: frame, length: length.int)

method serialize*(f: var Frame) : seq[byte] {.base.} =
    let body = f.serialize_body
    f.body_len = body.len
    var flags: int8 = 0
    for (flag, flag_bit) in f.defined_flags.items:
        if flag in f.flags:
            flags = flags or flag_bit
    var header = STRUCT_HBBBL.pack(
        (f.body_len shr 8) and 0xFFFF,
        f.body_len and 0xFF,
        f.typ.get.int,
        flags,
        f.stream_id and 0x7FFFFFFF
    )
    return cast[seq[byte]](header) & body

proc explain*(data: seq[byte]) : tuple[frame: Frame, length: int] =
    var (frame, length) = parse_from_header(data[0..<9])
    frame.parse_body(data[9..^1])
    echo frame
    return (frame: frame, length: length)

type
    Padding* = ref PaddingObj
    PaddingObj = object of Frame
        pad_length: int

method pad_length*(p: Padding) : int {.base, inline.} = result = p.pad_length
method parse_padding_data*(p: Padding, data: seq[byte]) : int {.base, discardable.} =
    if "PADDED" in p.flags:
        p.pad_length = try:
            unpack("!b", cast[string](data[0..<1]))[0].getInt
        except ValueError:
            raise InvalidFrameError(msg: "Invalid Padding data")
        return 1
    return 0
method serialize_padding_data*(p: Padding) : seq[byte] {.base.} =
    if "PADDED" in p.flags:
        return cast[seq[byte]](STRUCT_B.pack(p.pad_length))
    return @[]

type
    Priority* = ref PriorityObj
    PriorityObj = object of Frame
        depends_on: int
        stream_weight: int
        exclusive: bool

method serialize_priority_data*(p: Priority) : seq[byte] {.base.} = 
    return cast[seq[byte]](STRUCT_LB.pack(
        p.depends_on + (if p.exclusive: 0x80000000 else: 0),
        p.stream_weight
    ))
method parse_priority_data*(p: Priority, data: seq[byte]) : int {.base, discardable.} =
    let up = try:
        STRUCT_LB.unpack(cast[string](data[0..<5]))
    except ValueError:
        raise InvalidFrameError(msg: "Invalid Priority data")
    (p.depends_on, p.stream_weight) = (up[0].getInt, up[1].getInt)
    p.exclusive = (p.depends_on shr 31) != 0
    p.depends_on = p.depends_on and 0x7FFFFFFF
    return 5

type
    DataFrame* = ref DataFrameObj
    DataFrameObj = object of Padding
        data: seq[byte]

proc newDataFrame*(stream_id: int32; data: seq[byte] = @[], pad_length: int = 0; flags: seq[string] = @[]) : Frame =
    result = new(DataFrame)
    result.typ = DataFrameType.some
    result.name = "DataFrame"
    result.defined_flags = @[
        (name: "END_STREAM", bit: 0x01.int8),
        (name: "PADDED", bit: 0x08.int8),
    ]
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)
    Padding(result).pad_length = pad_length
    DataFrame(result).data = data

proc flow_controlled_length*(d: DataFrame) : int =
    var padding_len = 0
    if "PADDED" in d.flags:
        padding_len = d.pad_length + 1
    return d.data.len + padding_len

method serialize_body*(d: DataFrame) : seq[byte] =
    result = d.serialize_padding_data() & d.data & newSeq[byte](d.pad_length)
method parse_body*(d: DataFrame, data: seq[byte]) =
    let padding_data_length = d.parse_padding_data(data)
    d.data = data[padding_data_length..^d.pad_length]
    d.body_len = data.len
    if d.pad_length > 0 and d.pad_length >= d.body_len:
        raise InvalidPaddingError(msg: "Padding is too long.")

type
    PriorityFrame* = ref PriorityFrameObj
    PriorityFrameObj = object of Priority

proc newPriorityFrame*(stream_id: int32; depends_on: int =0 , stream_weight: int = 0, exclusive: bool = false; flags: seq[string] = @[]) : Frame =
    result = new(PriorityFrame)
    result.typ = PriorityFrameType.some
    result.name = "PriorityFrame"
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)
    Priority(result).depends_on = depends_on
    Priority(result).stream_weight = stream_weight
    Priority(result).exclusive = exclusive

method body_repr(p: PriorityFrame) : string {.inline.} =
    return "exclusive=" & $p.exclusive & ", depends_on=" & $p.depends_on & ", stream_weight=" & $p.stream_weight
method serialize_body*(p: PriorityFrame) : seq[byte] {.inline.} =
    result = p.serialize_priority_data()
method parse_body*(p: PriorityFrame, data: seq[byte]) =
    if data.len > 5:
        raise InvalidFrameError(msg: "PRIORITY must have 5 byte body: actual length " & $data.len & ".")
    p.parse_priority_data(data)
    p.body_len = 5

type
    RstStreamFrame* = ref RstStreamFrameObj
    RstStreamFrameObj = object of Frame
        error_code: int

proc newRstStreamFrame*(stream_id: int32; error_code: int = 0; flags: seq[string] = @[]) : Frame =
    result = new(RstStreamFrame)
    result.typ = RstStreamFrameType.some
    result.name = "RstStreamFrame"
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)

    RstStreamFrame(result).error_code = error_code

method body_repr(r: RstStreamFrame) : string {.inline.} =
    return "error_code=" & $r.error_code
method serialize_body*(r: RstStreamFrame) : seq[byte] {.inline.} =
    result = cast[seq[byte]](STRUCT_L.pack(r.error_code))
method parse_body*(r: RstStreamFrame, data: seq[byte]) =
    if data.len != 5:
        raise InvalidFrameError(msg: "RST_STREAM must have 4 byte body: actual length " & $data.len & ".")
    r.error_code = try:
        STRUCT_L.unpack(cast[string](data))[0].getInt
    except ValueError:
        raise InvalidFrameError(msg: "Invalid RST_STREAM body")
    r.body_len = 4

type
    SettingsFrame* = ref SettingsFrameObj
    SettingsFrameObj = object of Frame
        settings: TableRef[Settings, int]

proc newSettingsFrame*(stream_id: int32; settings: TableRef[Settings, int] = newTable[Settings, int](); flags: seq[string] = @[]) : Frame =
    result = new(SettingsFrame)
    result.defined_flags = @[
        (name: "ACK", bit: 0x01.int8)
    ]
    result.name = "SettingsFrame"
    result.typ = SettingsFrameType.some
    result.stream_association = STREAM_ASSOC_NO_STREAM.some
    initFrame(result, stream_id, flags)

    if settings.len > 0 and "ACK" in flags:
        raise InvalidDataError(msg: "")

    SettingsFrame(result).settings = settings

method body_repr(p: SettingsFrame) : string {.inline.} =
    return "settings=" & $p.settings
method serialize_body*(s: SettingsFrame) : seq[byte] =
    result = @[]
    for setting, value in s.settings.pairs:
        result &= cast[seq[byte]](STRUCT_HL.pack(setting.uint8 and 0xFF, value))
method parse_body*(s: SettingsFrame, data: seq[byte]) =
    if "ACK" in s.flags and data.len > 0:
        raise InvalidDataError(msg: "")
    var body_len = 0
    for i in countup(0, data.len, 6):
        let unpacked = try:
            STRUCT_HL.unpack(cast[string](data[i..<i+6]))
        except ValueError:
            raise InvalidFrameError(msg: "")
        s.settings[newSetting(unpacked[0].getInt)] = unpacked[1].getInt
        body_len += 6
    s.body_len = body_len

type
    PushPromiseFrame* = ref PushPromiseFrameObj
    PushPromiseFrameObj = object of Padding
        data: seq[byte]
        promised_stream_id: int

proc newPushPromiseFrame*(stream_id: int32; promised_stream_id: int32 = 0; data: seq[byte] = @[], pad_length: int = 0; flags: seq[string] = @[]) : Frame =
    result = new(PushPromiseFrame)
    result.typ = PushPromiseFrameType.some
    result.name = "PushPromiseFrame"
    result.defined_flags = @[
        (name: "END_HEADERS", bit: 0x04.int8),
        (name: "PADDED", bit: 0x08.int8),
    ]
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id)
    Padding(result).pad_length = pad_length
    PushPromiseFrame(result).data = data
    PushPromiseFrame(result).promised_stream_id = promised_stream_id

method body_repr(p: PushPromiseFrame) : string {.inline.} =
    return "promised_stream_id=" & $p.promised_stream_id & ", data=" & raw_data_repr(p.data)
method serialize_body*(p: PushPromiseFrame) : seq[byte] =
    result = p.serialize_padding_data() & cast[seq[byte]](STRUCT_L.pack(p.promised_stream_id)) & p.data & newSeq[byte](p.pad_length)
method parse_body*(p: PushPromiseFrame, data: seq[byte]) =
    let padding_data_length = p.parse_padding_data(data)
    p.promised_stream_id = try:
        STRUCT_L.unpack(cast[string](data[padding_data_length..<padding_data_length+4]))[0].getInt
    except ValueError:
        raise InvalidFrameError(msg: "Invalid PUSH_PROMISE body")
    p.data = data[padding_data_length..^p.pad_length]
    p.body_len = data.len
    if p.promised_stream_id == 0 and (p.promised_stream_id and 1) != 0:
        raise InvalidDataError(msg: "Invalid PUSH_PROMISE promised stream id: " & $p.promised_stream_id)
    if p.pad_length > 0 and p.pad_length >= p.body_len:
        raise InvalidPaddingError(msg: "Padding is too long.")

type
    PingFrame* = ref PingFrameObj
    PingFrameObj = object of Frame
        opaque_data: seq[byte]
proc newPingFrame*(stream_id: int32; opaque_data: seq[byte] = @[], flags: seq[string] = @[]) : Frame =
    result = new(PingFrame)
    result.typ = PingFrameType.some
    result.name = "PingFrame"
    result.defined_flags = @[
        (name: "ACK", bit: 0x01.int8),
    ]
    result.stream_association = STREAM_ASSOC_NO_STREAM.some
    initFrame(result, stream_id)
    PingFrame(result).opaque_data = opaque_data

method body_repr(p: PingFrame) : string {.inline.} =
    return "opaque_data=" & cast[string](p.opaque_data)
method serialize_body*(p: PingFrame) : seq[byte] =
    if p.opaque_data.len > 8: raise InvalidFrameError(msg: "PING frame may not have more than 8 bytes of data, got "&cast[string](p.opaque_data))
    result = deepCopy(p.opaque_data)
    for _ in 0..<8-p.opaque_data.len: result.add('\x00'.byte)
method parse_body*(p: PingFrame, data: seq[byte]) =
    if data.len != 8:
        raise InvalidFrameError(msg: "PING frame must have 8 byte length: got " & cast[string](data))
    p.opaque_data = data
    p.body_len = 8
