#
#
#  StashTable, a contender for Nim stdlib's SharedTable
#        (c) Copyright 2020 Olli Niinivaara
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#  
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#

## `StashTable` is a space- and time-efficient generic concurrent hash table
## (also often named map or dictionary in other programming languages)
## that is a mapping from keys to values.
##
## Thanks to it's unique collision resolution strategy, StashTable provides following key features:
## * O(1) amortized parallel reads and writes
## * O(1) worst-case serialized inserts
## * O(1) amortized serialized deletes
## * Fast, cache-friendly iterating that does not block and is not blocked by any other operation
## 
## API in a nutshell: 
## * `keys<#keys.i%2CStashTable%5BK%2CV%2CCapacity%5D>`_ iterator to access all items
## * `withValue<#withValue.t%2CStashTable%5BK%2CV%2CCapacity%5D%2CK%2Cuntyped%2Cuntyped>`_ and
##   `withFound<#withFound.t%2CStashTable%5BK%2CV%2CCapacity%5D%2CK%2CIndex%2Cuntyped>`_ templates lock access to a single item
##   but any other operation can proceed in parallel
## * other operations (`len<#len%2CStashTable>`_, `insert<#insert%2CStashTable%5BK%2CV%2CCapacity%5D%2CK%2CV>`_, 
##   `upsert<#upsert%2CStashTable%5BK%2CV%2CCapacity%5D%2CK%2CV>`_, `addAll<#addAll%2CStashTable%5BK%2CV%2CCapacity1%5D%2CStashTable%5BK%2CV%2CCapacity2%5D%2Cbool>`_, 
##   `del<#addAll%2CStashTable%5BK%2CV%2CCapacity1%5D%2CStashTable%5BK%2CV%2CCapacity2%5D%2Cbool>`_, 
##   and `clear<#clear%2CStashTable%5BK%2CV%2CCapacity%5D>`_) will block each other
##
## caveats:
## * Because iterating does not block, aggregate functions do not give consistent answers if other threads are modifying the table
## * ``withValue`` or ``withFound`` calls cannot be nested, unless always in same key order. Otherwise a deadlock is bound to occur
## * A blocking operation cannot be called from inside ``withValue`` or ``withFound``. Otherwise a deadlock is bound to occur
## * Don't put strings or seqs in keys or values (this is an inherent limitation of Nim itself)
## 
## StashTable has `ref semantics<https://nim-lang.org/docs/manual.html#types-reference-and-pointer-types>`_.
##
## Basic usage
## -----------
##
## .. code-block:: nim
##  from sequtils import zip
##
##  type BeatleName = enum
##    Nil = "", John = "John", Paul = "Paul", George = "George", Ringo = "Ringo"
##    
##  const BeatleMaximum = 4
##
##  let
##    names = [John, Paul, George, Ringo]
##    years = [1940, 1942, 1943, 1940]
##    beatles = newStashTable[BeatleName, int, BeatleMaximum]()
##  
##  for (name , birthYear) in zip(names, years):
##    beatles[name] = birthYear
##  
##  echo beatles
##  doAssert $beatles == "{John: 1940, Paul: 1942, George: 1943, Ringo: 1940}"
##  
##  type Names = array[2, BeatleName]
##  
##  let beatlesByYear = newStashTable[int, Names, BeatleMaximum]()
##  
##  for (birthYear , name) in zip(years, names):
##    beatlesByYear.withValue(birthYear):    
##      value[1] = name
##    do: 
##      # key doesn't exist, we create one
##      beatlesByYear[birthYear] = [name, Nil]
##  
##  echo beatlesByYear
##  doAssert $beatlesByYear == "{1940: [John, Ringo], 1942: [Paul, ], 1943: [George, ]}"
##   
#[ DocGen fails...
runnableExamples:
    from sequtils import zip

    type BeatleName = enum
      Nil = "", John = "John", Paul = "Paul", George = "George", Ringo = "Ringo"
    
    const BeatleMaximum = 4
    
    let
      names = [John, Paul, George, Ringo]
      years = [1940, 1942, 1943, 1940]
      beatles = newStashTable[BeatleName, int, BeatleMaximum]()
    
    for (name , birthYear) in zip(names, years):
      beatles[name] = birthYear
    
    echo beatles
    doAssert $beatles == "{John: 1940, Paul: 1942, George: 1943, Ringo: 1940}"
    
    type Names = array[2, BeatleName]
    
    let beatlesByYear = newStashTable[int, Names, BeatleMaximum]()
    
    for (birthYear , name) in zip(years, names):
      beatlesByYear.withValue(birthYear):    
        value[1] = name
      do: 
        # key doesn't exist, we create one
        beatlesByYear[birthYear] = [name, Nil]
    
    echo beatlesByYear
    doAssert $beatlesByYear == "{1940: [John, Ringo], 1942: [Paul, ], 1943: [George, ]}"
]#

