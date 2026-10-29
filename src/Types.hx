import Model;

using StringTools;

// a C type as hxmc passes it in a message
enum HType {
	HPrim(pack:Array<String>, name:String); // Int, Float, Bool, hxmc.I64, hxmc.unsafe.Ptr, ...
	HVoid;
	HClass(name:String, nullable:Bool);
	HStruct(r:RecordInfo);
	HEnum(e:EnumInfo);
}

// a member left out: why
class Skip {
	public var reason:String;
	public var what:String;

	public function new(reason, what = "") {
		this.reason = reason;
		this.what = what;
	}
}

// C types to Haxe types (docs/interop.md, "Objective-C": the types a message passes)
class Types {
	public static var I64 = HPrim(["hxmc"], "I64");
	public static var PTR = HPrim(["hxmc", "unsafe"], "Ptr");
	public static var INT = HPrim([], "Int");

	static var QUALIFIERS = [
		"_Nonnull", "_Nullable", "_Nullable_result", "_Null_unspecified", "__kindof", "const", "volatile", "__strong", "__weak", "__unsafe_unretained",
		"__autoreleasing", "restrict", "__restrict", "struct", "enum", "union"
	];

	var r:Reader;
	var gen:Gen;

	public function new(r, gen) {
		this.r = r;
		this.gen = gen;
	}

	// an `id` of nil allowed: an explicit _Nullable (unannotated types, of
	// headers not audited for nullability, as Swift's implicitly unwrapped ones)
	public static function nullable(q:String):Bool {
		var s = q.trim();
		return s.endsWith("_Nullable") || s.endsWith("_Nullable_result");
	}

	public static function isInstancetype(t:CType):Bool
		return t.qual.trim().startsWith("instancetype");

	// without <...> (generics, protocol lists)
	static function stripAngles(s:String):String {
		var b = new StringBuf(), depth = 0;
		for (i in 0...s.length) {
			var c = s.fastCodeAt(i);
			if (c == "<".code) depth++;
			else if (c == ">".code) depth--;
			else if (depth == 0) b.addChar(c);
		}
		return b.toString();
	}

	static function words(s:String):Array<String>
		return [for (w in s.replace("*", " * ").split(" ")) if (w != "") w];

	// the first identifier of a type's spelling, after its qualifiers
	static function firstName(q:String):String {
		for (w in words(stripAngles(q)))
			if (QUALIFIERS.indexOf(w) < 0) return w;
		return "";
	}

	public static function builtin(base:String):Null<HType>
		return switch base {
			case "void": HVoid;
			case "bool" | "_Bool": HPrim([], "Bool");
			case "char" | "signed char": HPrim(["hxmc", "unsafe"], "Int8");
			case "unsigned char": HPrim(["hxmc", "unsafe"], "UInt8");
			case "short": HPrim(["hxmc", "unsafe"], "Int16");
			case "unsigned short": HPrim(["hxmc", "unsafe"], "UInt16");
			case "int" | "unsigned int": INT;
			case "long" | "unsigned long" | "long long" | "unsigned long long": I64;
			case "float": HPrim(["hxmc", "unsafe"], "Float32");
			case "double": HPrim([], "Float");
			case _: null;
		}

	// `self`: the class whose declaration this is (instancetype)
	public function map(t:CType, self:String, inStruct = false, depth = 0):HType {
		if (depth > 16) throw new Skip("typedef cycle", t.qual + " = " + t.desugared);
		if (isInstancetype(t)) return HClass(self, nullable(t.qual));
		// SEL desugars to a pointer to a struct
		if (t.qual.indexOf("*") < 0 && firstName(t.qual) == "SEL") return HPrim(["hxmc", "objc"], "Selector");
		var d = t.desugared;
		if (d.indexOf("__attribute__") >= 0) throw new Skip("vector type");
		if (d.indexOf("(^") >= 0) return PTR; // a block: for now
		var anonymous = d.indexOf("(unnamed") >= 0 || d.indexOf("(anonymous") >= 0;
		if (anonymous) {
			if (d.trim().endsWith("*")) return PTR;
			var td = r.typedefs.get(firstName(t.qual));
			if (td == null || td.tagId == null) throw new Skip("anonymous type");
			var e = r.enumsById.get(td.tagId);
			if (e != null) return gen.useEnum(e);
			var rec = r.records.get(td.tagId);
			if (rec != null) return gen.useStruct(rec);
			throw new Skip("anonymous type");
		}
		if (d.indexOf("(*") >= 0 || d.indexOf("(") >= 0) throw new Skip("function pointer");
		if (d.indexOf("[") >= 0) throw new Skip("C array");
		var plain = stripAngles(d);
		var ws = words(plain);
		var stars = 0, base = [], tag = "";
		for (w in ws) {
			if (w == "*") stars++;
			else if (w == "struct" || w == "union" || w == "enum") tag = w;
			else if (QUALIFIERS.indexOf(w) < 0) base.push(w);
		}
		var name = base.join(" ");
		if (stars >= 2) return PTR;
		// clang desugars only a sugared outermost type (`NSPoint *` stays): typedefs
		var td = tag == "" && ["id", "Class", "SEL", "Protocol", "instancetype"].indexOf(name) < 0 ? r.typedefs.get(name) : null;
		if (td != null && !gen.isClass(name)) {
			if (stars == 1) return PTR;
			if (td.tagId != null) {
				var e = r.enumsById.get(td.tagId);
				if (e != null) return gen.useEnum(e);
				var rec = r.records.get(td.tagId);
				if (rec != null) return gen.useStruct(rec);
			}
			if (td.type.desugared == name) throw new Skip("opaque typedef", name);
			return map({qual: t.qual, desugared: td.type.desugared}, self, inStruct, depth + 1);
		}
		if (stars == 1) {
			if (tag != "" || builtin(name) != null || name == "id" || name == "Class" || name == "SEL" || name == "Protocol") return PTR;
			// an Objective-C object
			if (inStruct) return PTR;
			if (!gen.isClass(name)) {
				if (!r.classes.exists(name)) return PTR; // a pointer to a type parameter (`ObjectType const *`)
				throw new Skip("class not defined or unavailable", d);
			}
			return gen.useClass(name, nullable(t.qual));
		}
		switch tag {
			case "struct":
				var rec = r.recordsByTag.get(name);
				if (rec == null) throw new Skip("struct not defined");
				return gen.useStruct(rec);
			case "union":
				throw new Skip("union");
			case "enum":
				var e = gen.enumNamed(name);
				if (e == null) throw new Skip("enum not defined");
				return gen.useEnum(e);
			case _:
		}
		var b = builtin(name);
		if (b != null) return b;
		return switch name {
			case "id": inStruct ? PTR : gen.useClass("NSObject", nullable(t.qual));
			case "Class": PTR;
			case "SEL": HPrim(["hxmc", "objc"], "Selector");
			case "long double": throw new Skip("long double");
			case "__int128" | "unsigned __int128": throw new Skip("128-bit integer");
			case _:
				if (r.classes.exists(name)) throw new Skip("Objective-C object by value");
				throw new Skip("unsupported type", d);
		}
	}
}
