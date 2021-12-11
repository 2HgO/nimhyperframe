from strformat import `fmt`

type
    HyperFrameError* = object of CatchableError
    UnknownFrameError* = object of HyperFrameError
        frame_type*: uint8
        length*: uint32
    InvalidPaddingError* = object of HyperFrameError
    InvalidFrameError* = object of HyperFrameError
    InvalidDataError* = object of HyperFrameError
    ImplementationError* = object of HyperFrameError

template newUnknownFrameError*(typ: uint8, lth: uint32) : untyped =
    (ref UnknownFrameError)(frame_type: typ, length: lth, msg: "Unknown Frame Error")
proc `$`*(u: UnknownFrameError) : string =
    result = fmt"""UnknownFrameError: Unknown frame type {u.frame_type:#X} received, length {u.length} bytes"""
