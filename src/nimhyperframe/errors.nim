type
    HyperFrameError* = ref object of CatchableError
    UnknownFrameError* = ref object of HyperFrameError
        frame_type*: int8
        length*: int8
    InvalidPaddingError* = ref object of HyperFrameError
    InvalidFrameError* = ref object of HyperFrameError
    InvalidDataError* = ref object of HyperFrameError
    ImplementationError* = ref object of HyperFrameError

proc newUnknownFrameError*(typ: int8, lth: int8) : UnknownFrameError = result = UnknownFrameError(frame_type: typ, length: lth)
proc `$`*(u: UnknownFrameError) : string =
    result = "UnknownFrameError: Unknown frame type 0x" & $u.frame_type & "received, \nlength " & $u.length & " bytes"
