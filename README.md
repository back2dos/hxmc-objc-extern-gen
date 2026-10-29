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

## License

MIT