## See also
## --------
## `sharedtables<https://nim-lang.org/docs/sharedtables.html>`_
## `tables<https://nim-lang.org/docs/tables.html>`_
## `hashes<https://nim-lang.org/docs/hashes.html>`_

import locks, hashes
export locks
from math import isPowerOfTwo

type
  Item[K; V] = tuple[lock: Lock, hash: int, key: K, value: V]

  Index* = distinct int
    ## Index to an item (item = key-value pair).
    ## Other threads may delete or move the item until it's locked with ``withFound`` template.
    
  StashTableObject[K; V; Capacity: static int] = object
    totallock: Lock
    freeindex: int
    storage: array[Capacity, Item[K,V]]
    deletioncount: int
    deletionstack: array[Capacity, Index]
    hashes: array[Capacity, tuple[count: int, first: Index, last: Index]]

  StashTable*[K; V; Capacity: static int] = ref StashTableObject[K, V, Capacity]
    ## Generic thread-safe hash table.
    
const NotInStash* = (low(int32) + 1).Index
  ## Index for keys not in the table.

{.push checks:off.}

proc newStashTable*[K; V; Capacity: static int](): StashTable[K, V, Capacity] =
  ## Creates a new hash table that is empty.
  ##
  ## ``Capacity`` must be a power of two.
  ## If you need to accept runtime values for this you could use the
  ## `nextPowerOfTwo<https://nim-lang.org/docs/math.html#nextPowerOfTwo,int>`_ proc
  ##
  ## After maximum capacity is reached, inserts and upserts will start returning ``NotInStash``.
  ## If you need to grow the capacity, create a new larger table, copy items to it
  ## with ``addAll`` proc and switch reference(s). 
  ##
  ## Recommended practice is to reserve enough capacity right at initialisation, because
  ## * StashTable is very space-efficient anyway (especially when using pointers as values)
  ## * ``addAll`` takes some time and blocked operations will naturally not be reflected in new table.
  ## * ``addAll`` will temporarily need enough memory to hold both old ***and*** new table
  ## * Last but not least: all extra capacity will speed up execution by lowering probability of hash collisions
  ##
 
  doAssert isPowerOfTwo(Capacity)
  result = StashTable[K, V, Capacity]()
  result.totallock.initLock()
  for i in 0 .. result.storage.high:
    result.storage[i].lock.initLock()
    result.storage[i].hash = NotInStash.int
    result.hashes[i] = (0, NotInStash , NotInStash)

proc `=destroy`*[K, V, Capacity](stash: var StashTableObject[K, V, Capacity]) =
  ## Releases OS resources reserved by locks.
  stash.totallock.deinitLock()
  for i in 0 .. stash.storage.high: stash.storage[i].lock.deinitLock()
 
proc `==`*(x, y: Index): bool {.borrow.}

proc `$`*(index: Index): string =
  if index == NotInStash: "NotInStash"
  else: '@' & $index.int

iterator keys*[K, V, Capacity](stash: StashTable[K, V, Capacity]): (K , Index) =
  ## Iterates over all ``(key , index)`` pairs in the table ``stash``.
  ##
  ## feature: if there are no deletes, iteration order is insertion order.
  ##
  ## .. code-block:: nim  
  ##  let a = newStashTable[char, array[4, int], 128]()
  ##  a['o'] = [1, 5, 7, 9]
  ##  a['e'] = [2, 4, 6, 8]  
  ##  for (k , index) in a.keys:
  ##    a.withFound(k, index):
  ##      echo "key: ", k
  ##      echo "value: ", value[]
  ##      doAssert (k == 'o' and value[] == [1, 5, 7, 9]) or (k == 'e' and value[] == [2, 4, 6, 8])  
  #[
  docgen fail
  runnableExamples:  
      let a = newStashTable[char, array[4, int], 128]()
      a['o'] = [1, 5, 7, 9]
      a['e'] = [2, 4, 6, 8]  
      for (k , index) in a.keys:
        a.withFound(k, index):
          echo "key: ", k
          echo "value: ", value[]
          doAssert (k == 'o' and value[] == [1, 5, 7, 9]) or (k == 'e' and value[] == [2, 4, 6, 8])  
  for i in 0 .. stash.freeindex - 1:
    if(likely) stash.storage[i].hash != NotInStash.int: yield (stash.storage[i].key , i.Index)
]#

