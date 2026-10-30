import Model;

using StringTools;

// a C type as hxmc passes it in a message
enum HType {
	HPrim(pack:Array<String>, name:String); // Int, Float, Bool, hxmc.I64, hxmc.unsafe.Ptr, ...
	HVoid;
	HClass(name:String, nullable:Bool, args:Array<HType>); // args: a lightweight generic's (none: its defaults)
	HParam(name:String, nullable:Bool); // a type parameter of the class (or of a static method, the class's)
	HId(nullable:Bool); // id: hxmc.objc.Id, any object
	HProto(name:String, nullable:Bool); // id<P>: the protocol's interface
	HCF(name:String, nullable:Bool); // an object of C (CGColorRef): an extern class implementing Id
	HFun(args:Array<HType>, ret:HType, nullable:Bool); // a block: a Haxe function
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
	public static var CSTRING = HPrim(["hxmc", "unsafe"], "CString");

	static var QUALIFIERS = [
		"_Nonnull", "_Nullable", "_Nullable_result", "_Null_unspecified", "__kindof", "const", "volatile", "__strong", "__weak", "__unsafe_unretained",
		"__autoreleasing", "restrict", "__restrict", "struct", "enum", "union"
	];

	var r:Reader;
	var gen:Gen;

	// the type parameters in scope: as the member's declaration names them
	// (a category's own names) => the class's
	public var scope = new Map<String, String>();
	// the class's own type arguments: its parameters (instancetype)
	public var selfArgs:Array<HType> = [];

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

	// a block's spelling, `R (^ _Nullable)(A, B)`: a function (A, B) -> R,
	// nullable as the caret's annotation says
	function block(d:String, q:String, self:String, depth:Int):HType {
		var i = d.indexOf("(^");
		var close = matching(d, i);
		if (close < 0) throw new Skip("block type", d);
		var inner = d.substring(i + 2, close);
		var rest = d.substr(close + 1).trim();
		if (!rest.startsWith("(")) throw new Skip("block type", d);
		var pend = matching(rest, 0);
		if (pend < 0 || rest.substr(pend + 1).trim() != "") throw new Skip("block type", d);
		var ret = d.substr(0, i).trim();
		var params = splitTop(rest.substring(1, pend));
		if (params.length == 1 && params[0] == "void") params = [];
		if (params.indexOf("...") >= 0) throw new Skip("variadic block");
		var args = [for (p in params) map({qual: p, desugared: p}, self, false, depth + 1)];
		for (a in args)
			if (a == HVoid) throw new Skip("block type", d);
		var r = map({qual: ret, desugared: ret}, self, false, depth + 1);
		return HFun(args, r, nullable(inner) || nullable(q));
	}

	// the index of the parenthesis closing the one at s[open], or -1
	static function matching(s:String, open:Int):Int {
		var depth = 0;
		for (k in open...s.length)
			switch s.charAt(k) {
				case "(": depth++;
				case ")":
					depth--;
					if (depth == 0) return k;
				case _:
			}
		return -1;
	}

	// a parameter list split at its top-level commas
	public static function splitTop(s:String):Array<String> {
		var r = [], depth = 0, start = 0;
		for (k in 0...s.length)
			switch s.charAt(k) {
				case "(" | "<" | "[": depth++;
				case ")" | ">" | "]": depth--;
				case "," if (depth == 0):
					r.push(s.substring(start, k).trim());
					start = k + 1;
				case _:
			}
		var last = s.substr(start).trim();
		if (last != "" || r.length > 0) r.push(last);
		return r;
	}

	// the content of the first <...> after `name` in s, or null
	static function angles(s:String, name:String):Null<String> {
		var at = new EReg("\\b" + name + "\\s*<", "");
		if (!at.match(s)) return null;
		var open = at.matchedPos().pos + at.matchedPos().len - 1, depth = 0;
		for (k in open...s.length)
			switch s.charAt(k) {
				case "<": depth++;
				case ">":
					depth--;
					if (depth == 0) return s.substring(open + 1, k);
				case _:
			}
		return null;
	}

