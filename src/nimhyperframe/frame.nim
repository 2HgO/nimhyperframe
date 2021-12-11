from math import `^`
from options import Option, get, none, some
import struct
import unidecode
import tables
from strutils import toHex

from errors import ImplementationError, InvalidDataError, InvalidFrameError, InvalidPaddingError, newUnknownFrameError
from flags import Flag, Flags, add, newFlags, `$`, `in`

const
    FRAME_MAX_LENGTH* = 2^14
    FRAME_MAX_ALLOWED_LEN* = FRAME_MAX_LENGTH - 1
    STREAM_ASSOC_HAS_STREAM = "has-stream"
    STREAM_ASSOC_NO_STREAM = "no-stream"
    STREAM_ASSOC_EITHER = "either"

const
    STRUCT_HBBBL: string = ">HbbbI"
    STRUCT_LL{.used.}: string = ">II"
    STRUCT_HL: string = ">HI"
    STRUCT_LB: string = ">Ib"
    STRUCT_L: string = ">I"
    STRUCT_H{.used.}: string = ">H"
    STRUCT_B: string = ">b"

type
    FrameType* = enum
        DataFrameType=0x00'u8
        HeadersFrameType=0x01'u8
        PriorityFrameType=0x02'u8
        RstStreamFrameType=0x03'u8
        SettingsFrameType=0x04'u8
        PushPromiseFrameType=0x05'u8
        PingFrameType=0x06'u8
    Settings* = enum
        HEADER_TABLE_SIZE = 0x01'u16 ## The byte that signals the SETTINGS_HEADER_TABLE_SIZE setting.
        ENABLE_PUSH = 0x02'u16 ## The byte that signals the SETTINGS_ENABLE_PUSH setting.
        MAX_CONCURRENT_STREAMS = 0x03'u16 ## The byte that signals the SETTINGS_MAX_CONCURRENT_STREAMS setting.
        INITIAL_WINDOW_SIZE = 0x04'u16 ## The byte that signals the SETTINGS_INITIAL_WINDOW_SIZE setting.
        MAX_FRAME_SIZE = 0x05'u16 ## The byte that signals the SETTINGS_MAX_FRAME_SIZE setting.
        MAX_HEADER_LIST_SIZE = 0x06'u16 ## The byte that signals the SETTINGS_MAX_HEADER_LIST_SIZE setting.
        ENABLE_CONNECT_PROTOCOL = 0x08'u16 ## The byte that signals SETTINGS_ENABLE_CONNECT_PROTOCOL setting.
    Frame* = ref FrameObj
    FrameObj = object of RootObj
        stream_id: uint32
        flags: Flags
        defined_flags: seq[Flag]
        typ: Option[FrameType]
        stream_association: Option[string]
        body_len: int64
        name: string

proc `$`*(s: Settings) : string {.inline.} = $s.uint16

proc newDataFrame*(stream_id: uint32; data: seq[byte] = @[], pad_length: uint32 = 0; flags: seq[string] = @[]) : Frame
proc newSettingsFrame*(stream_id: uint32 = 0; settings: OrderedTable[Settings, uint32] = initOrderedTable[Settings, uint32](); flags: seq[string] = @[]) : Frame
proc newPushPromiseFrame*(stream_id: uint32; promised_stream_id: uint32 = 0; data: seq[byte] = @[], pad_length: uint32 = 0; flags: seq[string] = @[]) : Frame
proc newPriorityFrame*(stream_id: uint32; depends_on: uint32 = 0, stream_weight: uint8 = 0, exclusive: bool = false; flags: seq[string] = @[]) : Frame
proc newRstStreamFrame*(stream_id: uint32; error_code: uint32 = 0; flags: seq[string] = @[]) : Frame
proc newPingFrame*(stream_id: uint32; opaque_data: seq[byte] = @[], flags: seq[string] = @[]) : Frame
proc newExtensionFrame*(frame_type: uint8; stream_id: uint32; flag_byte: uint8 = 0; body: seq[byte] = @[]; flags: seq[string] = @[]) : Frame

proc newSetting(f: int) : Settings {.inline.} =
    case f.uint8
    of 0x01..0x06, 0x08: result = Settings(f)
    else: raise newException(ValueError, "Invalid enum value.")

proc raw_data_repr(data: seq[byte]) : string =
    if data.len == 0:
        return "nil"
    result = cast[string](data)
    result = unidecode(result).toHex
    if result.len > 20:
        result = result[0..<20] & "..."
    result = "<hex:" & result & ">"

