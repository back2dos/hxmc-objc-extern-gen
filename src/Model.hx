// What the generator reads from clang's AST: declarations only (never the
// headers' comments, Apple's SDK terms).

// a C type as clang spells it: with its sugar (typedef names, nullability)
// and desugared
typedef CType = {qual:String, desugared:String};

// where a declaration is: its framework (the innermost .framework of its
// header's path; "objc" for libobjc's headers, "" for other C headers), the
// library a Mach-O load names, and the header's name without ".h"
class Origin {
	public var framework:String;
	public var lib:Null<String>; // a library other than /System/Library/Frameworks/X.framework/X
	public var header:String;

	public function new(framework, lib, header) {
		this.framework = framework;
		this.lib = lib;
		this.header = header;
	}

	public static function of(path:String):Origin {
		var header = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path));
		var i = path.lastIndexOf(".framework/");
		if (i >= 0) {
			var s = path.lastIndexOf("/", i - 1);
			var name = path.substring(s + 1, i);
			// a framework inside another one (CoreServices' CarbonCore): its own path
			var outer = path.substring(0, s).indexOf(".framework/");
			var lib = outer >= 0 ? path.substring(path.indexOf("/System/Library/Frameworks/"), i) + ".framework/" + name : null;
			return new Origin(name, lib, header);
		}
		if (path.indexOf("/usr/include/objc/") >= 0) return new Origin("objc", "/usr/lib/libobjc.A.dylib", header);
		return new Origin("", null, header);
	}
}

// availability on macOS (Avail reads it from clang's text dump: the JSON
// dump names no platform)
typedef Availability = {unavailable:Bool, deprecated:Null<String>};

typedef Param = {name:String, type:CType};

// a lightweight generic's parameter (`ObjectType`, bound by `id`)
typedef TypeParamInfo = {name:String, bound:CType, covariant:Bool};

enum MemberKind {
	KMethod(ret:CType, params:Array<Param>, variadic:Bool);
	KProperty(type:CType, readonly:Bool, getter:Null<String>, setter:Null<String>);
}

class Member {
	public var name:String; // the selector, or the property's name
	public var isStatic:Bool;
	public var kind:MemberKind;
	public var optional:Bool; // a protocol's @optional
	public var avail:Null<Availability>;
	public var origin:Origin; // of the container declaring it (a category's)
	public var designated:Bool = false;
	public var at:Int = -1; // the offset of its declaration in its file (a protocol's: @optional)
	public var scope:Array<String> = []; // the type parameters' names where it is declared (a category's own)

	public function new(name, isStatic, kind, origin) {
		this.name = name;
		this.isStatic = isStatic;
		this.kind = kind;
		this.origin = origin;
		this.optional = false;
	}
}

class Container {
	public var name:String; // a class's or protocol's
	public var superName:Null<String>;
	public var protocols:Array<String> = [];
	public var members:Array<Member> = [];
	public var origin:Null<Origin>; // of its definition
	public var span:Int = -1; // the definition's extent (forward declarations are short)
	public var avail:Null<Availability>;
	public var typeParams:Array<TypeParamInfo> = []; // a class's
	public var superArgs:Null<Array<String>>; // the superclass's type arguments, as spelled

	public function new(name)
		this.name = name;
}

typedef EnumConst = {name:String, value:haxe.Int64, avail:Null<Availability>};

class EnumInfo {
	public var id:String;
	public var name:Null<String>; // or a typedef's for an anonymous enum
	public var underlying:Null<CType>;
	public var consts:Array<EnumConst> = [];
	public var options:Bool = false; // NS_OPTIONS (flag_enum)
	public var origin:Origin;
	public var avail:Null<Availability>;

	public function new(id, name, origin) {
		this.id = id;
		this.name = name;
		this.origin = origin;
	}
}

typedef RecordField = {name:String, type:CType, bitfield:Bool};

class RecordInfo {
	public var id:String;
	public var tag:String; // the struct's tag (may be empty)
	public var name:String; // its Haxe name: the tag, or a typedef's for `_NSRange` and anonymous ones
	public var union:Bool;
	public var fields:Array<RecordField> = [];
	public var complete:Bool;
	public var origin:Origin;

	public function new(id, tag, union, origin) {
		this.id = id;
		this.tag = tag;
		this.name = tag;
		this.union = union;
		this.origin = origin;
	}
}

typedef Typedef = {name:String, type:CType, tagId:Null<String>};
