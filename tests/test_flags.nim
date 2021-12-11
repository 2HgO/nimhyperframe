import balls
from sequtils import toSeq

import nimhyperframe

suite "Flags test suite":
    test "Add flag":
        var flags = newFlags(@[(name: "VALID_FLAG", bit: 0x00.uint8)])
        checkpoint flags

        flags.add("VALID_FLAG")
        flags.add("VALID_FLAG")
        check("VALID_FLAG" in flags)
        check(toSeq(flags) == @["VALID_FLAG"])
        check(flags.len == 1)
    
    test "Remove flag":
        var flags = newFlags(@[(name: "VALID_FLAG", bit: 0x00.uint8)])
        checkpoint flags
        flags.add("VALID_FLAG")

        flags.exclude("VALID_FLAG")
        check("VALID_FLAG" notin flags)
        check(toSeq(flags) == @[])
        check(flags.len == 0)

    test "Validate flag":
        var flags = newFlags(@[(name: "VALID_FLAG", bit: 0x00.uint8)])
        checkpoint flags
        flags.add("VALID_FLAG")
        expect ValueError:
            flags.add("INVALID_FLAG")

    test "Repr flag":
        var flags = newFlags(@[(name: "VALID_FLAG", bit: 0x00.uint8), (name: "OTHER_FLAG", bit: 0x00.uint8)])
        checkpoint flags

        check($flags == "@[]")
        flags.add("VALID_FLAG")
        check($flags == "@[\"VALID_FLAG\"]")
        flags.add("OTHER_FLAG")
        check($flags == "@[\"OTHER_FLAG\", \"VALID_FLAG\"]")