proc initFrame*(f: Frame, stream_id: uint32; flags: seq[string] = @[]) =
    f.name = if f.name == "": "Frame" else: f.name
    f.stream_id = stream_id
    f.flags = newFlags(f.defined_flags)
    for flag in flags:
        f.flags.add(flag)
    if (f.stream_id == 0) and (STREAM_ASSOC_HAS_STREAM == f.stream_association.get("")):
        raise newException(InvalidDataError, "Stream ID must be non-zero for " & f.name)
    if (f.stream_id != 0) and (STREAM_ASSOC_NO_STREAM == f.stream_association.get("")):
        raise newException(InvalidDataError, "Stream ID must be zero for " & f.name & " with stream_id=" & $f.stream_id)

proc stream_id*(f: Frame) : uint32 {.inline.} = f.stream_id
proc flags*(f: Frame) : Flags {.inline.} = f.flags
proc defined_flags*(f: Frame) : seq[Flag] {.inline.} = f.defined_flags
proc typ*(f: Frame) : Option[FrameType] {.inline.} = f.typ
proc stream_association*(f: Frame) : Option[string] {.inline.} = f.stream_association
proc body_len*(f: Frame) : int64 {.inline.} = f.body_len
proc name*(f: Frame) : string {.inline.} = f.name

method serialize_body*(f: Frame) : seq[byte] {.base, locks: "unknown".} = raise newException(ImplementationError, "serializer not implemented for frame: " & $typeof(f))
method parse_body*(f: Frame, data: seq[byte]) {.base, locks: "unknown".} = raise newException(ImplementationError, "parser not implemented for frame: " & $typeof(f))

method body_repr(f: Frame) : string {.base, locks: "unknown", inline.} = result = raw_data_repr(f.serialize_body())

method `$`*(f: Frame) : string {.base.} =
    result = f.name & "(stream_id=" & $f.stream_id & ", flags=" & $f.flags & "): " & f.body_repr

method parse_flags*(f: Frame, flag_byte: uint8) : Flags {.base, discardable.} =
    for (flag, flag_bit) in f.defined_flags.mitems:
        if (flag_byte and flag_bit) != 0:
            f.flags.add(flag)
    
    return f.flags

proc parse_from_header*(header: seq[byte]; strict: bool = false) : tuple[frame: Frame, length: int] =
    let fields = try:
        STRUCT_HBBBL.unpack(cast[string](header))
    except ValueError:
        raise newException(InvalidFrameError, "Invalid frame header")
    let length = ((fields[0].getUShort shl 8) + fields[1].getChar.uint16).uint32
    let typ = fields[2].getChar.uint8
    let flags = fields[3].getChar.uint8
    let stream_id = fields[4].getUInt and 0x7FFFFFFF'u32
    var frame = try:
        case FrameType(typ)
        of DataFrameType: newDataFrame(stream_id)
        of PingFrameType: newPingFrame(stream_id)
        of PriorityFrameType: newPriorityFrame(stream_id)
        of RstStreamFrameType: newRstStreamFrame(stream_id)
        of SettingsFrameType: newSettingsFrame(stream_id)
        of PushPromiseFrameType: newPushPromiseFrame(stream_id)
        else:
            if strict:
                raise newUnknownFrameError(typ, length)
            newExtensionFrame(typ, stream_id)
    except:
        if strict:
            raise newUnknownFrameError(typ, length)
        newExtensionFrame(typ, stream_id)
    frame.parse_flags(flags)
    return (frame: frame, length: length.int)

method serialize*(f: Frame) : seq[byte] {.base.} =
    let body = f.serialize_body
    f.body_len = body.len
    var flags: uint8 = 0
    for (flag, flag_bit) in f.defined_flags.items:
        if flag in f.flags:
            flags = flags or flag_bit
    var header = STRUCT_HBBBL.pack(
        ((f.body_len shr 8) and 0xFFFF).uint16,
        (f.body_len and 0xFF).char,
        f.typ.get.uint8.char,
        flags.char,
        f.stream_id and 0x7FFFFFFF
    )
    return cast[seq[byte]](header) & body

proc explain*(data: seq[byte]) : tuple[frame: Frame, length: int] =
    var (frame, length) = parse_from_header(data[0..<min(9, high(data)+1)])
    frame.parse_body(data[min(9, high(data)+1)..^1])
    echo frame
    return (frame: frame, length: length)

type
    Padding* = ref PaddingObj
    PaddingObj = object of Frame
        pad_length: uint32

