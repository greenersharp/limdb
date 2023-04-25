## .. include:: docs.rst

# this is mainly here to temporarily store form data after each keystroke
# it probably doesn't matter at the likely scale of usage, but it just seems
# like such bad fit for sqllite to write to the darn file and block comment loading
# whenever someone presses a key. Hence, way overkill but lovely, lmdb.

# could do it on the client but it will just be such a pleasant surprise when
# someone finds a half-finished comment already there when loading on another device

import std/[os, macros], lmdb

when NimMajor >= 1 and NimMinor >= 4:
  import std/effecttraits

export lmdb

type
  Database*[A, B] = object
    ## A key-value database in a memory-mapped on-disk storage location.
    env*: LMDBEnv
    dbi*: Dbi

  Transaction*[A, B] = object
    ## A transaction may be created and reads or writes performed on it instead of directly
    ## on a database object. That way, reads or writes are not affected by other writes happening
    ## at the same time, and changes happen all at once at the end or not at all.
    txn*: LMDBTxn
    dbi*: Dbi

  Blob* = Val
    ## A variable-length collection of bytes that can be used as either a key or value. This
    ## is LMDB's native storage type- a block of memory. `string` types are converted automatically,
    ## and conversion for other data types can be added by adding `fromBlob` and `toBlob` for a type.

  Writes* = object
    ## A tag to track write transactions
  Concludes* = object
    ## A tag to track commits and rollbacks

  LimDefect* = object of Defect

proc open*[A, B](d: Database[A, B], name: string): Dbi =
  # Open a database and return a low-level handle
  let dummy = d.env.newTxn()  # lmdb quirk, need an initial txn to open dbi that can be kept
  result = dummy.dbiOpen(name, if name == "": 0 else: lmdb.CREATE)
  dummy.commit()

proc initDatabase*[A, B](d: Database, name = "",): Database[A, B] =
  ## Open another database of a different name in an already-connected on-disk storage location.
  result.env = d.env
  result.dbi = result.open(name)

proc initDatabase*[A, B](filename = "", name = "", maxdbs = 254, size = 10485760): Database[A, B] =
  ## Connect to an on-disk storage location and open a database. If the path does not exist,
  ## a directory will be created.
  createDir(filename)
  result.env = newLMDBEnv(filename, maxdbs)
  discard envSetMapsize(result.env, uint(size))
  result.dbi = result.open(name)

proc compare(a, b: SomeNumber): int =
  if a < b:
    -1
  elif a > b:
    1
  else:
    0

proc compare[N, T](a, b: array[N, T]): int =
  for i in 0..<a.len:
    let r = compare(a[i], b[i])
    if r != 0:
      return r
  0

proc compare[T: object | tuple](a, b: T): int =
  for u, v in fields(a, b):
    let r = compare(u, v)
    if r != 0:
      return r
  0

proc wrapCompare(T: typedesc): auto =
  proc (a, b: ptr Blob): cint {.cdecl.} =
    compare(cast[ptr T](a.mvData)[], cast[ptr T](b.mvData)[]).cint

proc initTransaction*[A, B](d: Database[A, B]): Transaction[A, B] =
  ## Start a transaction from a database.
  ##
  ## Reads and writes on the transaction will reflect the same
  ## point in time and will not be affected by other writes.
  ##
  ## After reads, `reset` must be called on the transaction. After writes,
  ## `commit` must be called to perform all of the writes, or `reset` to perform
  ## none of them.
  ##
  ## .. caution::
  ##     Calling neither `reset` nor `commit` on a transaction can block database access.
  ##     This commonly happens when an exception is raised.
  result.dbi = d.dbi
  result.txn = d.env.newTxn()
  when A isnot string:
    if 0 != setCompare(result.txn, result.dbi, cast[ptr CmpFunc](wrapCompare(A))):
      raise newException(CatchableError, "LimDB could not set compare proc for type" & $A)


proc toBlob*(s: string): Blob =
  ## Convert a string to a chunk of data, key or value, for LMDB
  ##
  ## .. note::
  ##     If you want other data types than a string, implement this for the data type
  result.mvSize = s.len.uint
  result.mvData = s.cstring

