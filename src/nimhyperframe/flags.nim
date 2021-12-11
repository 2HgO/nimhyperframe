import sets
from sequtils import map, toSeq
from algorithm import sort

type
    Flag* = tuple
        name: string
        bit: uint8
    FlagsObj = object
        valid_flags : HashSet[string]
        flags : HashSet[string]
    Flags* = ref FlagsObj

proc newFlags*(defined_flags: seq[Flag]) : Flags =
    result = Flags(valid_flags: toHashSet(defined_flags.map(proc(x: Flag) : string = x.name)), flags: initHashSet[string]())

iterator items*(f: Flags) : string =
    for i in f.flags: yield i

proc len*(f: Flags) : int = result = f.flags.len

proc contains*(f: Flags, s: string) : bool {.inline.} = s in f.flags
proc `in`*(s: string, f: Flags) : bool {.inline.} = s in f.flags

proc exclude*(f: Flags, s: string) : void = f.flags.excl(s)

proc add*(f: Flags, s: string) : void =
    if not (s in f.valid_flags): raise newException(ValueError, "Unexpected flag: " & s & ". Valid flags are: " & $f.valid_flags)
    f.flags.incl(s)

proc `$`*(f: Flags) : string =
    var list = f.flags.toSeq
    sort(list, cmp)
    result = $list
