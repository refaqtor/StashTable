# StashTable
Concurrent hash table for Nim

## Installation

`nimble install https://github.com/olliNiinivaara/StashTable?subdir=stashtable`

## Documentation

http://htmlpreview.github.io/?https://github.com/olliNiinivaara/StashTable/blob/master/stashtable/src/stashtable.html

## Benchmarking

`nimble test`

Compares StashTable against SharedTable. You can benchmark different
aspects by modifying the consts in test.nim file.
Essentially, SharedTable will drastically slow down when reading or writing
takes some time (simulateio parameter in test.nim), while StashTable just keeps going.

## Testing

`nimble test`

Benchmarking and testing are integrated. Each benchmark run ends with a pseudorandom
sequence of operations executed on both tables after which the table contents are compared.
There will nondeterministically be notifications that the contents do not align.
Explanation is that a context switch has happened when an operation was executed on
the other table but not yet on the other, and the other thread operated on the same key.
For example:
```
...
Thread 1:
Stashtable : op1-1: insert X
Thread 2:
Stashtable : op2-1: delete X
Sharedtable: op2.1: delete X
Thread 1:
Sharedtable: op1-1: insert X
...
```