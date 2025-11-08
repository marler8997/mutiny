## The Stack

Most everything on the stack will be prefixed by a "type" followed by a value of variable size based on the type.  The exception to this is symbols, which are started by a symbol id (usize pointing to where in the text the id appears) and then a "previous symbol address" (except for the first entry which has none).  After that it's a normal type/value like everywhere else.


- symbol_id: usize  (pointer to where the symbol id is in text)
- [ no previous_addr like subsequent symbols will have ]
- next_symbol_type: Type
- next_symbol_value: (size based on type)
--------------
- symbol_id: usize  (pointer to where the symbol id is in text)
- previous_addr: Addr (address of previous symbol id for reverse stack walking)
- next_symbol_type: Type
- next_symbol_value: (size based on type)
--------------
- symbol_id: usize  (pointer to where the symbol id is in text)
- previous_addr: Addr (address of previous symbol id for reverse stack walking)
- next_symbol_type: Type
- next_symbol_value: (size based on type)
--------------
....
--------------


## Restriction on calling fields on assemblies

> can't call fields on an assembly directly, call @Class first

We could support calling assembly fields directly by inferring that
the leaf identifier is a static method, parent is a class and everything
else is namespace, but, this is intentionally not supported for now.

Supporting this would make another way of doing the same thing.
It would be more "streamlined" if you only ever call this static
function once, but, for now I'd like to encourage just the one way which
ends up being more streamlined if you have to call it multiple times.

```
mscorlib.System.Console.WriteLine("hello")
mscorlib.System.Console.WriteLine("there")
```
VS
```
Console = @Class(mscorlib.System.Console)
Console.WriteLine("hello")
Console.WriteLine("there")
```