method pad_length*(p: Padding) : uint32 {.base, inline.} = result = p.pad_length
method parse_padding_data*(p: Padding, data: seq[byte]) : int {.base, discardable.} =
    if "PADDED" in p.flags:
        p.pad_length = try:
            unpack("!b", cast[string](data[0..<min(1, high(data)+1)]))[0].getChar.uint8
        except ValueError:
            raise newException(InvalidFrameError, "Invalid Padding data")
        return 1
    return 0
method serialize_padding_data*(p: Padding) : seq[byte] {.base.} =
    if "PADDED" in p.flags:
        return cast[seq[byte]](STRUCT_B.pack(p.pad_length.char))
    return @[]

type
    Priority* = ref PriorityObj
    PriorityObj = object of Frame
        depends_on: uint32
        stream_weight: uint8
        exclusive: bool

proc depends_on*(p: Priority) : uint32 {.inline.} = p.depends_on
proc stream_weight*(p: Priority) : uint8 {.inline.} = p.stream_weight
proc exclusive*(p: Priority) : bool {.inline.} = p.exclusive

method serialize_priority_data*(p: Priority) : seq[byte] {.base.} = 
    return cast[seq[byte]](STRUCT_LB.pack(
        p.depends_on + (if p.exclusive: 0x80000000'u32 else: 0'u32),
        p.stream_weight.char
    ))
method parse_priority_data*(p: Priority, data: seq[byte]) : int {.base, discardable.} =
    let up = try:
        STRUCT_LB.unpack(cast[string](data[0..<min(5, high(data)+1)]))
    except ValueError:
        raise newException(InvalidFrameError, "Invalid Priority data")
    (p.depends_on, p.stream_weight) = (up[0].getUInt, up[1].getChar.uint8)
    p.exclusive = (p.depends_on shr 31) != 0
    p.depends_on = p.depends_on and 0x7FFFFFFF
    return 5

type
    DataFrame* = ref DataFrameObj
    DataFrameObj = object of Padding
        data: seq[byte]

proc newDataFrame*(stream_id: uint32; data: seq[byte] = @[], pad_length: uint32 = 0; flags: seq[string] = @[]) : Frame =
    result = new(DataFrame)
    result.typ = DataFrameType.some
    result.name = "DataFrame"
    result.defined_flags = @[
        (name: "END_STREAM", bit: 0x01.uint8),
        (name: "PADDED", bit: 0x08.uint8),
    ]
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)
    Padding(result).pad_length = pad_length
    DataFrame(result).data = data

proc flow_controlled_length*(d: DataFrame) : uint32 =
    var padding_len = 0'u32
    if "PADDED" in d.flags:
        padding_len = d.pad_length + 1'u32
    return d.data.len.uint32 + padding_len

proc data*(d: DataFrame) : seq[byte] {.inline.} = d.data

method serialize_body*(d: DataFrame) : seq[byte] =
    result.add d.serialize_padding_data
    result.add d.data
    result.add newSeq[byte](d.pad_length)
method parse_body*(d: DataFrame, data: seq[byte]) =
    let padding_data_length = d.parse_padding_data(data)

    d.data = data[padding_data_length..<min(data.len - d.pad_length.int, high(data)+1)]
    d.body_len = data.len
    if d.pad_length > 0 and d.pad_length.int64 >= d.body_len:
        raise newException(InvalidPaddingError, "Padding is too long.")

type
    PriorityFrame* = ref PriorityFrameObj
    PriorityFrameObj = object of Priority

proc newPriorityFrame*(stream_id: uint32; depends_on: uint32 =0 , stream_weight: uint8 = 0, exclusive: bool = false; flags: seq[string] = @[]) : Frame =
    result = new(PriorityFrame)
    result.typ = PriorityFrameType.some
    result.name = "PriorityFrame"
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)
    Priority(result).depends_on = depends_on
    Priority(result).stream_weight = stream_weight
    Priority(result).exclusive = exclusive

method body_repr(p: PriorityFrame) : string {.inline, locks: "unknown".} =
    return "exclusive=" & $p.exclusive & ", depends_on=" & $p.depends_on & ", stream_weight=" & $p.stream_weight
method serialize_body*(p: PriorityFrame) : seq[byte] {.inline, locks: "unknown".} =
    result = p.serialize_priority_data()
method parse_body*(p: PriorityFrame, data: seq[byte]) {.locks: "unknown".} =
    if data.len > 5:
        raise newException(InvalidFrameError, "PRIORITY must have 5 byte body: actual length " & $data.len & ".")
    p.parse_priority_data(data)
    p.body_len = 5

type
    RstStreamFrame* = ref RstStreamFrameObj
    RstStreamFrameObj = object of Frame
        error_code: uint32

