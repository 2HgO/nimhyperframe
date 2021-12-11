import balls
import options
import sequtils
import strutils
import tables

import nimhyperframe

proc decode_frame(data: seq[byte]) : Frame =
    var (f, length) = parse_from_header(data[0..<min(9, high(data)+1)])
    f.parse_body(data[min(9, high(data)+1)..<min(9+length, high(data)+1)])
    doAssert 9+length == data.len
    return f

suite "General frame behaviour test suite":
    test "Base frame ignores flags":
        var f = new(Frame)
        initFrame(f, 0)
        checkpoint $f[]
        var flags = f.parse_flags(0xFF.uint8)
        checkpoint flags
        check(flags.len == 0)
    test "Base frame cannot serialize":
        var f = new(Frame)
        initFrame(f, 0)
        expect ImplementationError:
            discard f.serialize()
    test "Base frame cannot parse body":
        var f = new(Frame)
        initFrame(f, 0)
        expect ImplementationError:
            f.parse_body(newSeqOfCap[byte](0))
    test "Parse frame header unknown type strict":
        expect UnknownFrameError:
            discard parse_from_header(@['\x00'.byte, '\x00'.byte, '\x59'.byte, '\xFF'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x01'.byte], true)
        try: discard parse_from_header(@['\x00'.byte, '\x00'.byte, '\x59'.byte, '\xFF'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x01'.byte], true)
        except UnknownFrameError:
            check((ref UnknownFrameError)(getCurrentException()).frame_type == 0xFF'u8)
            check((ref UnknownFrameError)(getCurrentException()).length == 0x59'u32)
            check($(ref UnknownFrameError)(getCurrentException())[] == "UnknownFrameError: Unknown frame type 0xFF received, length 89 bytes")
    test "Parse frame header ignore first bit of stream_id":
        let s = @['\x00'.byte, '\x00'.byte, '\x00'.byte, '\x06'.byte, '\x01'.byte, '\x80'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte]
        let f = parse_from_header(s).frame
        check(f.stream_id == 0)
    test "Parse frame header unknown type":
        let (frame, length) = parse_from_header(@['\x00'.byte, '\x00'.byte, '\x59'.byte, '\xFF'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x01'.byte])
        check(frame.typ.isNone)
        check(length == 0x59)
        check(ExtensionFrame(frame).frame_type.uint8 == 0xFF'u8)
        check(frame.stream_id == 1)
    test "Flags are persisted":
        let (frame, length) = parse_from_header(@['\x00'.byte, '\x00'.byte, '\x59'.byte, '\xFF'.byte, '\x09'.byte, '\x00'.byte, '\x00'.byte, '\x00'.byte, '\x01'.byte])
        check(frame.typ.isNone)
        check(length == 0x59)
        check(ExtensionFrame(frame).frame_type.uint8 == 0xFF'u8)
        check(ExtensionFrame(frame).flag_byte == 0x09'u8)
    test "Parse body unknown type":
        let frame = decode_frame(cast[seq[byte]]("\x00\x00\x0C\xFF\x00\x00\x00\x00\x01hello world!"))
        check(frame.typ.isNone)
        check(cast[string](ExtensionFrame(frame).body) == "hello world!")
        check(frame.body_len == 12)
        check(frame.stream_id == 1)
    test "Can round trip unknown frames":
        let frame_data = cast[seq[byte]]("\x00\x00\x0C\xFF\x00\x00\x00\x00\x01hello world!")
        let frame = decode_frame(frame_data)
        check(frame.serialize() == frame_data)
    test "Cannot parse invalid header":
        expect InvalidFrameError:
            discard parse_from_header(cast[seq[byte]]("\x00\x00\x08\x00\x01\x00\x00\x00"))

suite "Data Frame test suite":
    let payload = cast[seq[byte]]("\x00\x00\x08\x00\x01\x00\x00\x00\x01testdata")
    let payload_with_padding = cast[seq[byte]]("\x00\x00\x13\x00\x09\x00\x00\x00\x01\x0Atestdata\0\0\0\0\0\0\0\0\0\0")
    test "Data frame has correct flags":
        let frame = newDataFrame(1)
        let flags = frame.parse_flags(0xFF)
        check("END_STREAM" in flags)
        check("PADDED" in flags)
        check(flags.len == 2)
    test "Data frame serializes properly":
        let frame = newDataFrame(1, data = cast[seq[byte]]("testdata"), flags = @["END_STREAM"])
        check(frame.serialize() == payload)
    test "Data frame with padding serializes properly":
        let frame = newDataFrame(1, data = cast[seq[byte]]("testdata"), pad_length = 10, flags = @["END_STREAM", "PADDED"])
        check(frame.serialize() == payload_with_padding)
    test "Data frame parses properly":
        let frame = decode_frame(payload)
        check(frame.typ.get == DataFrameType)
        check("END_STREAM" in frame.flags)
        check(frame.flags.len == 1)
        check(DataFrame(frame).data == cast[seq[byte]]("testdata"))
        check(frame.body_len == 8)
        check(DataFrame(frame).pad_length == 0)
    test "Data frame with padding parses properly":
        let frame = decode_frame(payload_with_padding)
        check(frame.typ.get == DataFrameType)
        check("END_STREAM" in frame.flags)
        check("PADDED" in frame.flags)
        check(frame.flags.len == 2)
        check(DataFrame(frame).data == cast[seq[byte]]("testdata"))
        check(frame.body_len == 19)
        check(DataFrame(frame).pad_length == 10)
    test "Data frame with invalid padding errors":
        expect InvalidFrameError:
            discard decode_frame(payload_with_padding[0..<9])
    test "Data frame with padding calculates flow control len":
        let frame = newDataFrame(1, flags = @["PADDED"], data = cast[seq[byte]]("testdata"), pad_length = 10)
        check(DataFrame(frame).flow_controlled_length == 19)
    test "Data frame zero length padding calculates flow control len":
        let frame = newDataFrame(1, flags = @["PADDED"], data = cast[seq[byte]]("testdata"), pad_length = 0)
        check(DataFrame(frame).flow_controlled_length == (cast[seq[byte]]("testdata").len + 1).uint32)
    test "Data frame without padding calculates flow control len":
        let frame = newDataFrame(1, data = cast[seq[byte]]("testdata"))
        check(DataFrame(frame).flow_controlled_length == 8)
    test "Data frame comes on a stream":
        expect InvalidDataError:
            discard newDataFrame(0)
    test "Long data frame":
        let frame = newDataFrame(1, data = repeat[byte]('\x01'.byte, 300))
        let data = frame.serialize()

        check(data[0] == '\x00'.byte)
        check(data[1] == '\x01'.byte)
        check(data[2] == '\x2C'.byte)
    test "Body length behaves correctly":
        let frame = newDataFrame(1, data = repeat[byte]('\x01'.byte, 300))
        check(DataFrame(frame).body_len == 0)
        discard frame.serialize()
        check(DataFrame(frame).body_len == 300)
    test "Data frame with invalid padding fails to parse":
        let data = cast[seq[byte]]("\x00\x00\x05\x00\x0b\x00\x00\x00\x01\x06\x54\x65\x73\x74")
        expect InvalidPaddingError:
            discard decode_frame(data)
    test "Data frame with no length parses":
        let frame = newDataFrame(1)
        let data = serialize(frame)
        let new_frame = decode_frame(data)
        check(DataFrame(new_frame).data == newSeqOfCap[byte](0))

suite "Priority Frame test suite":
    let payload = cast[seq[byte]]("\x00\x00\x05\x02\x00\x00\x00\x00\x01\x80\x00\x00\x04\x40")
    test "repr":
        var f = newPriorityFrame(1)
        check(($f).endsWith("exclusive=false, depends_on=0, stream_weight=0"))
        f = newPriorityFrame(1, exclusive = true, depends_on = 4, stream_weight = 64)
        check(($f).endsWith("exclusive=true, depends_on=4, stream_weight=64"))
    test "Priority frame has no flags":
        let f = newPriorityFrame(1)
        let flags = f.parse_flags(0xFF)
        check(flags.len == 0)
    test "Priority frame default serializes properly":
        let f = newPriorityFrame(1)
        check(f.serialize == cast[seq[byte]]("\x00\x00\x05\x02\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00"))
    test "Priority frame with all data serializes properly":
        let f = newPriorityFrame(1, depends_on = 0x04, stream_weight = 64, exclusive = true)
        check(f.serialize == payload)
    test "Priority frame with all data parses properly":
        let f = decode_frame(payload)
        check(f.typ.get == PriorityFrameType)
        check(f.flags.len == 0)
        check(PriorityFrame(f).depends_on == 4)
        check(PriorityFrame(f).stream_weight == 64)
        check(PriorityFrame(f).exclusive)
        check(f.body_len == 5)
    test "Priority frame invalid":
        expect InvalidFrameError:
            discard decode_frame(cast[seq[byte]]("\x00\x00\x06\x02\x00\x00\x00\x00\x01\x80\x00\x00\x04\x40\xFF"))
    test "Priority frame comes on a stream":
        expect InvalidDataError:
            discard newPriorityFrame(0)
    test "Short priority frame errors":
        expect InvalidFrameError:
            discard decode_frame(payload[0..^2])
    
suite "RST Stream Frame test suite":
    test "repr":
        var f = newRstStreamFrame(1)
        check(($f).endsWith("error_code=0"))
        f = newRstStreamFrame(1, error_code = 420)
        check(($f).endsWith("error_code=420"))
    test "Rst stream frame has no flags":
        let f = newRstStreamFrame(1)
        let flags = f.parse_flags(0xFF)
        check(flags.len == 0)
    test "Rst stream frame serializes properly":
        let f = newRstStreamFrame(1, error_code = 420)
        check(f.serialize == cast[seq[byte]]("\x00\x00\x04\x03\x00\x00\x00\x00\x01\x00\x00\x01\xa4"))
    test "Rst stream frame parses properly":
        let s = cast[seq[byte]]("\x00\x00\x04\x03\x00\x00\x00\x00\x01\x00\x00\x01\xa4")
        let f = decode_frame(s)
        check(f.typ.get == RstStreamFrameType)
        check(f.flags.len == 0)
        check(RstStreamFrame(f).error_code == 420)
        check(f.body_len == 4)
    test "Rst stream frame comes on a stream":
        expect InvalidDataError:
            discard newRstStreamFrame(0)
    test "Rst stream frame must have body of four":
        let f = newRstStreamFrame(1)
        expect InvalidFrameError:
            f.parse_body(@['\x01'.byte])

suite "Settings Frame test suite":
    let serialized = cast[seq[byte]]("\x00\x00\x2A\x04\x01\x00\x00\x00\x00" &  # Frame header
        "\x00\x01\x00\x00\x10\x00" &              # HEADER_TABLE_SIZE
        "\x00\x02\x00\x00\x00\x00" &              # ENABLE_PUSH
        "\x00\x03\x00\x00\x00\x64" &              # MAX_CONCURRENT_STREAMS
        "\x00\x04\x00\x00\xFF\xFF" &              # INITIAL_WINDOW_SIZE
        "\x00\x05\x00\x00\x40\x00" &              # MAX_FRAME_SIZE
        "\x00\x06\x00\x00\xFF\xFF" &              # MAX_HEADER_LIST_SIZE
        "\x00\x08\x00\x00\x00\x01")                # ENABLE_CONNECT_PROTOCOL
    let settings = {
        HEADER_TABLE_SIZE: 4096'u32,
        ENABLE_PUSH: 0'u32,
        MAX_CONCURRENT_STREAMS: 100'u32,
        INITIAL_WINDOW_SIZE: 65535'u32,
        MAX_FRAME_SIZE: 16384'u32,
        MAX_HEADER_LIST_SIZE: 65535'u32,
        ENABLE_CONNECT_PROTOCOL: 1'u32,
    }.toOrderedTable
    test "repr":
        var f = newSettingsFrame()
        check(($f).endsWith "settings={:}")
        f = newSettingsFrame(settings = {MAX_FRAME_SIZE: 16384'u32}.toOrderedTable)
        check(($f).endsWith "settings={5: 16384}")
    test "Settings frame has only one flag":
        let f = newSettingsFrame()
        let flags = f.parse_flags(0xFF)
        check(flags.len == 1)
        check("ACK" in flags)
    test "Settings frame serializes properly":
        let f = newSettingsFrame(settings = settings)
        discard f.parse_flags(0xFF)
        let s = f.serialize
        checkpoint s
        checkpoint serialized
        check(s == serialized)
    test "Settings frame with settings":
        let f = newSettingsFrame(settings = settings)
        check(SettingsFrame(f).settings == settings)
    test "Settings frame without settings":
        let f = newSettingsFrame()
        check(SettingsFrame(f).settings == initOrderedTable[Settings, uint32]())
    test "Settings frame with ack":
        let f = newSettingsFrame(flags = @["ACK"])
        check("ACK" in f.flags)
    test "Settings frame ack and settings":
        expect InvalidDataError:
            discard newSettingsFrame(settings = settings, flags = @["ACK"])
    test "Settings frame parses properly":
        let data = serialized[0..<4] & @['\x00'.byte] & serialized[5..^1]
        let f = decode_frame(data)
        check(f.typ.get == SettingsFrameType)
        check(SettingsFrame(f).settings == settings)
        check(f.body_len == 42)
        check(f.flags.len == 0)
    test "Settings frame invalid body length":
        expect InvalidFrameError:
            discard decode_frame(cast[seq[byte]]("\x00\x00\x2A\x04\x00\x00\x00\x00\x00\xFF\xFF\xFF\xFF"))
    test "Settings frame never have streams":
        expect InvalidDataError:
            discard newSettingsFrame(1)
    test "Short settings frame errors":
        expect InvalidDataError:
            discard decode_frame(serialized[0..^2])

suite "Push Promise Frame test suite":
    test "repr":
        var f = newPushPromiseFrame(1)
        check(($f).endsWith "promised_stream_id=0, data=nil")
        f = newPushPromiseFrame(1, promised_stream_id = 4, data = cast[seq[byte]]("testdata"))
        checkpoint $f
        check(($f).endsWith "promised_stream_id=4, data=<hex:7465737464617461>")

    test "Push promise frame flags":
        let f = newPushPromiseFrame(1)
        let flags = f.parse_flags(0xFF)
        check(flags.len == 2)
        check("END_HEADERS" in flags)
        check("PADDED" in flags)
    test "Push promise frame serializes properly":
        let f = newPushPromiseFrame(1, promised_stream_id = 4, data = cast[seq[byte]]("hello world"), flags = @["END_HEADERS"])
        let s = f.serialize
        echo s
        check(s == cast[seq[byte]]("\x00\x00\x0F\x05\x04\x00\x00\x00\x01\x00\x00\x00\x04hello world"))
    test "Push promise frame parses properly":
        let s = cast[seq[byte]]("\x00\x00\x0F\x05\x04\x00\x00\x00\x01\x00\x00\x00\x04hello world")
        let f = decode_frame(s)
        check(f.typ.get == PushPromiseFrameType)
        check(f.flags.len == 1)
        check("END_HEADERS" in f.flags)
        check(f.body_len == 15)
        check(PushPromiseFrame(f).data == cast[seq[byte]]("hello world"))
        check(PushPromiseFrame(f).promised_stream_id == 4)
    test "Push promise frame with padding":
        let s = cast[seq[byte]]("\x00\x00\x17\x05\x0C\x00\x00\x00\x01\x07\x00\x00\x00\x04hello worldpadding")
        let f = decode_frame(s)
        check(f.typ.get == PushPromiseFrameType)
        check(f.flags.len == 2)
        check("END_HEADERS" in f.flags)
        check("PADDED" in f.flags)
        check(f.body_len == 23)
        check(PushPromiseFrame(f).data == cast[seq[byte]]("hello world"))
        check(PushPromiseFrame(f).promised_stream_id == 4)
    test "Push promise frame with invalid padding fails to parse":
        let data = cast[seq[byte]]("\x00\x00\x05\x05\x08\x00\x00\x00\x01\x06\x54\x65\x73\x74")
        expect InvalidPaddingError:
            discard decode_frame(data)
    test "Push promise frame with no length parses":
        let f = newPushPromiseFrame(1, 2)
        let data = f.serialize
        let new_frame = decode_frame(data)

        check(PushPromiseFrame(new_frame).data == newSeqOfCap[byte](0))
    test "Push promise frame invalid":
        var data = newPushPromiseFrame(1, 0).serialize
        expect InvalidDataError:
            discard decode_frame(data)
        data = newPushPromiseFrame(1, 3).serialize
        expect InvalidDataError:
            discard decode_frame(data)
    test "Short push promise errors":
        let s = cast[seq[byte]]("\x00\x00\x0F\x05\x04\x00\x00\x00\x01\x00\x00\x00")
        expect InvalidFrameError:
            discard decode_frame(s)