template toBlob*(x: SomeNumber | array | tuple | object): Blob =
  ## Convert a string to a chunk of data, key or value, for LMDB
  ##
  ## .. note::
  ##     If you want other data types than a string, implement this for the data type
  Blob(mvSize: sizeof(x).uint, mvData: cast[pointer](x.unsafeAddr))

proc fromBlob*(b: Blob, T: typedesc[string]): string =
  ## Convert a chunk of data, key or value, to a string
  ##
  ## .. note::
  ##     If you want other data types than a string, implement this for the data type
  result = newStringOfCap(b.mvSize)
  result.setLen(b.mvSize)
  copyMem(cast[pointer](result.cstring), cast[pointer](b.mvData), b.mvSize)

proc fromBlob*(b: Blob, T: typedesc[SomeNumber | array | tuple | object]): T =
  ## Convert a chunk of data, key or value, to a string
  ##
  ## .. note::
  ##     If you want other data types than a string, implement this for the data type
  result = cast[ptr T](b.mvData)[]

proc `[]`*[A, B](t: Transaction[A, B], key: A): B =
  # Read a value from a key in a transaction
  var k = key.toBlob
  var d: Blob
  let err = lmdb.get(t.txn, t.dbi, addr(k), addr(d))
  if err == 0:
    result = fromBlob(d, B)
  elif err == lmdb.NOTFOUND:
    raise newException(KeyError, $strerror(err))
  else:
    raise newException(Exception, $strerror(err))

proc `[]=`*[A, B](t: Transaction[A, B], key: A, val: B) {.tags: [Writes].} =
  # Writes a value to a key in a transaction
  var k = key.toBlob
  var v = val.toBlob
  let err = lmdb.put(t.txn, t.dbi, addr(k), addr(v), 0)
  if err == 0:
    return
  elif err == lmdb.NOTFOUND:
    raise newException(KeyError, $strerror(err))
  else:
    raise newException(Exception, $strerror(err))

proc del*[A, B](t: Transaction[A, B], key: A, val: B) {.tags: [Writes].} =
  ## Delete a key-value pair
  # weird lmdb quirk, you delete with both key and value because you can "shadow"
  # a key's value with another put
  var k = key.toBlob
  var v = val.toBlob
  let err = lmdb.del(t.txn, t.dbi, addr(k), addr(v))
  if err == 0:
    return
  elif err == lmdb.NOTFOUND:
    raise newException(KeyError, $strerror(err))
  else:
    raise newException(Exception, $strerror(err))

template del*[A, B](t: Transaction[A, B], key: A) =
  ## Delete a value in a transaction
  ##
  ## .. note::
  ##     LMDB requires you to delete by key and value. This proc fetches
  ##     the value for you, giving you the more familiar interface.
  t.del(key, t[key])

proc hasKey*[A, B](t: Transaction[A, B], key: A): bool =
  ## See if a key exists without fetching any data
  var key = key.toBlob
  var dummyData:Blob
  return 0 == get(t.txn, t.dbi, addr(key), addr(dummyData))

proc contains*[A, B](t: Transaction[A, B], key: A): bool =
  ## Alias for hasKey to support `in` syntax
  hasKey(t, key)

proc commit*[A, B](t: Transaction[A, B]) {.tags: [Concludes].} =
  ## Commit a transaction. This writes all changes made in the transaction to disk.
  t.txn.commit()

proc reset*[A, B](t: Transaction[A, B]) {.tags: [Concludes].} =
  ## Reset a transaction. This throws away all changes made in the transaction.
  ## After only reading in a transaction, reset it as well.
  ##
  ## .. note::
  ##     This is called `reset` because that is a pleasant and familiar term for reverting
  ##     changes. The term differs from LMDB though, under the hood this calles `mdb_abort`,
  ##     not `mdb_reset`- the latter does something else not covered by LimDB.
  t.txn.abort()

proc `[]`*[A, B](d: Database[A, B], key: A): B =
  ## Fetch a value in the database
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  try:
    result = t[key]
  finally:
    t.reset()

