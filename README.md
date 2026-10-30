# hxmc-objc-extern-gen

> **Experimental.** A work in progress, made to find out what the declarations should look like. Expect the output, the rules behind it and the tool itself to change.

Generates Haxe extern declarations of the macOS SDK's Objective-C APIs (Foundation and AppKit so far) for [hxmc](https://github.com/benmerckx/hxmc)'s Objective-C interop, from clang's AST of the SDK's headers.

Using the generated declarations needs hxmc's Objective-C interop, which is not published yet. The generator itself is plain Haxe and builds with the published hxmc.

## Use

macOS with Xcode's command line tools (clang) and node:

```sh
npm install
npm run gen        # builds bin/objc-extern-gen, writes out/
```

`bin/objc-extern-gen <out-dir> [--frameworks Foundation,AppKit] [--check]` writes a package per framework (`appkit.NSView`, `foundation.NSString`, ...), one module per class or protocol, `skipped.txt` (what was left out and why) and, with `--check`, `ObjcExternsCheck.hx`, a program naming every type. `--json` and `--text` read existing dumps instead of running clang.

The generated declarations are derived from Apple's headers: they are not part of this repository, and they carry none of the headers' comments.

## Rules

What the declarations make of the headers (decided in [#1](https://github.com/back2dos/hxmc-objc-extern-gen/issues/1)):

- **Properties** are `var x(get, set)`. One readonly in a class and readwrite in a subclass (`NSPanel.floatingPanel`) gets only its setter in the subclass (`panel.set_floatingPanel(true)`): Haxe does not let a subclass redefine the variable, and a setter on the superclass would accept calls that fail at run time.
- **Informal protocols**, categories of `NSObject` that name methods for other objects to implement (`controlTextDidChange:`, `validateMenuItem:`), are left out (`skipped.txt` lists them): those outside NSObject's own headers that a formal protocol of their name supersedes, or whose methods all take their sender first (named `sender`, a notification, or an object of the class the selector's first piece names).
- **Names**: enum constants lose their common prefix (`NSWindowStyleMask.Titled`); types are non-null unless `_Nullable`. Methods whose selectors begin alike are `overload`s of the first piece where their parameters' types differ (`systemFontOfSize(size)`, `systemFontOfSize(size, weight)`), the others named by their pieces joined. `@:deprecated` carries no message.
- **Protocols** are extern interfaces (`@:hxmc.objc("Name")`, extending the protocols they adopt), named `NameProtocol` when a class has the name (`NSObjectProtocol`). Optional members are `@:optional`: a Haxe class implementing the protocol may leave them out, and Objective-C then sees no such method. A protocol's methods are never overloads (a Haxe class implementing one declares none): a method keeps its selector's first piece when no other method of the protocol's family begins with it (or it is that piece alone), else its pieces are joined (`parserFoundCharacters` for `parser:foundCharacters:`). `id<P>` is `P`. A class implements the protocols it adopts, under the protocols' names (a method the class names otherwise gets a field of the protocol's name too, sending the same selector); one whose names the class gives other members is left out (`skipped.txt`). Which methods are `@optional` is read from the protocol's header, which clang's dumps do not tell.
- **Lightweight generics** are type parameters bound to `hxmc.objc.Id` (any object, which the root classes and protocols extend) and defaulting to it: `NSArray<ObjectType:Id = Id>`, `NSArray<NSString *> *` is `NSArray<NSString>`, a bare `NSArray *` `NSArray<Id>`. A superclass's arguments are read from the declaration (`NSLayoutXAxisAnchor extends NSLayoutAnchor<NSLayoutXAxisAnchor>`). A static method declares the class's parameters it uses (`alloc<ObjectType:Id>()`). Haxe's parameters are invariant: a covariant class (the immutable collections) has `upcast`, widening its elements to a supertype (`NSArray.upcast(subviews):NSArray<NSObject>`).
- **Options** (`NS_OPTIONS`) are enum abstracts with `|` and `&`, `None` (no bits) and `has` (all the given bits set: `o.has(WithoutChanges)`).
- **Packages**: one per framework; Core Graphics' types (`CGRect`, `CGPoint`, `CGSize`, ...) are in `coregraphics`.
- **Types**: `id` is `hxmc.objc.Id` (any object: messages to it need a cast or `Std.downcast` first), `id<P>` `P`. `const char *` is `hxmc.unsafe.CString`, other pointers `Ptr`. A block is a Haxe function (`completionHandler:(Null<NSData>, Null<NSURLResponse>, Null<NSError>) -> Void`), a block taking or returning blocks too (`performAsynchronousFileAccessUsingBlock(block:(() -> Void) -> Void)`), `Null<...>` when `_Nullable`.
- **Redeclarations**: a class redeclares `alloc` and the initializers it inherits for their result's type; not `self`, `new` or `allocWithZone:`. `retain`, `release` and `autorelease` are left out (memory is the compiler's).

## License

MIT
