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

`bin/objc-extern-gen <out-dir> [--frameworks Foundation,AppKit] [--check]` writes a package per framework (`appkit.NSView`, `foundation.NSString`, ...), one module per class, `skipped.txt` (what was left out and why) and, with `--check`, `ObjcExternsCheck.hx`, a program naming every type. `--json` and `--text` read existing dumps instead of running clang.

The generated declarations are derived from Apple's headers: they are not part of this repository, and they carry none of the headers' comments.

## Rules

What the declarations make of the headers (decided in [#1](https://github.com/back2dos/hxmc-objc-extern-gen/issues/1)):

- **Properties** are `var x(get, set)`. One readonly in a class and readwrite in a subclass (`NSPanel.floatingPanel`) gets only its setter in the subclass (`panel.set_floatingPanel(true)`): Haxe does not let a subclass redefine the variable, and a setter on the superclass would accept calls that fail at run time.
- **Informal protocols**, categories of `NSObject` that name methods for other objects to implement (`controlTextDidChange:`, `validateMenuItem:`), are left out (`skipped.txt` lists them): those outside NSObject's own headers that a formal protocol of their name supersedes, or whose methods all take their sender first (named `sender`, a notification, or an object of the class the selector's first piece names).
- **Names**: enum constants lose their common prefix (`NSWindowStyleMask.Titled`); types are non-null unless `_Nullable`. Methods whose selectors begin alike are `overload`s of the first piece where their parameters' types differ (`systemFontOfSize(size)`, `systemFontOfSize(size, weight)`), the others named by their pieces joined. `@:deprecated` carries no message.
- **Packages**: one per framework; Core Graphics' types (`CGRect`, `CGPoint`, `CGSize`, ...) are in `coregraphics`.
- **Types**: `const char *` is `hxmc.unsafe.CString`, other pointers `Ptr`.
- **Redeclarations**: a class redeclares `alloc` and the initializers it inherits for their result's type; not `self`, `new` or `allocWithZone:`. `retain`, `release` and `autorelease` are left out (memory is the compiler's).

## License

MIT
