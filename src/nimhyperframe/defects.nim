type
    HyperFrameDefect* = ref object of CatchableError
    UnknownFrameDefect* = ref object of HyperFrameDefect
        frame_type*: int8
        length*: int8
    InvalidPaddingDefect* = ref object of HyperFrameDefect
    InvalidFrameDefect* = ref object of HyperFrameDefect
    InvalidDataDefect* = ref object of HyperFrameDefect

proc newUnknownFrameDefect*(typ: int8, lth: int8) : UnknownFrameDefect = result = UnknownFrameDefect(frame_type: typ, length: lth)
proc `$`*(u: UnknownFrameDefect) : string =
    result = "UnknownFrameDefect: Unknown frame type 0x" & $u.frame_type & "received, \nlength " & $u.length & " bytes"