proc `[]=`*[A, B](d: Database[A, B], key: A, val: B) =
  ## Set a value in the database
  ##
  ## .. note::
  ##     This inits and commits a transaction under the hood
  let t = d.initTransaction
  try:
    t[key] = val
  except:
    t.reset()
    raise
  t.commit()

proc del*[A, B](d: Database[A, B], key: A, val: B) =
  ## Delete a key-value pair in the database
  ##
  ## .. note::
  ##     This inits and commits a transaction under the hood
  let t = d.initTransaction
  try:
    t.del(key, val)
  except:
    t.reset()
    raise
  t.commit()

proc del*[A, B](d: Database[A, B], key: A) =
  ## Deletes a value in the database
  ##
  ## .. note::
  ##     This inits and commits a transaction under the hood
  ##
  ## .. note::
  ##     LMDB requires you to delete by key and value. This proc fetches
  ##     the value for you, giving you the more familiar interface.
  let t = d.initTransaction
  try:
    t.del(key)
  except:
    t.reset()
    raise
  t.commit()

proc hasKey*[A, B](d: Database[A, B], key: A):bool =
  ## See if a key exists without fetching any data in a transaction
  let t = d.initTransaction
  result = t.hasKey(key)
  t.reset()

template contains*[A, B](d: Database[A, B], key: A):bool =
  ## Alias for hasKey to support `in` syntax in transactions
  hasKey(d, key)

iterator keys*[A, B](t: Transaction[A, B]): A =
  ## Iterate over all keys in a database with a transaction
  let cursor = cursorOpen(t.txn, t.dbi)
  var key:Blob
  var data:Blob
  let err = cursorGet(cursor, addr(key), addr(data), lmdb.FIRST)
  try:
    if err == 0:
      yield fromBlob(key, A)
      while true:
        let err = cursorGet(cursor, addr(key), addr(data), op=NEXT)
        if err == 0:
          yield fromBlob(key, A)
        elif err == lmdb.NOTFOUND:
          break
        else:
          raise newException(Exception, $strerror(err))
  finally:
    cursor.cursorClose

iterator values*[A, B](t: Transaction[A, B]): B =
  ## Iterate over all values in a database with a transaction.
  let cursor = cursorOpen(t.txn, t.dbi)
  var key:Blob
  var data:Blob
  let err = cursorGet(cursor, addr(key), addr(data), lmdb.FIRST)
  try:
    if err == 0:
      yield fromBlob(data, B)
      while true:
        let err = cursorGet(cursor, addr(key), addr(data), op=NEXT)
        if err == 0:
          yield fromBlob(data, B)
        elif err == lmdb.NOTFOUND:
          break
        else:
          raise newException(Exception, $strerror(err))
  finally:
    cursor.cursorClose

iterator mvalues*[A, B](t: Transaction[A, B]): var B {.tags: [Writes].} =
  ## Iterate over all values in a database with a transaction, allowing
  ## the values to be modified.
  let cursor = cursorOpen(t.txn, t.dbi)
  var key:Blob
  var data:Blob
  let err = cursorGet(cursor, addr(key), addr(data), lmdb.FIRST)
  try:
    if err == 0:
      var d: ref string
      new(d)
      d[] = fromBlob(data, B)
      yield d[]
      var mdata = d[].toBlob
      if 0 != cursorPut(cursor, addr(key), addr(mdata), 0):
        raise newException(Exception, $strerror(err))
      while true:
        let err = cursorGet(cursor, addr(key), addr(data), op=NEXT)
        if err == 0:
          var d:ref string
          new(d)
          d[] = fromBlob(data, B)
          yield d[]
          var mdata = d[].toBlob
          if 0 != cursorPut(cursor, addr(key), addr(mdata), 0):
            raise newException(Exception, $strerror(err))
        elif err == lmdb.NOTFOUND:
          break
        else:
          raise newException(Exception, $strerror(err))
  finally:
    cursor.cursorClose

