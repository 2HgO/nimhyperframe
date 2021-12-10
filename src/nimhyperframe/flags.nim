import sets
import sequtils

type
    Flag* = tuple
        name: string
        bit: int8
    FlagsObj = object
        valid_flags : HashSet[string]
        flags : HashSet[string]
    Flags* = ref FlagsObj

proc newFlags*(defined_flags: seq[Flag]) : Flags =
    result = Flags(valid_flags: toHashSet(defined_flags.map(proc(x: Flag) : string = x.name)), flags: initHashSet[string]())

iterator items*(f: Flags) : string =
    for i in f.flags: yield i

proc len*(f: Flags) : int = result = f.flags.len

proc contains*(f: Flags, s: string) : bool = s in f.flags
proc `in`*(s: string, f: Flags) : bool {.inline.} = f.contains(s)

proc exclude*(f: Flags, s: string) : void = f.flags.excl(s)

proc add*(f: Flags, s: string) : void =
    if not (s in f.valid_flags): raise newException(ValueError, "Unexpected flag: " & s & ". Valid flags are: " & $f.valid_flags)
    f.flags.incl(s)

proc `$`*(f: Flags) : string =
    result = $f.flags