proc hashis*[K](t: StashTable, key: K): int {.inline.} =
  ## This should not need to be public...
  hash(key) and t.hashes.high

proc len*(stash: StashTable): int {.inline.} =
  ## Returns the number of keys in ``stash``.
  withLock(stash.totallock): result = stash.freeindex - stash.deletioncount 

proc findIndex*[K, V, Capacity](stash: StashTable[K, V, Capacity], key: K): Index =
  ## Returns ``Index`` for given ``key``, or ``NotInStash`` if key was not in ``stash``.
  ## Note that the returned ``Index`` may be invalidated at any moment by other threads.
  let h = stash.hashis(key)
  if stash.hashes[h].count == 0: return NotInStash
  var founds = 0
  if stash.hashes[h].first != NotInStash:
    founds.inc
    if stash.storage[stash.hashes[h].first.int].key == key: 
      return if stash.storage[stash.hashes[h].first.int].hash != NotInStash.int: stash.hashes[h].first else: NotInStash
  if stash.hashes[h].last != NotInStash:
     founds.inc 
     if stash.storage[stash.hashes[h].last.int].key == key:
       return if stash.storage[stash.hashes[h].last.int].hash != NotInStash.int: stash.hashes[h].last else: NotInStash
  if stash.hashes[h].count < 3: return NotInStash
  for i in stash.hashes[h].first.int + 1 .. stash.hashes[h].last.int - 1:
    if(unlikely) (stash.storage[i].hash == NotInStash.int): continue
    if(unlikely) stash.storage[i].key == key: return i.Index
    if(unlikely) stash.storage[i].hash == h:
      founds.inc
      if(unlikely) founds >= stash.hashes[h].count: return NotInStash 
  return NotInStash

proc `[]`[K; V; Capacity](stash: StashTable[K, V, Capacity], index: Index): var Item[K, V] {.inline.} = stash.storage[index.int]

template withFound*[K, V, Capacity](stash: StashTable[K, V, Capacity],  thekey: K, theindex: Index, body: untyped) =
  ## Retrieves pointer to the value as variable ``value`` at ``theindex``.
  ## ``thekey`` must also be given to ensure that the given Index is still holding the putative item.
  ##
  ## Item is locked and value can be modified in the scope of ``withFound`` call.
  ##
  ## On one hand this is faster operation than ``withValue`` because there's no need to
  ## find the Index, but on other hand there's greater probability that the item was
  ## deleted and reinserted to other Index by other thread(s) since the Index was retrieved.
  runnableExamples:
      type Item = tuple[name: char, uid: int]
      let stash = newStashTable[int, Item, 8]()
      let key = 42
      stash[key] = ('a', 555)
      let index = stash.findIndex(key)
      stash.withFound(key , index):
        # block is executed only if ``key`` in ``index``
        value.name = 'u'
        value.uid = 1000
      stash.withFound(42 , 0.Index): doAssert value.name == 'u'
  if theindex != NotInStash:
    withLock(stash[theindex].lock):
      if(likely) stash[theindex].hash != NotInStash.int and stash[theindex].key == thekey:
        var value {.inject.} = addr stash[theindex].value
        body

template withValue*[K, V, Capacity](stash: StashTable[K, V, Capacity], thekey: K, body1, body2: untyped) =
  ## Retrieves pointer to the value as variable ``value`` for ``thekey``.
  ## Item is locked and ``value`` can be modified in the scope of ``withValue`` call.
  ##
  ## **Example:**
  ##
  ## .. code-block:: nim
  ##  stashTable.withValue(key):
  ##    # block is executed only if ``key`` in ``stashTable``
  ##    value.name = username
  ##    value.uid = 1000
  ##  do:
  ##    # block is executed when ``key`` not in ``stashTable``
  ##    raise newException(KeyError, "Key not found")
  ##

  #[ does not render correctly...
  runnableExamples:
      let s = newStashTable[int, char, 4]()
      let key = 123
      s[key] = 'x'
      s.withValue(key):
        # block is executed only if ``key`` in ``stashTable``
        value[] = 'y'        
      do:
        # block is executed when ``key`` not in ``stashTable``
        raise newException(KeyError, "Key not found") ]#

  let index = stash.findIndex(thekey)
  if index == NotInStash: body2
  else:
    acquire(stash[index].lock)
    if(likely) stash[index].hash != NotInStash.int and stash[index].key == thekey:
      var value {.inject.} = addr stash[index].value
      try:
        body1
      finally:
        release(stash[index].lock)
    else:
      release(stash[index].lock)
      body2