iterator pairs*[A, B](t: Transaction[A, B]): (A, B) =
  ## Iterate over all key-value pairs in a database with a transaction.
  let cursor = cursorOpen(t.txn, t.dbi)
  var key:Blob
  var data:Blob
  try:
    let err = cursorGet(cursor, addr(key), addr(data), lmdb.FIRST)
    if err == 0:
      yield (fromBlob(key, A), fromBlob(data, B))
      while true:
        let err = cursorGet(cursor, addr(key), addr(data), op=NEXT)
        if err == 0:
          yield (fromBlob(key, A), fromBlob(data, B))
        elif err == lmdb.NOTFOUND:
          break
        else:
          raise newException(Exception, $strerror(err))
  finally:
    cursor.cursorClose

iterator mpairs*[A, B](t: Transaction[A, B]): (A, var B) {.tags: [Writes].} =
  ## Iterate over all key-value pairs in a database with a transaction, allowing
  ## the values to be modified.
  let cursor = cursorOpen(t.txn, t.dbi)
  var key:Blob
  var data:Blob
  let err = cursorGet(cursor, addr(key), addr(data), lmdb.FIRST)
  try:
    if err == 0:
      var d: ref B
      new(d)
      d[] = fromBlob(data, B)
      yield (fromBlob(key, A), d[])
      var mdata = d[].toBlob
      if 0 != cursorPut(cursor, addr(key), addr(mdata), 0):
        raise newException(Exception, $strerror(err))
      while true:
        let err = cursorGet(cursor, addr(key), addr(data), op=NEXT)
        if err == 0:
          var d:ref B
          new(d)
          d[] = fromBlob(data, B)
          yield (fromBlob(key, A), d[])
          var mdata = d[].toBlob
          if 0 != cursorPut(cursor, addr(key), addr(mdata), 0):
            raise newException(Exception, $strerror(err))
        elif err == lmdb.NOTFOUND:
          break
        else:
          raise newException(Exception, $strerror(err))
  finally:
    cursor.cursorClose

template len*[A, B](t: Transaction[A, B]): int =
  ## Returns the number of key-value pairs in the database.
  stat(t.txn, t.dbi).msEntries.int

iterator keys*[A, B](d: Database[A, B]): A =
  ## Iterate over all keys in a database.
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  try:
    for key in t.keys:
      yield key
  finally:
    t.reset()

iterator values*[A, B](d: Database[A, B]): B =
  ## Iterate over all values in a database
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  try:
    for value in t.values:
      yield value
  finally:
    t.reset()

iterator pairs*[A, B](d: Database[A, B]): (A, B) =
  ## Iterate over all values in a database
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  try:
    for pair in t.pairs:
      yield pair
  finally:
    t.reset()

iterator mvalues*[A, B](d: Database[A, B]): var B =
  ## Iterate over all values in a database allowing modification
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  try:
    for value in t.mvalues:
      yield value
  finally:
    t.commit()

iterator mpairs*[A, B](d: Database[A, B]): (A, var B) =
  ## Iterate over all key-value pairs in a database allowing the values
  ## to be modified
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  try:
    for k, v in t.mpairs:
      yield (k, v)
  finally:
    t.commit()

proc len*[A, B](d: Database[A, B]): int =
  ## Returns the number of key-value pairs in the database.
  ##
  ## .. note::
  ##     This inits and resets a transaction under the hood
  let t = d.initTransaction
  result = t.len
  t.reset()

proc copy*[A, B](d: Database[A, B], filename: string) =
  ## Copy a database to a different directory. This also performs routine database
  ## maintenance so the resulting file with usually be smaller. This is best performed
  ## when no one is writing to the database directory.
  let err = envCopy(d.env, filename.cstring)
  if err != 0:
    raise newException(Exception, $strerror(err))

template clear*[A, B](t: Transaction[A, B]) =
  ## Remove all key-values pairs from the database, emptying it.
  ##
  ## .. note::
  ##     The size of the database will stay the same on-disk but won't grow until
  ##     more data than was in there before is added. It will shrink if it is copied.
  emptyDb(t.txn, t.dbi)

proc clear*[A, B](d: Database[A, B]) =
  ## Remove all key-values pairs from the database, emptying it.
  ##
  ## .. note::
  ##     This creates and commits a transaction under the hood
  let t = d.initTransaction
  t.clear
  t.commit