proc newRstStreamFrame*(stream_id: uint32; error_code: uint32 = 0; flags: seq[string] = @[]) : Frame =
    result = new(RstStreamFrame)
    result.typ = RstStreamFrameType.some
    result.name = "RstStreamFrame"
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)

    RstStreamFrame(result).error_code = error_code

proc error_code*(r: RstStreamFrame) : uint32 {.inline.} = r.error_code

method body_repr(r: RstStreamFrame) : string {.inline, locks: "unknown".} =
    return "error_code=" & $r.error_code
method serialize_body*(r: RstStreamFrame) : seq[byte] {.inline, locks: "unknown".} =
    result = cast[seq[byte]](STRUCT_L.pack(r.error_code))
method parse_body*(r: RstStreamFrame, data: seq[byte]) {.locks: "unknown".} =
    if data.len != 4:
        raise newException(InvalidFrameError, "RST_STREAM must have 4 byte body: actual length " & $data.len & ".")
    r.error_code = try:
        STRUCT_L.unpack(cast[string](data))[0].getUInt
    except ValueError:
        raise newException(InvalidFrameError, "Invalid RST_STREAM body")
    r.body_len = 4

type
    SettingsFrame* = ref SettingsFrameObj
    SettingsFrameObj = object of Frame
        settings: OrderedTable[Settings, uint32]

proc newSettingsFrame*(stream_id: uint32 = 0; settings: OrderedTable[Settings, uint32] = initOrderedTable[Settings, uint32](); flags: seq[string] = @[]) : Frame =
    result = new(SettingsFrame)
    result.defined_flags = @[
        (name: "ACK", bit: 0x01.uint8)
    ]
    result.name = "SettingsFrame"
    result.typ = SettingsFrameType.some
    result.stream_association = STREAM_ASSOC_NO_STREAM.some
    initFrame(result, stream_id, flags)

    if settings.len > 0 and "ACK" in flags:
        raise newException(InvalidDataError, "Settings must be empty if ACK flag is set.")

    SettingsFrame(result).settings = settings

proc settings*(s: SettingsFrame) : OrderedTable[Settings, uint32] {.inline.} = s.settings

method body_repr(p: SettingsFrame) : string {.inline, locks: "unknown".} =
    return "settings=" & $p.settings
method serialize_body*(s: SettingsFrame) : seq[byte] {.locks: "unknown".} =
    result = @[]
    for setting, value in s.settings.pairs:
        result.add cast[seq[byte]](STRUCT_HL.pack(setting.uint16 and 0xFF, value))
method parse_body*(s: SettingsFrame, data: seq[byte]) =
    if "ACK" in s.flags and data.len > 0:
        raise newException(InvalidDataError, "SETTINGS ack frame must not have payload: got " & $data.len & " bytes")
    var body_len = 0
    for i in countup(0, data.len - 1, 6):
        let unpacked = try:
            STRUCT_HL.unpack(cast[string](data[i..<min(i+6, high(data)+1)]))
        except ValueError:
            echo getCurrentExceptionMsg()
            raise newException(InvalidFrameError, "Invalid SETTINGS body")
        s.settings[newSetting(unpacked[0].getShort)] = unpacked[1].getUInt
        body_len += 6
    s.body_len = body_len

type
    PushPromiseFrame* = ref PushPromiseFrameObj
    PushPromiseFrameObj = object of Padding
        data: seq[byte]
        promised_stream_id: uint32

proc newPushPromiseFrame*(stream_id: uint32; promised_stream_id: uint32 = 0; data: seq[byte] = @[], pad_length: uint32 = 0; flags: seq[string] = @[]) : Frame =
    result = new(PushPromiseFrame)
    result.typ = PushPromiseFrameType.some
    result.name = "PushPromiseFrame"
    result.defined_flags = @[
        (name: "END_HEADERS", bit: 0x04.uint8),
        (name: "PADDED", bit: 0x08.uint8),
    ]
    result.stream_association = STREAM_ASSOC_HAS_STREAM.some
    initFrame(result, stream_id, flags)
    Padding(result).pad_length = pad_length
    PushPromiseFrame(result).data = data
    PushPromiseFrame(result).promised_stream_id = promised_stream_id

proc data*(p: PushPromiseFrame) : seq[byte] {.inline.} = p.data
proc promised_stream_id*(p: PushPromiseFrame) : uint32 {.inline.} = p.promised_stream_id

method body_repr(p: PushPromiseFrame) : string {.inline, locks: "unknown".} =
    return "promised_stream_id=" & $p.promised_stream_id & ", data=" & raw_data_repr(p.data)