template withValue*[K, V, Capacity](stash: StashTable[K, V, Capacity], thekey: K, body: untyped) =
  ## Retrieves pointer to the value as variable ``value`` for ``thekey``.
  ## Item is locked and ``value`` can be modified in the scope of ``withValue`` call.
  let index = stash.findIndex(thekey)
  if index != NotInStash:
    withLock(stash[index].lock):
      if(likely) stash[index].hash != NotInStash.int and stash[index].key == thekey:
        var value {.inject.} = addr stash[index].value
        body

proc `$`*(stash: StashTable): string =
  if stash.len == 0: return "{:}"
  result = "{"
  for (key , index) in stash.keys():
    stash.withFound(key, index):
      if result.len > 1: result.add(", ")
      result.addQuoted(key)
      result.add(": ")      
      result.addQuoted(value[])
  result.add("}")

template reserveIndex[K, V, Capacity](thestash: StashTable[K, V, Capacity]) =
  if thestash.deletioncount > 0:
    index = thestash.deletionstack[thestash.deletioncount - 1]
    thestash.deletioncount.dec
  else:
    if thestash.freeindex == Capacity: return (NotInStash , false)
    index = thestash.freeindex.Index
    thestash.freeindex.inc
  assert(thestash[index].hash == NotInStash.int)

template useIndex(thestash: StashTable) =
  let h = thestash.hashis(key)
  withLock(thestash[index].lock):
    if thestash.hashes[h].first == NotInStash or index.int < thestash.hashes[h].first.int:
      if thestash.hashes[h].last == NotInStash: thestash.hashes[h].last = thestash.hashes[h].first
      thestash.hashes[h].first = index
    elif thestash.hashes[h].last == NotInStash or index.int > thestash.hashes[h].last.int: thestash.hashes[h].last = index
    thestash[index].key = key
    thestash[index].hash = h
    thestash.hashes[h].count.inc

proc put[K, V, Capacity](stash: StashTable[K, V, Capacity], key: K, value: V, upsert = false): (Index , bool) {.inline.} =
  withLock(stash.totallock):
    var inserted = false
    var index = stash.findIndex(key)
    if index == NotInStash:
      reserveIndex(stash)
      inserted = true
    elif not upsert: return (index , false)
    stash[index].value = value
    useIndex(stash)
    if not upsert: return (index , true)
    else: return (index , inserted)

proc insert*[K, V, Capacity](stash: StashTable[K, V, Capacity], key: K, value: V): (Index , bool) =
  ## Inserts a ``(key, value)`` pair into ``stash``.
  ## Returns a tuple with following information:
  ## * ``(i , true)`` : The item was succesfully inserted to Index i
  ## * ``(i , false)`` : The item was not inserted because there was already item with the same ``key`` at Index i
  ## * ``(NotInStash , false)`` : The item was not inserted because ``stash`` was full, i.e. ``len`` == ``Capacity``
  ##
  runnableExamples:
      let a = newStashTable[char, int, 1024]()  
      let (index1, wasinserted1) = a.insert('x', 7)
      doAssert wasinserted1
      let (index2, wasinserted2) = a.insert('x', 33)
      doAssert index2 == index1 and not wasinserted2
  stash.put(key, value)
    
proc upsert*[K, V, Capacity](stash: StashTable[K, V, Capacity], key: K, value: V): (Index , bool) = stash.put(key, value, true)
  ## Updates value at ``stash[key]`` or inserts item if ``key`` not present.
  ## Returns a tuple with following information:
  ## * ``(i , true)`` : The item was succesfully inserted to Index i
  ## * ``(i , false)`` : The item already existed at Index i and it's value was updated to given ``value``
  ## * ``(NotInStash , false)`` : The key did not exist but the item could not be inserted because ``stash`` was full

