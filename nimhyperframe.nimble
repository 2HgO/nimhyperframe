# Package

version       = "0.1.0"
author        = "Oghogho Odemwingie <odemwingieog@gmail.com>"
description   = "Hyperframe port for nim"
license       = "MIT"
srcDir        = "src"


# Dependencies
requires "nim >= 1.4.0"
requires "struct >= 0.2.3"

when not defined(release):
    requires "https://github.com/disruptek/balls >= 3.7.0"
