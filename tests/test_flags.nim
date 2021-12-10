import balls
from sequtils import toSeq

import nimhyperframe

suite "Flags test suite":
    test "Add flag":
        var flags = newFlags(@[(name: "VALID_FLAG", bit: 0x00.byte)])
        checkpoint flags

        flags.add("VALID_FLAG")
        flags.add("VALID_FLAG")
        check("VALID_FLAG" in flags)
        check(toSeq(flags) == @["VALID_FLAG"])
        check(flags.len == 1)

