// hxmc-objc-extern-gen: Haxe extern declarations of the macOS SDK's Objective-C
// classes for hxmc (its docs/interop.md, "Objective-C"), from clang's AST of
// `#import <AppKit/AppKit.h>`.
//
//   objc-extern-gen <out-dir> [--json ast.json --text ast.txt [--macros macros.txt]] [--frameworks Foundation,AppKit,...] [--keep-dumps] [--check]
//
// Without --json/--text it runs clang (twice: the JSON dump for the
// declarations, the text dump for their availability, which the JSON dump
// does not spell out; and the preprocessor, for the constant macros), into <out-dir>/.clang, deleted after unless
// --keep-dumps. A framework inside another (HIServices) is read from its
// outer framework's header. --check also writes <out-dir>/ObjcExternsCheck.hx, a
// program naming every generated type.
class Main {
	static function stamp(what:String, t0:Float):Float {
		var t = haxe.Timer.stamp();
		Sys.println('$what: ${Math.round((t - t0) * 100) / 100} s');
		return t;
	}

	static function shell(cmd:String) {
		if (Sys.command("/bin/sh", ["-c", cmd]) != 0) throw 'failed: $cmd';
	}

	// the umbrella header that declares framework `f`: its own, or its outer
	// framework's for a sub-framework (HIServices: ApplicationServices)
	static function umbrella(sdk:String, f:String):String {
		var dir = sdk + "/System/Library/Frameworks";
		if (!sys.FileSystem.exists('$dir/$f.framework'))
			for (u in sys.FileSystem.readDirectory(dir))
				if (sys.FileSystem.exists('$dir/$u/Frameworks/$f.framework')) {
					var name = haxe.io.Path.withoutExtension(u);
					return '<$name/$name.h>';
				}
		return '<$f/$f.h>';
	}

	static function main() {
		var args = Sys.args();
		var out:Null<String> = null, json:Null<String> = null, text:Null<String> = null, macrosFile:Null<String> = null, check = false, keep = false;
		var scope = ["Foundation", "AppKit", "CoreGraphics", "CoreText", "QuartzCore", "UniformTypeIdentifiers"];
		var i = 0;
		while (i < args.length) {
			switch args[i] {
				case "--json": json = args[++i];
				case "--text": text = args[++i];
				case "--macros": macrosFile = args[++i];
				case "--frameworks": scope = args[++i].split(",");
				case "--check": check = true;
				case "--keep-dumps": keep = true;
				case a: out = a;
			}
			i++;
		}
		if (out == null) {
			Sys.println("usage: objc-extern-gen <out-dir> [--json ast.json --text ast.txt [--macros macros.txt]] [--frameworks Foundation,AppKit,...] [--keep-dumps] [--check]");
			Sys.exit(1);
		}
		sys.FileSystem.createDirectory(out);
		var t = haxe.Timer.stamp();
		var tmp = out + "/.clang", ran = json == null || text == null;
		if (ran) {
			sys.FileSystem.createDirectory(tmp);
			shell('xcrun --show-sdk-path > $tmp/sdk-path');
			var sdk = StringTools.trim(sys.io.File.getContent('$tmp/sdk-path'));
			sys.io.File.saveContent(tmp + "/sdk.m", [for (f in scope) '#import ${umbrella(sdk, f)}\n'].join(""));
			json = tmp + "/ast.json";
			text = tmp + "/ast.txt";
			var cc = "clang -fsyntax-only -x objective-c";
			shell('$cc -Xclang -ast-dump=json $tmp/sdk.m > $json');
			shell('$cc -Xclang -ast-dump -fno-color-diagnostics $tmp/sdk.m > $text');
			macrosFile = tmp + "/macros.txt";
			shell('clang -E -dD -x objective-c $tmp/sdk.m > $macrosFile');
			t = stamp("clang (json and text dumps)", t);
		}
		var avail = new Avail();
		avail.read(text);
		t = stamp("availability (text dump)", t);
		var root:Dynamic = haxe.Json.parse(sys.io.File.getContent(json));
		t = stamp("haxe.Json.parse", t);
		var reader = new Reader(avail);
		reader.read(root);
		root = null;
		if (ran && !keep) {
			for (f in sys.FileSystem.readDirectory(tmp))
				sys.FileSystem.deleteFile('$tmp/$f');
			sys.FileSystem.deleteDirectory(tmp);
		}
		t = stamp("read", t);
		var gen = new Gen(reader, scope);
		if (macrosFile != null) {
			var ms = new Macros();
			ms.read(macrosFile);
			ms.addEnums(reader.enums);
			gen.macros = ms;
			t = stamp("macros", t);
		}
		gen.prepare();
		gen.closure();
		var modules = gen.write(out);
		t = stamp("generate", t);

		function report(title:String, m:Map<String, Int>) {
			Sys.println(title + ":");
			var ks = [for (k in m.keys()) k];
			ks.sort((a, b) -> m.get(b) - m.get(a));
			for (k in ks)
				Sys.println('  ${m.get(k)}\t$k');
		}
		var fws = new Map<String, Int>();
		for (m in modules) {
			var p = m.split(".")[0];
			fws.set(p, (fws.exists(p) ? fws.get(p) : 0) + 1);
		}
		report("modules by package", fws);
		report("generated", gen.count);
		report("skipped", gen.skipped);

		var b = new StringBuf();
		for (k => v in gen.details) {
			b.add(k + ":\n");
			for (x in v)
				b.add("  " + x + "\n");
		}
		sys.io.File.saveContent(out + "/skipped.txt", b.toString());

		if (check) {
			var b = new StringBuf();
			b.add("// Generated: names every module of the externs, for the type checker.\n");
			b.add("class ObjcExternsCheck {\n\tstatic function main() {\n\t\tif (Sys.args().length > 1000) {\n");
			var k = 0;
			for (m in modules)
				b.add('\t\t\tvar v${k++}:$m = cast null;\n');
			b.add("\t\t}\n\t}\n}\n");
			sys.io.File.saveContent(out + "/ObjcExternsCheck.hx", b.toString());
		}
	}
}