	// a lightweight generic's type arguments (`NSArray<NSString *> *`), as
	// spelled or desugared; none (its defaults) where they are not objects or
	// not as many as its parameters (`NSView<NSTextInputClient>`: protocols)
	function typeArgs(name:String, t:CType, self:String, depth:Int):Array<HType> {
		var n = gen.typeParamCount(name);
		if (n == 0) return [];
		var a = angles(t.qual, name);
		if (a == null) a = angles(t.desugared, name);
		if (a == null) return [];
		var spelled = splitTop(a);
		if (spelled.length != n) return [];
		var r = [];
		for (s in spelled) {
			var h = try typeArg({qual: s, desugared: s}, self, depth + 1) catch (_:Skip) null;
			if (h == null) return [];
			r.push(h);
		}
		return r;
	}

	// a type argument (or a bound): an object type, never null; `id` any object
	public function typeArg(t:CType, self:String, depth = 0):Null<HType> {
		return switch map(t, self, false, depth) {
			case HClass(n, _, a): HClass(n, false, a);
			case HProto(n, _): HProto(n, false);
			case HParam(n, _): HParam(n, false);
			case HId(_): HId(false);
			case HCF(n, _): HCF(n, false);
			case _: null;
		}
	}

	// `self`: the class whose declaration this is (instancetype)
	public function map(t:CType, self:String, inStruct = false, depth = 0):HType {
		if (depth > 16) throw new Skip("typedef cycle", t.qual + " = " + t.desugared);
		if (isInstancetype(t)) return HClass(self, nullable(t.qual), selfArgs);
		// a type parameter (`ObjectType`, `__kindof KeyType`): an id
		var first = firstName(t.qual);
		if (scope.exists(first) && t.qual.indexOf("*") < 0 && t.qual.indexOf("(^") < 0) return HParam(scope.get(first), nullable(t.qual));
		// SEL desugars to a pointer to a struct
		if (t.qual.indexOf("*") < 0 && firstName(t.qual) == "SEL") return HPrim(["hxmc", "objc"], "Selector");
		// CFTypeRef (`const void *`): any object
		if (t.qual.indexOf("*") < 0 && first == "CFTypeRef") {
			if (inStruct) return PTR;
			gen.markCF();
			return HId(nullable(t.qual));
		}
		var d = t.desugared;
		if (d.indexOf("__attribute__") >= 0) throw new Skip("vector type");
		if (stripAngles(d).indexOf("(^") >= 0) {
			if (inStruct) return PTR;
			// (as spelled, where it is: its type parameters and arguments)
			return block(stripAngles(t.qual).indexOf("(^") >= 0 ? t.qual : d, t.qual, self, depth);
		}
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
		// a C string (`char *` is a buffer: Ptr)
		if (stars == 1 && tag == "" && name == "char" && ws.indexOf("const") >= 0 && ws.indexOf("const") < ws.indexOf("*")) return CSTRING;
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
		// a pointer to a struct that is an object (CF_BRIDGED_TYPE: CGColorRef,
		// CFStringRef), the typedef that names it as spelled
		if (stars == 1 && tag == "struct" && !inStruct) {
			var constant = ws.indexOf("const") >= 0 && ws.indexOf("const") < ws.indexOf("*");
			var h = gen.useCF(name, constant, first, nullable(t.qual));
			if (h != null) return h;
		}
		if (stars == 1) {
			if (tag != "" || builtin(name) != null || name == "id" || name == "Class" || name == "SEL" || name == "Protocol") return PTR;
			// an Objective-C object
			if (inStruct) return PTR;
			if (!gen.isClass(name)) {
				if (!r.classes.exists(name)) return PTR; // a pointer to a type parameter (`ObjectType const *`)
				throw new Skip("class not defined or unavailable", d);
			}
			return gen.useClass(name, nullable(t.qual), typeArgs(name, t, self, depth));
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
			case "id":
				if (inStruct) return PTR;
				// id<P, ...>: the protocol's interface
				var list = ~/\bid\s*<([^>]*)>/;
				var h = list.match(d) || list.match(t.qual) ? gen.useProtocol([for (p in list.matched(1).split(",")) p.trim()], nullable(t.qual)) : null;
				h != null ? h : HId(nullable(t.qual));
			case "Class": inStruct ? PTR : HPrim(["hxmc", "objc"], "ObjCClass");
			case "SEL": HPrim(["hxmc", "objc"], "Selector");
			case "long double": throw new Skip("long double");
			case "__int128" | "unsigned __int128": throw new Skip("128-bit integer");
			case _:
				if (r.classes.exists(name)) throw new Skip("Objective-C object by value");
				throw new Skip("unsupported type", d);
		}
	}
}