template close*[A, B](d: Database[A, B]) =
  ## Close the database directory. This will free up some memory and make all databases
  ## that were created from the same directory unavailable. This is not necessary for many use cases.
  ##
  ## .. note::
  ##     This creates and commits a transaction under the hood
  envClose(d.env)

proc getOrDefault*[A, B](t: Transaction[A, B], key: A):B=
  ## Read a value from a key in a transaction and return the provided default value if
  ## it does not exist
  try:
    result = t[key]
  except KeyError:
    result = ""

proc getOrDefault*[A, B](d: Database[A, B], key: A):B =
  ## Fetch a value in the database and return the provided default value if it does not exist
  let t = d.initTransaction
  try:
    result = t[key]
  except KeyError:
    result = ""
  finally:
    t.reset()

proc hasKeyOrPut*[A, B](t: Transaction[A, B], key: A, val: B): bool =
  ## Returns true if `key` is in the transaction view of the database, otherwise inserts `value`.
  result = key in t
  if not result:
    t[key] = val

proc hasKeyOrPut*[A, B](d: Database[A, B], key: A, val: B): bool =
  ## Returns true if `key` is in the Database, otherwise inserts `value`.
  let t = d.initTransaction
  try:
    result = key in t
    if result:
      t.reset
    else:
      t[key] = val
      t.commit
  except:
    t.reset
    raise

proc getOrPut*[A, B](t: Transaction[A, B], key: A, val: B): B =
  ## Retrieves value at key or enters and returns val if not present
  try:
    result = t[key]
  except KeyError:
    result = val
    t[key] = val

proc getOrPut*[A, B](d: Database[A, B], key: A, val: B): B =
  ## Retrieves value of key as mutable copy or enters and returns val if not present
  let t = d.initTransaction
  try:
    result = t[key]
    t.reset()
  except KeyError:
    result = val
    t[key] = val
    t.commit()

proc pop*[A, B](t: Transaction[A, B], key: A, val: var B): bool =
  ## Delete value in database within transaction. If it existed, return
  ## true and place into `val`
  try:
    val = t[key]
    t.del(key)
    true
  except KeyError:
    false
  except:
    t.reset
    raise

proc pop*[A, B](d: Database[A, B], key: A, val: var B): bool =
  ## Delete value in database. If it existed, return
  ## true and place value into `val`
  let t = d.initTransaction
  try:
    val = t[key]
    t.del(key)
    t.commit
    true
  except KeyError:
    t.reset
    false
  except:
    t.reset
    raise

proc take*[A, B](t: Transaction[A, B], key: A, val: var B): bool =
  ## Alias for pop
  pop(t, key, val)

proc take*[A, B](d: Database[A, B], key: A, val: var B): bool =
  ## Alias for pop
  pop(d, key, val)


# keeping a note of our thinking in not implementing some procs from tables
#
# smallest, largest    would need to be done low level in C code for efficiency
#                      to make sense, not important enough for that
# inc, dec             want to support native ints and floats first, incing strings irks me
# indexBy              seems a bit specialized, you can always use a loop
# toLimDB              cool way to init but db needs path or existing db to init, create normal table
#                      with toTable and add values instead
# merge                specialized, only for counttable.
# mgetOrPut            Returns mutable value, can't directly write memory (yet), give getOrPut instead
# withValue            Also returns mutable value, unsure how useful it is

when NimMajor >= 1 and NimMinor >= 4:

  macro callsTaggedAs(p:proc, tag: string):untyped =
    for t in getTagsList(p):
      if t.eqIdent(tag):
        return newLit(true)
    newLit(false)

  template with*(db: Database, body: untyped) =
    ## Execute a block of code in a transaction. Commit if there are any writes, otherwise reset.
    ##
    ## .. note::
    ##     Available using Nim 1.4 and above
    block:
      let t {.inject.} = db.initTransaction
      try:
        body
        proc bodyproc() {.compileTime.} =
          body
        static:
          when callsTaggedAs(bodyproc, "Concludes"):
            raise newException(LimDefect, "Transaction in a `with` block are automatically committed or reset at the end of the block. Use `initTransaction` to do it manually.")
        when callsTaggedAs(bodyproc, "Writes"):
          t.commit
        else:
          t.reset
      except CatchableError:
        t.reset
        raise