method serialize_body*(p: PushPromiseFrame) : seq[byte] =
    result.add p.serialize_padding_data()
    result.add cast[seq[byte]](STRUCT_L.pack(p.promised_stream_id))
    result.add p.data
    result.add newSeq[byte](p.pad_length)
method parse_body*(p: PushPromiseFrame, data: seq[byte]) =
    let padding_data_length = p.parse_padding_data(data)
    p.promised_stream_id = try:
        STRUCT_L.unpack(cast[string](data[padding_data_length..<min(padding_data_length+4, high(data)+1)]))[0].getUInt
    except ValueError:
        raise newException(InvalidFrameError, "Invalid PUSH_PROMISE body")
    p.data = data[min(padding_data_length+4, high(data)+1)..<min(data.len - p.pad_length.int, high(data)+1)]
    p.body_len = data.len
    if p.promised_stream_id == 0 or (p.promised_stream_id and 1) != 0:
        raise newException(InvalidDataError, "Invalid PUSH_PROMISE promised stream id: " & $p.promised_stream_id)
    if p.pad_length > 0 and p.pad_length.int64 >= p.body_len:
        raise newException(InvalidPaddingError, "Padding is too long.")

type
    PingFrame* = ref PingFrameObj
    PingFrameObj = object of Frame
        opaque_data: seq[byte]
proc newPingFrame*(stream_id: uint32; opaque_data: seq[byte] = @[], flags: seq[string] = @[]) : Frame =
    result = new(PingFrame)
    result.typ = PingFrameType.some
    result.name = "PingFrame"
    result.defined_flags = @[
        (name: "ACK", bit: 0x01.uint8),
    ]
    result.stream_association = STREAM_ASSOC_NO_STREAM.some
    initFrame(result, stream_id, flags)
    PingFrame(result).opaque_data = opaque_data

proc opaque_data*(p: PingFrame) : seq[byte] {.inline.} = p.opaque_data

method body_repr(p: PingFrame) : string {.inline, locks: "unknown".} =
    return "opaque_data=" & cast[string](p.opaque_data)
method serialize_body*(p: PingFrame) : seq[byte] {.locks: "unknown".} =
    if p.opaque_data.len > 8: raise newException(InvalidFrameError, "PING frame may not have more than 8 bytes of data, got "&cast[string](p.opaque_data))
    result = p.opaque_data
    for _ in 0..<8-p.opaque_data.len: result.add('\x00'.byte)
method parse_body*(p: PingFrame, data: seq[byte]) {.locks: "unknown".} =
    if data.len != 8:
        raise newException(InvalidFrameError, "PING frame must have 8 byte length: got " & cast[string](data))
    p.opaque_data = data
    p.body_len = 8

type
    ExtensionFrame* = ref ExtensionFrameObj
    ExtensionFrameObj = object of Frame
        frame_type: uint8
        flag_byte: uint8
        body: seq[byte]

proc newExtensionFrame*(frame_type: uint8; stream_id: uint32; flag_byte: uint8 = 0; body: seq[byte] = @[]; flags: seq[string] = @[]) : Frame =
    result = new(ExtensionFrame)
    result.stream_association = STREAM_ASSOC_EITHER.some
    result.name = "ExtensionFrame"
    initFrame(result, stream_id, flags)
    ExtensionFrame(result).frame_type = frame_type
    ExtensionFrame(result).flag_byte = flag_byte
    ExtensionFrame(result).body = body

proc frame_type*(e: ExtensionFrame) : uint8 {.inline.} = e.frame_type
proc flag_byte*(e: ExtensionFrame) : uint8 {.inline.} = e.flag_byte
proc body*(e: ExtensionFrame) : seq[byte] {.inline.} = e.body

method body_repr(e: ExtensionFrame) : string {.inline, locks: "unknown".} =
    result = "type=" & $e.frame_type & ", flag_byte=" & $e.flag_byte & ", body=" & raw_data_repr(e.body)

method parse_body*(e: ExtensionFrame, data: seq[byte]) {.locks: "unknown".} =
    e.body = data
    e.body_len = data.len

method parse_flags*(e: ExtensionFrame, flag_byte: uint8) : Flags {.discardable, locks: "unknown".} =
    e.flag_byte = flag_byte
    return result

method serialize*(e: ExtensionFrame) : seq[byte] {.locks: "unknown".} =
    let flags = e.flag_byte
    let header = STRUCT_HBBBL.pack(
        ((e.body_len shr 8) and 0xFFFF).uint16,
        (e.body_len and 0xFF).uint8.char,
        e.frame_type.char,
        flags.char,
        e.stream_id and 0x7FFFFFFF
    )

    result.add cast[seq[byte]](header)
    result.add e.body