proc `[]=`*[K, V, Capacity](stash: StashTable[K, V, Capacity], key: K, value: V) = discard stash.put(key, value, true)
  ## Executes ``upsert`` and silently discards the result.

proc addAll*[K; V; Capacity1: static int, Capacity2: static int](
     toStashTable: StashTable[K, V, Capacity1], fromStashTable: StashTable[K, V, Capacity2], upsert: bool): bool =    
  ## Copies all items from ``fromStashTable`` to ``toStashTable``.
  ## ``upsert`` parameter tells whether existing keys will be updated or skipped.
  acquire(toStashTable.totallock)
  acquire(fromStashTable.totallock)
  defer:
    release(fromStashTable.totallock)
    release(toStashTable.totallock)
  for (key , fromindex) in fromStashTable.keys:
    var index = toStashTable.findIndex(key)
    if index == NotInStash: reserveIndex(toStashTable)
    elif not upsert: continue
    fromStashTable.withFound(key, fromindex):
      toStashTable[index].value = value[]
      useIndex(toStashTable)
  return true

proc removeHash[K, V, Capacity](stash: StashTable[K, V, Capacity], index: Index, key: K) {.inline.} =
  let h = stash.hashis(key)
  stash.hashes[h].count.dec
  if stash.hashes[h].count == 0:
    stash.hashes[h].first = NotInStash
    return
  if index == stash.hashes[h].first:
    if stash.hashes[h].count == 1:
      stash.hashes[h].first = stash.hashes[h].last
      stash.hashes[h].last = NotInStash
    else:
      for i in stash.hashes[h].first.int + 1 ..< stash.hashes[h].last.int:
        if(unlikely) stash.hashis(stash.storage[i].key) == h:
          if (likely) stash.storage[i].hash != NotInStash.int:
            stash.hashes[h].first = i.Index
            return   
  elif index == stash.hashes[h].last:
    if stash.hashes[h].count == 1:
      stash.hashes[h].last = NotInStash
    else:
      for i in countdown(stash.hashes[h].last.int - 1, stash.hashes[h].first.int + 1):
        if(unlikely) stash.hashis(stash.storage[i].key) == h:
          if(likely) stash.storage[i].hash != NotInStash.int:
            stash.hashes[h].last = i.Index
            return
          
proc del*[K, V, Capacity](stash: StashTable[K, V, Capacity], key: K) =
  ## Deletes ``key`` from ``stash``. Does nothing if the key does not exist.
  ##
  ## Note that ``del`` must not be called from inside a ``withValue`` or ``withFound`` block.
  ## Instead, write down the ``key`` and call ``del`` afterwards.
  ##
  ## .. code-block:: nim
  ##  let s = newStashTable[int, char, 4]()
  ##  var deletables: seq[int]
  ##  s[1] = 'a' ; s[2] = 'b' ; s[3] = 'a'
  ##  doAssert s.len == 3
  ##  for (key, index) in s.keys:
  ##    s.withFound(key, index):
  ##      if value[] != 'b': deletables.add(key)
  ##  for key in deletables: s.del(key)
  ##  doAssert s.len == 1
  #[
    renders incorrectly
  runnableExamples:
      let s = newStashTable[int, char, 4]()
      var deletables: seq[int]
      s[1] = 'a' ; s[2] = 'b' ; s[3] = 'a'
      doAssert s.len == 3
      for (key, index) in s.keys:
        s.withFound(key, index):
          if value[] != 'b': deletables.add(key)
      for key in deletables: s.del(key)
      doAssert s.len == 1
  ]#
  withLock(stash.totallock):
    let index = stash.findIndex(key)
    if index == NotInStash: return
    withLock(stash[index].lock):
      if stash[index].hash == NotInStash.int or stash[index].key != key: return
      stash[index].hash = NotInStash.int
      if index.int == stash.freeindex - 1: stash.freeindex.dec
      else:
        stash.deletionstack[stash.deletioncount] = index
        stash.deletioncount.inc    
      stash.removeHash(index, key)
  
proc clear*[K, V, Capacity](stash: StashTable[K, V, Capacity]) =
  ## Resets the stash so that it is empty.
  withLock(stash.totallock):
    stash.freeindex = 0
    stash.deletioncount = 0
    for i in 0 .. stash.storage.high:
      stash.storage[i].hash = NotInStash.int
      stash.hashes[i] = (0, NotInStash , NotInStash)

{.pop.}