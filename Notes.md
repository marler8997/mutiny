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
