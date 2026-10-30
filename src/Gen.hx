import Model;
import Types;
import haxe.macro.Expr;

using StringTools;

// a member as declared in Haxe: what subclasses redeclare (instancetype) or
// must not collide with
typedef FieldRec = {
	name:String,
	sel:String,
	isStatic:Bool,
	params:Array<{name:String, t:HType}>,
	ret:HType,
	selMeta:Bool, // the selector does not follow from the names
	lib:Null<Origin>, // a category's of another library
	deprecated:Null<String>,
	instancetype:Bool,
	accessor:Bool,
	isOverload:Bool // one of several methods of its name
}

// a protocol's members as its interface declares them (those of the
// protocols it extends first): names unique in the whole family, no overloads
// (a Haxe class implementing it declares none), optional ones @:optional
typedef ProtoMethod = {rec:FieldRec, optional:Bool, owner:String};
typedef ProtoProp = {name:String, objcName:String, h:HType, readonly:Bool, get:FieldRec, set:Null<FieldRec>, optional:Bool, owner:String};
typedef ProtoInfo = {methods:Array<ProtoMethod>, props:Array<ProtoProp>, names:Map<String, Bool>, sels:Map<String, Bool>};

// what a class sees of itself and its superclasses
class ClassState {
	public var adopted = new Map<String, Bool>(); // the protocols implemented, inherited too
	public var names = new Map<String, FieldRec>(); // instance fields, inherited too
	public var sels = new Map<String, FieldRec>(); // instance selectors, inherited too
	public var props = new Map<String, {readonly:Bool, setter:String}>(); // instance properties, inherited too
	public var initLike = new Map<String, FieldRec>(); // inherited instance methods returning instancetype, still available
	public var factories = new Map<String, FieldRec>(); // inherited class methods returning instancetype
	public var staticNames = new Map<String, FieldRec>(); // own only
	public var staticSels = new Map<String, FieldRec>(); // own only

	public function new() {}

	public function inherit():ClassState {
		var s = new ClassState();
		s.adopted = adopted.copy();
		s.names = names.copy();
		s.sels = sels.copy();
		s.props = props.copy();
		s.initLike = initLike.copy();
		s.factories = factories.copy();
		return s;
	}
}

// the imports of the module being written
class Module {
	public var pack:String;
	public var imports = new Map<String, Bool>();

	public function new(pack)
		this.pack = pack;

	public function use(pack:Array<String>, name:String) {
		if (pack.length == 0) return;
		if (pack.length == 1 && pack[0] == this.pack) return;
		imports.set(pack.concat([name]).join("."), true);
	}
}

class Gen {
	public static var KEYWORDS = [
		"abstract", "break", "case", "cast", "catch", "class", "continue", "default", "do", "dynamic", "else", "enum", "extends", "extern", "false", "final",
		"for", "function", "if", "implements", "import", "in", "inline", "interface", "macro", "new", "null", "operator", "overload", "override", "package",
		"private", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "typedef", "untyped", "using", "var", "while"
	];

	static var POS:Position = {file: "", min: 0, max: 0};

	// memory is the compiler's (docs/interop.md, "Memory")
	static var MEMORY = ["retain", "release", "autorelease"];

	// instancetype methods NSObject declares that its subclasses do not
	// redeclare (alloc and the initializers they do)
	static var ROOT_ONLY = ["self", "new", "allocWithZone:"];

	var r:Reader;
	var types:Types;
	var scope:Array<String>;

	// the classes of the SDK (categories merged), the protocols each adopts
	var classes = new Map<String, Container>();
	var adopted = new Map<String, Array<{proto:String, origin:Origin}>>();
	var enumByName = new Map<String, EnumInfo>();
	// the protocols of the SDK
	var protos = new Map<String, Container>();

	// what is generated
	public var included = new Map<String, Bool>();
	public var protosIncluded = new Map<String, Bool>();
	var structsUsed = new Map<String, RecordInfo>();
	var enumsUsed = new Map<String, EnumInfo>();
	var structOk = new Map<String, Null<String>>(); // record id -> why it cannot be passed (null: it can)

	// objects of C (docs/interop.md, "Objects of C"): by the bridged struct's
	// tag, the class of its const typedef (CGPathRef: CGPath) and of its other
	// one (CGMutablePathRef: CGMutablePath, a subclass), or the only one
	var cfByTag = new Map<String, {base:Null<String>, mutable:Null<String>, origin:Origin}>();
	var cfTag = new Map<String, String>(); // class -> tag
	var cfUsed = new Map<String, Bool>();
	// the C functions and variables of the frameworks in scope kept
	var funcsKept:Array<{f:CFunc, ret:HType, params:Array<{name:String, t:HType}>, retained:Bool}> = [];
	var varsKept:Array<{v:CVar, t:HType}> = [];

	// what the type being mapped references (committed when its member is kept)
	var refs:Array<String> = [];
	var protoRefs:Array<String> = [];
	var structRefs:Array<RecordInfo> = [];
	var enumRefs:Array<EnumInfo> = [];
	var cfRefs:Array<String> = [];
	// the type mapped last was C's object (a CF type: Core Foundation's
	// ownership rules apply, not Objective-C's)
	public var spelledCF = false;

	public var skipped = new Map<String, Int>();
	public var count = new Map<String, Int>();

	public function new(r:Reader, scope:Array<String>) {
		this.r = r;
		this.scope = scope;
		types = new Types(r, this);
	}

	function tally(m:Map<String, Int>, k:String, n = 1)
		m.set(k, (m.exists(k) ? m.get(k) : 0) + n);

	public var details = new Map<String, Array<String>>();
	public var where = "";

	public function skip(reason:String, ?what:String) {
		tally(skipped, reason);
		if (!details.exists(reason)) details.set(reason, []);
		details.get(reason).push(where + (what != null ? " " + what : ""));
	}

	static function unavailable(a:Null<Availability>):Bool
		return a != null && a.unavailable;

	// --- what is there ---

	public function prepare() {
		for (name => c in r.classes) {
			// a class only forward-declared (@class) has no superclass nor members
			if (c.superName == null && c.members.length == 0 && name != "NSObject" && name != "NSProxy") continue;
			if (unavailable(c.avail)) continue;
			classes.set(name, c);
			adopted.set(name, [for (p in c.protocols) {proto: p, origin: c.origin}]);
		}
		for (name => p in r.protocols)
			if (!unavailable(p.avail) && p.origin != null) protos.set(name, p);
		// a class whose superclass is missing is too
		var changed = true;
		while (changed) {
			changed = false;
			for (name => c in classes)
				if (c.superName != null && !classes.exists(c.superName)) {
					classes.remove(name);
					changed = true;
				}
		}
		for (cat in r.categories) {
			var c = classes.get(cat.cls);
			if (c == null) continue;
			if (unavailable(cat.cat.avail)) {
				skip("category unavailable on macOS");
				continue;
			}
			var why = cat.cls == "NSObject" ? informal(cat.cat) : null;
			if (why != null) {
				where = "NSObject(" + cat.cat.name + ") " + cat.cat.origin.framework + ":";
				skip("informal protocol (category of NSObject): " + why, [for (m in cat.cat.members) (m.isStatic ? "+" : "-") + m.name].join(" "));
				tally(skipped, "informal protocol methods", cat.cat.members.length);
				continue;
			}
			for (m in cat.cat.members)
				c.members.push(m);
			for (p in cat.cat.protocols)
				adopted.get(cat.cls).push({proto: p, origin: cat.cat.origin});
		}
		where = "";
		// anonymous enums and records named by their typedefs
		for (td in r.typedefs) {
			if (td.tagId == null) continue;
			var e = r.enumsById.get(td.tagId);
			if (e != null && e.name == null) e.name = td.name;
			var rec = r.records.get(td.tagId);
			if (rec != null && (rec.tag == "" || rec.tag.startsWith("_"))) {
				// `typedef struct _NSRange {...} NSRange`: the typedef's name
				if (rec.name == rec.tag || rec.tag.substr(1) == td.name) rec.name = td.name;
			}
		}
		for (e in r.enums)
			if (e.name != null && !enumByName.exists(e.name)) enumByName.set(e.name, e);
		// objects of C: the `…Ref` typedefs of pointers to bridged structs
		var ptr = ~/^(const )?struct (\w+) \*$/;
		var tds = [for (td in r.typedefs) td];
		tds.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (td in tds) {
			if (!td.name.endsWith("Ref") || td.name.length <= 3 || !ptr.match(td.type.desugared.trim())) continue;
			var tag = ptr.matched(2);
			if (!r.bridges.exists(tag)) continue;
			var cls = td.name.substr(0, td.name.length - 3);
			var e = cfByTag.get(tag);
			if (e == null) cfByTag.set(tag, e = {base: null, mutable: null, origin: td.origin});
			// (one of each: a second name of the same, a typedef of a typedef, is not a class)
			if (ptr.matched(1) != null && e.base == null) e.base = cls;
			else if (ptr.matched(1) == null && e.mutable == null) e.mutable = cls;
			else continue;
			cfTag.set(cls, tag);
		}
		// (only one typedef, not const: CGColorRef, the class itself)
		for (e in cfByTag)
			if (e.base == null) {
				e.base = e.mutable;
				e.mutable = null;
			}
	}

	// a pointer to the struct `tag` (const), spelled `spelled`: an object of C
	// (an HCF), or of its toll-free bridged Objective-C class (CFStringRef:
	// NSString); null: not an object
	public function useCF(tag:String, constant:Bool, spelled:String, nullable:Bool):Null<HType> {
		var b = r.bridges.get(tag);
		if (b == null) return null;
		var objc = !constant && b.mutable != null && b.mutable != "id" ? b.mutable : b.objc;
		if (objc != null && objc != "id" && isClass(objc)) {
			spelledCF = true;
			return useClass(objc, nullable);
		}
		var e = cfByTag.get(tag);
		if (e == null) return null;
		var own = spelled.endsWith("Ref") ? spelled.substr(0, spelled.length - 3) : "";
		var name = cfTag.get(own) == tag ? own : constant || e.mutable == null ? e.base : e.mutable;
		spelledCF = true;
		cfRefs.push(name);
		return HCF(name, nullable);
	}

	// CFTypeRef: any object, of C's rules
	public function markCF()
		spelledCF = true;

	// why a category of NSObject is an informal protocol (methods for other
	// objects to implement: delegates, data sources, validation, actions,
	// which NSObject does not), or null: one outside NSObject's own headers
	// that a formal protocol of its name (without "Deprecated") supersedes,
	// or whose members are all callbacks
	function informal(cat:Container):Null<String> {
		if (cat.origin.header == "NSObject") return null;
		if (r.protocols.exists(cat.name) || r.protocols.exists(cat.name.replace("Deprecated", ""))) return "a formal protocol of its name";
		if (cat.members.length == 0) return null;
		for (m in cat.members)
			if (!callback(m)) return null;
		return "callbacks";
	}

	// an instance method whose first parameter is its sender: named `sender`,
	// a notification (`controlTextDidChange:`), or an object of a class the
	// first piece names without its prefix (`fileManager:`, `validateMenuItem:`)
	static function callback(m:Member):Bool {
		if (m.isStatic) return false;
		return switch m.kind {
			case KMethod(_, params, _) if (params.length > 0):
				var p = params[0];
				var obj = ~/^\s*(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\*/;
				if (p.name == "sender") return true;
				if (!obj.match(p.type.qual)) return false;
				var cls = obj.matched(1);
				if (cls == "NSNotification") return true;
				var short = (~/^[A-Z][A-Z]./.match(cls) ? cls.substr(2) : cls).toLowerCase();
				var first = pieces(m.name)[0].toLowerCase();
				short.length > 2 && (first.startsWith(short) || first.endsWith(short));
			case _: false;
		}
	}

	public function isClass(name:String):Bool
		return classes.exists(name);

	public function enumNamed(name:String):Null<EnumInfo>
		return enumByName.get(name);

	public function useClass(name:String, nullable:Bool, ?args:Array<HType>):HType {
		refs.push(name);
		return HClass(name, nullable, args == null ? [] : args);
	}

	// a class's lightweight generic parameters: how many
	public function typeParamCount(name:String):Int {
		var c = r.classes.get(name);
		return c == null ? 0 : c.typeParams.length;
	}

	// the type parameters in scope for a member of class cls (none: a
	// protocol's), named as its declaration names them (Types.scope)
	function within(m:Member, cls:Null<String>) {
		types.scope = new Map();
		types.selfArgs = [];
		var c = cls == null ? null : r.classes.get(cls);
		if (c == null) return;
		for (i in 0...c.typeParams.length) {
			var own = c.typeParams[i].name;
			types.scope.set(own, own);
			if (i < m.scope.length) types.scope.set(m.scope[i], own);
			types.selfArgs.push(HParam(own, false));
		}
	}

	// t with the type parameters replaced (an inherited member's, in a subclass's terms)
	static function subst(t:HType, by:Map<String, HType>):HType
		return switch t {
			case HParam(n, nl) if (by.exists(n)):
				switch by.get(n) {
					case HClass(c, _, a): HClass(c, nl, a);
					case HProto(p, _): HProto(p, nl);
					case HParam(q, _): HParam(q, nl);
					case HId(_): HId(nl);
					case o: o;
				}
			case HClass(n, nl, a): HClass(n, nl, [for (x in a) subst(x, by)]);
			case HFun(args, ret, nl): HFun([for (x in args) subst(x, by)], subst(ret, by), nl);
			case _: t;
		}

	static function substRec(f:FieldRec, by:Map<String, HType>):FieldRec {
		var g = Reflect.copy(f);
		g.params = [for (p in f.params) {name: p.name, t: subst(p.t, by)}];
		g.ret = subst(f.ret, by);
		return g;
	}

	// the type parameters t names
	static function paramsIn(t:HType, into:Array<String>)
		switch t {
			case HParam(n, _): if (into.indexOf(n) < 0) into.push(n);
			case HClass(_, _, a): for (x in a) paramsIn(x, into);
			case HFun(args, ret, _):
				for (x in args) paramsIn(x, into);
				paramsIn(ret, into);
			case _:
		}

	// id<P> (the first protocol of the list generated, NSObject's last)
	public function useProtocol(names:Array<String>, nullable:Bool):Null<HType> {
		var ps = [for (n in names) if (protos.exists(n)) n];
		ps.sort((a, b) -> (a == "NSObject" ? 1 : 0) - (b == "NSObject" ? 1 : 0));
		if (ps.length == 0) return null;
		protoRefs.push(ps[0]);
		return HProto(ps[0], nullable);
	}

	public function useEnum(e:EnumInfo):HType {
		if (e.name == null) return enumUnderlying(e);
		enumRefs.push(e);
		return HEnum(e);
	}

	public function useStruct(rec:RecordInfo):HType {
		var why = structCheck(rec);
		if (why != null) throw new Skip(why);
		structRefs.push(rec);
		return HStruct(rec);
	}

	// why a struct cannot be passed by value, or null
	function structCheck(rec:RecordInfo):Null<String> {
		if (structOk.exists(rec.id)) return structOk.get(rec.id);
		structOk.set(rec.id, "recursive struct");
		var why:Null<String> = null;
		if (rec.union) why = "union";
		else if (rec.name == "" || rec.name.startsWith("_")) why = "struct without a name";
		else if (rec.fields.length == 0) why = "empty struct";
		else
			for (f in rec.fields) {
				if (f.bitfield) {
					why = "struct with bitfields";
					break;
				}
				if (f.name == "") {
					why = "struct with an anonymous member";
					break;
				}
				try {
					switch types.map(f.type, "", true) {
						case HVoid: why = "struct with a void field";
						case _:
					}
				} catch (s:Skip) {
					why = "struct with a field of " + s.reason;
				}
				if (why != null) break;
			}
		structOk.set(rec.id, why);
		return why;
	}

	function enumUnderlying(e:EnumInfo):HType {
		if (e.underlying != null) {
			var b = Types.builtin(underlyingName(e.underlying));
			if (b != null && b != HVoid) return b;
			return Types.I64;
		}
		var wide = false;
		for (c in e.consts)
			if (c.value.high != (c.value.low >> 31) && c.value.high != 0) wide = true;
		return wide ? Types.I64 : Types.INT;
	}

	static function underlyingName(t:CType):String {
		var d = t.desugared;
		return [for (w in d.split(" ")) if (w != "const" && w != "") w].join(" ");
	}

	// the type of a declaration's member, its references committed if it maps
	function attempt<T>(f:() -> T):T {
		refs = [];
		protoRefs = [];
		structRefs = [];
		enumRefs = [];
		cfRefs = [];
		return f();
	}

	function commit() {
		for (n in cfRefs) {
			cfUsed.set(n, true);
			// (a mutable one's superclass)
			var e = cfByTag.get(cfTag.get(n));
			if (e.mutable == n) cfUsed.set(e.base, true);
		}
		for (n in refs)
			include(n);
		for (p in protoRefs)
			includeProto(p);
		for (s in structRefs)
			useStructDeep(s);
		for (e in enumRefs)
			if (e.name != null) enumsUsed.set(e.name, e);
	}

	function useStructDeep(rec:RecordInfo) {
		if (structsUsed.exists(rec.name)) return;
		structsUsed.set(rec.name, rec);
		var saved = structRefs, savedE = enumRefs;
		structRefs = [];
		enumRefs = [];
		for (f in rec.fields)
			try types.map(f.type, "", true) catch (_:Skip) {}
		var rs = structRefs, es = enumRefs;
		structRefs = saved;
		enumRefs = savedE;
		for (s in rs)
			useStructDeep(s);
		for (e in es)
			if (e.name != null) enumsUsed.set(e.name, e);
	}

	function includeProto(name:String) {
		if (protosIncluded.exists(name) || !protos.exists(name)) return;
		protosIncluded.set(name, false);
		for (q in protos.get(name).protocols)
			includeProto(q);
	}

	function include(name:String) {
		if (included.exists(name)) return;
		var c = classes.get(name);
		if (c == null) return;
		included.set(name, false);
		if (c.superName != null) include(c.superName);
	}

	// --- the members of a class ---

	// its own (categories merged), then the required ones of the protocols it adopts
	function membersOf(name:String):Array<Member> {
		var c = classes.get(name);
		var r = c.members.copy();
		var seen = new Map<String, Bool>();
		for (m in r)
			seen.set(key(m), true);
		var visited = new Map<String, Bool>();
		function adopt(p:String, origin:Origin) {
			if (visited.exists(p)) return;
			visited.set(p, true);
			var proto = this.r.protocols.get(p);
			if (proto == null || unavailable(proto.avail)) return;
			for (m in proto.members) {
				if (seen.exists(key(m))) continue;
				seen.set(key(m), true);
				if (m.optional) {
					skip("optional protocol member");
					continue;
				}
				var copy = new Member(m.name, m.isStatic, m.kind, origin);
				copy.avail = m.avail;
				r.push(copy);
			}
			for (q in proto.protocols)
				adopt(q, origin);
		}
		for (a in adopted.get(name))
			adopt(a.proto, a.origin);
		return r;
	}

	static function key(m:Member):String
		return (m.isStatic ? "+" : "-") + (m.kind.match(KProperty(_)) ? "@" : "") + m.name;

	// --- which classes: Foundation's and AppKit's, and what their members reference ---

	public function closure() {
		for (name => c in classes)
			if (scope.indexOf(c.origin.framework) >= 0) include(name);
		for (name => p in protos)
			if (scope.indexOf(p.origin.framework) >= 0) includeProto(name);
		cFunctions();
		cVariables();
		var done = new Map<String, Bool>();
		var progress = true;
		while (progress) {
			progress = false;
			for (name in [for (k in protosIncluded.keys()) k]) {
				if (done.exists("P:" + name)) continue;
				done.set("P:" + name, true);
				progress = true;
				for (m in protos.get(name).members) {
					if (unavailable(m.avail) || m.isStatic) continue;
					within(m, null);
					try {
						attempt(() -> switch m.kind {
							case KMethod(ret, params, variadic):
								if (variadic) throw new Skip("variadic");
								types.map(ret, "NSObject");
								for (p in params)
									types.map(p.type, "NSObject");
							case KProperty(t, _, _, _):
								types.map(t, "NSObject");
						});
						commit();
					} catch (_:Skip) {}
				}
			}
			for (name in [for (k in included.keys()) k]) {
				if (done.exists(name)) continue;
				done.set(name, true);
				progress = true;
				for (a in adopted.get(name))
					includeProto(a.proto);
				for (m in membersOf(name)) {
					if (unavailable(m.avail) || m.optional) continue;
					within(m, name);
					try {
						attempt(() -> switch m.kind {
							case KMethod(ret, params, variadic):
								if (variadic) throw new Skip("variadic");
								types.map(ret, name);
								for (p in params)
									types.map(p.type, name);
							case KProperty(t, _, _, _):
								types.map(t, name);
						});
						commit();
					} catch (_:Skip) {}
				}
			}
		}
		// enums and structs of the frameworks in scope, referenced or not
		for (e in r.enums)
			if (e.name != null && scope.indexOf(e.origin.framework) >= 0 && !unavailable(e.avail)) enumsUsed.set(e.name, e);
		for (rec in r.records)
			if (scope.indexOf(rec.origin.framework) >= 0 && structCheck(rec) == null) useStructDeep(rec);
	}

	// --- C's functions and variables ---

	// an object: what ownership concerns
	static function isObject(h:HType):Bool
		return h.match(HClass(_, _, _) | HCF(_, _) | HId(_) | HProto(_, _) | HParam(_, _));

	// whether h is a block
	static function hasBlock(h:HType):Bool
		return h.match(HFun(_, _, _));

	// a C function's parameter or result: a block is hxmc.objc.Block<F> there
	// (a message's signature says it of a function type; a C function's does
	// not), converted from and to a function F where it is passed
	function cParamType(h:HType, mod:Module):ComplexType
		return switch h {
			case HFun(args, ret, nullable):
				mod.use(["hxmc", "objc"], "Block");
				var b = TPath({pack: [], name: "Block", params: [TPType(ctype(HFun(args, ret, false), mod))]});
				nullable ? TPath({pack: [], name: "Null", params: [TPType(b)]}) : b;
			case _: ctype(h, mod);
		}

	// the C functions of the frameworks in scope: those with a symbol whose
	// types map; an object result's ownership by Core Foundation's rules for
	// C's objects (an audited region's Create rule, CF_RETURNS_RETAINED), by
	// ARC's for Objective-C's (borrowed unless NS_RETURNS_RETAINED);
	// reference counting is the compiler's (CFRetain, CGColorRelease: left out)
	function cFunctions() {
		var fs = [for (f in r.functions) if (scope.indexOf(f.origin.framework) >= 0) f];
		fs.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (f in fs) {
			where = f.origin.framework + ": " + f.name;
			if (unavailable(f.avail)) {
				skip("C function unavailable on macOS");
				continue;
			}
			if (f.name.startsWith("_")) {
				skip("C function: private (_)");
				continue;
			}
			if (f.headerOnly) {
				skip("C function only in its header (static inline: no symbol)");
				continue;
			}
			if (f.variadic) {
				skip("C function: variadic");
				continue;
			}
			if (f.consumes) {
				skip("C function consuming an argument (CF_CONSUMED)");
				continue;
			}
			try {
				var kept = attempt(() -> {
					spelledCF = false;
					var ret = types.map(f.ret, "");
					var cfRet = spelledCF;
					var params = [for (p in f.params) {name: p.name, t: types.map(p.type, "")}];
					if (params.length == 1 && params[0].t == HVoid) params = [];
					for (p in params)
						if (p.t == HVoid) throw new Skip("C function with a void parameter");
					// (memory is the compiler's: CFRetain, CGColorRelease, CFAutorelease)
					if ((f.name.endsWith("Retain") || f.name.endsWith("Release") || f.name.endsWith("Autorelease") || f.name == "CFMakeCollectable")
						&& params.length == 1 && isObject(params[0].t))
						throw new Skip("C function: reference counting (the compiler's)");
					var retained = false;
					if (isObject(ret)) {
						if (f.retained != null) retained = f.retained;
						else if (cfRet) {
							if (!f.audited) throw new Skip("C function returning C's object: ownership not audited");
							retained = f.name.indexOf("Create") >= 0 || f.name.indexOf("Copy") >= 0;
						}
					}
					{f: f, ret: ret, params: params, retained: retained};
				});
				commit();
				funcsKept.push(kept);
				tally(count, "C functions");
			} catch (s:Skip) {
				skip(s.reason, s.what);
			}
		}
		where = "";
	}

	// the `extern` variables of the frameworks in scope: constants and others
	function cVariables() {
		var vs = [for (v in r.vars) if (scope.indexOf(v.origin.framework) >= 0) v];
		vs.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (v in vs) {
			where = v.origin.framework + ": " + v.name;
			if (unavailable(v.avail)) {
				skip("C variable unavailable on macOS");
				continue;
			}
			if (v.name.startsWith("_")) {
				skip("C variable: private (_)");
				continue;
			}
			try {
				var t = attempt(() -> {
					var t = types.map(v.type, "");
					if (hasBlock(t) || t == HVoid) throw new Skip("C variable of a block or void");
					t;
				});
				commit();
				varsKept.push({v: v, t: t});
				tally(count, "C variables");
			} catch (s:Skip) {
				skip(s.reason, s.what);
			}
		}
		where = "";
	}

	// the class of a framework's C functions and variables (`coregraphics.CoreGraphics`)
	public function cDefs(taken:String->Bool):Array<{def:TypeDefinition, mod:Module}> {
		var byPack = new Map<String, {origin:Origin, fields:Array<Field>, mod:Module}>();
		var order = [];
		function group(o:Origin) {
			var k = packOf(o);
			var g = byPack.get(k);
			if (g == null) {
				byPack.set(k, g = {origin: o, fields: [], mod: new Module(k)});
				order.push(k);
			}
			// (the framework's own library, not a sub-framework's)
			if (g.origin.lib != null && o.lib == null) g.origin = o;
			return g;
		}
		function fieldMeta(cname:String, o:Origin, g:{origin:Origin}, avail:Null<Availability>):Metadata {
			var m:Metadata = [];
			if (ident(cname) != cname) m.push(meta(":native", [str(cname)]));
			if (o.lib != g.origin.lib) m.push(libMeta(o));
			if (avail != null && avail.deprecated != null) m.push(deprecatedMeta(avail.deprecated));
			return m;
		}
		for (k in funcsKept) group(k.f.origin);
		for (k in varsKept) group(k.v.origin);
		for (k in funcsKept) {
			var g = group(k.f.origin);
			var m = fieldMeta(k.f.name, k.f.origin, g, k.f.avail);
			if (k.retained) m.push(meta(":hxmc.retained"));
			var pnames = [];
			var args = [];
			for (p in k.params) {
				var n = ident(p.name);
				while (pnames.indexOf(n) >= 0)
					n += "_";
				pnames.push(n);
				args.push({name: n, type: cParamType(p.t, g.mod)});
			}
			g.fields.push({
				name: ident(k.f.name),
				access: [APublic, AStatic],
				meta: m,
				pos: POS,
				kind: FFun({args: args, ret: cParamType(k.ret, g.mod), expr: null})
			});
		}
		for (k in varsKept) {
			var g = group(k.v.origin);
			// (an object's: hxmc reads such variables only)
			var readOnly = k.v.isConst || isObject(k.t);
			g.fields.push({
				name: ident(k.v.name),
				access: readOnly ? [APublic, AStatic, AFinal] : [APublic, AStatic],
				meta: fieldMeta(k.v.name, k.v.origin, g, k.v.avail),
				pos: POS,
				kind: FVar(ctype(k.t, g.mod), null)
			});
		}
		var r = [];
		for (k in order) {
			var g = byPack.get(k);
			var name = ident(g.origin.framework == "" ? "CLib" : g.origin.framework);
			while (taken(name))
				name += "_";
			r.push({
				def: {
					pack: [k],
					name: name,
					pos: POS,
					meta: [meta(":hxmc.c"), libMeta(g.origin)],
					params: [],
					isExtern: true,
					kind: TDClass(null, [], false, false, false),
					fields: g.fields
				},
				mod: g.mod
			});
		}
		return r;
	}

	// an object of C: an extern class implementing Id (a mutable one
	// extending its immutable one)
	public function cfDef(name:String):TypeDefinition {
		var e = cfByTag.get(cfTag.get(name));
		tally(count, "objects of C");
		return {
			pack: [packOf(e.origin)],
			name: name,
			pos: POS,
			params: [],
			kind: e.mutable == name ? TDClass({pack: [], name: e.base}, [], false, false, false) : TDClass(null, [{pack: ["hxmc", "objc"], name: "Id"}], false,
				false, false),
			isExtern: true,
			fields: []
		};
	}

	// --- names ---

	public static function valid(s:String):Bool
		return ~/^[A-Za-z_][A-Za-z0-9_]*$/.match(s) && KEYWORDS.indexOf(s) < 0;

	static function ident(s:String):String {
		if (valid(s)) return s;
		var t = ~/[^A-Za-z0-9_]/g.replace(s, "_");
		if (t == "" || ~/^[0-9]/.match(t)) t = "_" + t;
		return valid(t) ? t : t + "_";
	}

	static function pieces(sel:String):Array<String> {
		var p = sel.split(":");
		if (sel.endsWith(":")) p.pop();
		return p;
	}

	// a parameter's type as Haxe tells overloads apart (Null<C> is C)
	static function sigKey(t:HType):String
		return switch t {
			case HPrim(pack, name): pack.concat([name]).join(".");
			case HVoid: "Void";
			case HClass(name, _, _): name;
			case HParam(name, _): "T:" + name;
			case HId(_): "Id";
			case HProto(name, _): "P:" + name;
			case HCF(name, _): name;
			case HFun(args, ret, _): "(" + [for (a in args) sigKey(a)].join(",") + ")->" + sigKey(ret);
			case HStruct(rec): rec.name;
			case HEnum(e): e.name;
		}

	static function camel(ps:Array<String>):String {
		var b = new StringBuf();
		for (i in 0...ps.length)
			b.add(i == 0 ? ps[i] : ps[i].charAt(0).toUpperCase() + ps[i].substr(1));
		return b.toString();
	}

	// the name and parameter names of a method: the selector's first piece,
	// the following pieces; else @:selector and names that are valid (an
	// overload keeps the first piece)
	function naming(sel:String, params:Array<Param>, taken:String->Bool, isOverload = false):{name:String, params:Array<String>, selMeta:Bool} {
		var ps = pieces(sel);
		var derived = ps.length == (params.length == 0 ? 1 : params.length) && Lambda.foreach(ps, valid);
		var names = [];
		if (derived && params.length > 0) {
			var later = ps.slice(1);
			for (i in 1...ps.length)
				if (later.indexOf(ps[i]) != i - 1) derived = false;
			var first = ident(params[0].name);
			while (later.indexOf(first) >= 0)
				first += "_";
			names = [first].concat(later);
		}
		if (derived && (isOverload || !taken(ps[0]))) return {name: ps[0], params: names, selMeta: false};
		// renamed: the pieces joined, or with underscores until free
		var name = ident(ps.length > 1 && ps.join("") != "" ? camel([for (p in ps) if (p != "") p]) : ps[0]);
		if (derived && taken(ps[0]) && params.length <= 1 && ps.length == 1) name = ident(ps[0]);
		if (isOverload) name = ps[0];
		else
			while (taken(name))
				name += "_";
		var pnames = [];
		for (i in 0...params.length) {
			var n = ident(i < ps.length && i > 0 && ps[i] != "" ? ps[i] : params[i].name);
			while (pnames.indexOf(n) >= 0)
				n += "_";
			pnames.push(n);
		}
		return {name: name, params: pnames, selMeta: true};
	}

	// --- Haxe syntax ---

	function ctype(t:HType, mod:Module):ComplexType {
		inline function path(pack:Array<String>, name:String, ?params:Array<TypeParam>):ComplexType {
			mod.use(pack, name);
			return TPath({pack: [], name: name, params: params});
		}
		return switch t {
			case HPrim(pack, name): path(pack, name);
			case HVoid: TPath({pack: [], name: "Void"});
			case HClass(name, nullable, args):
				var c = path([packOf(classes.get(name).origin)], name, args.length == 0 ? null : [for (a in args) TPType(ctype(a, mod))]);
				nullable ? TPath({pack: [], name: "Null", params: [TPType(c)]}) : c;
			case HParam(name, nullable):
				var c = TPath({pack: [], name: name});
				nullable ? TPath({pack: [], name: "Null", params: [TPType(c)]}) : c;
			case HId(nullable):
				var c = path(["hxmc", "objc"], "Id");
				nullable ? TPath({pack: [], name: "Null", params: [TPType(c)]}) : c;
			case HProto(name, nullable):
				var c = path([packOf(protos.get(name).origin)], protoName(name));
				nullable ? TPath({pack: [], name: "Null", params: [TPType(c)]}) : c;
			case HCF(name, nullable):
				var c = path([packOf(cfByTag.get(cfTag.get(name)).origin)], name);
				nullable ? TPath({pack: [], name: "Null", params: [TPType(c)]}) : c;
			case HFun(args, ret, nullable):
				var f = TFunction([for (a in args) ctype(a, mod)], ctype(ret, mod));
				nullable ? TPath({pack: [], name: "Null", params: [TPType(f)]}) : f;
			case HStruct(rec): path([typePack(rec.name, rec.origin)], typeName(rec.name));
			case HEnum(e): path([typePack(e.name, e.origin)], typeName(e.name));
		}
	}

	// a C type's name as a Haxe type's (uppercase first: tls_protocol_version_t)
	public static function typeName(n:String):String {
		while (n.startsWith("_"))
			n = n.substr(1);
		return n.charAt(0).toUpperCase() + n.substr(1);
	}

	public static function packOf(o:Origin):String
		return o.framework == "" ? "clib" : o.framework.toLowerCase();

	// a struct's or enum's package: Core Graphics' types where CoreFoundation
	// declares them (CGRect, CGPoint, CGSize in CFCGTypes.h) in `coregraphics`
	public static function typePack(name:String, o:Origin):String
		return name.startsWith("CG") && (o.framework == "CoreFoundation" || o.framework == "CoreGraphics") ? "coregraphics" : packOf(o);

	static function meta(name:String, ?args:Array<Expr>):MetadataEntry
		return {name: name, params: args == null ? [] : args, pos: POS};

	static function str(s:String):Expr
		return {expr: EConst(CString(s, DoubleQuotes)), pos: POS};

	static function int(s:String, ?suffix:String):Expr
		return {expr: EConst(CInt(s, suffix)), pos: POS};

	static function libMeta(o:Origin):MetadataEntry
		return o.lib != null ? meta(":hxmc.lib", [str(o.lib)]) : meta(":hxmc.framework", [str(o.framework)]);

	// bare: the headers' messages are Apple's text
	static function deprecatedMeta(d:String):MetadataEntry
		return meta(":deprecated");

	function methodField(f:FieldRec, ret:HType, isOverride:Bool, mod:Module):Field {
		var m = [];
		if (f.selMeta) m.push(meta(":selector", [str(f.sel)]));
		if (f.lib != null) m.push(libMeta(f.lib));
		if (f.deprecated != null) m.push(deprecatedMeta(f.deprecated));
		var access = [];
		var tps:Array<TypeParamDecl> = [];
		if (f.isStatic) {
			access.push(AStatic);
			// (a static method has none of the class's parameters: its own)
			var used = [];
			for (p in f.params)
				paramsIn(p.t, used);
			paramsIn(ret, used);
			for (n in used) {
				var b = bounds.get(n);
				tps.push({name: n, constraints: [ctype(b != null ? b : HId(false), mod)]});
			}
		}
		if (isOverride) access.push(AOverride);
		if (f.isOverload) access.push(AOverload);
		return {
			name: f.name,
			access: access,
			meta: m,
			pos: POS,
			kind: FFun({args: [for (p in f.params) {name: p.name, type: ctype(p.t, mod)}], ret: ctype(ret, mod), expr: null, params: tps})
		};
	}

	// the bounds of the type parameters of the class being written
	var bounds = new Map<String, HType>();

	// --- protocols ---

	// a protocol's Haxe name: its own, or with "Protocol" when a class has it
	// (NSObject's, as Swift names it)
	public function protoName(name:String):String
		return classes.exists(name) || r.classes.exists(name) ? name + "Protocol" : name;

	var protoInfos = new Map<String, ProtoInfo>();

	function protoInfo(name:String):ProtoInfo {
		var info = protoInfos.get(name);
		if (info != null) return info;
		info = {methods: [], props: [], names: new Map(), sels: new Map()};
		protoInfos.set(name, info);
		var p = protos.get(name);
		for (q in p.protocols) {
			if (!protos.exists(q)) continue;
			var qi = protoInfo(q);
			for (m in qi.methods)
				if (!info.sels.exists(m.rec.sel)) {
					info.methods.push(m);
					info.sels.set(m.rec.sel, true);
					info.names.set(m.rec.name, true);
				}
			for (pp in qi.props)
				if (!info.sels.exists("@" + pp.objcName)) {
					info.props.push(pp);
					info.sels.set("@" + pp.objcName, true);
					info.sels.set(pp.get.sel, true);
					if (pp.set != null) info.sels.set(pp.set.sel, true);
					for (n in [pp.name, pp.get.name, "set_" + pp.name])
						info.names.set(n, true);
				}
		}
		var live = [];
		for (m in p.members) {
			where = name + " (protocol) " + (m.isStatic ? "+" : "-") + m.name;
			if (unavailable(m.avail)) continue;
			if (m.isStatic) {
				skip("class member of a protocol");
				continue;
			}
			if (m.kind.match(KMethod(_, _, _)) && MEMORY.indexOf(m.name) >= 0) {
				skip("memory management (the compiler's)");
				continue;
			}
			live.push(m);
		}
		// properties first, then methods (their first pieces: the name when no
		// other method of the family has it, else all pieces joined)
		for (m in live)
			switch m.kind {
				case KProperty(t, ro, getter, setter):
					where = name + " (protocol) " + m.name;
					if (info.sels.exists("@" + m.name)) continue;
					within(m, null);
					var h = try attempt(() -> types.map(t, "NSObject")) catch (s:Skip) {
						skip(s.reason, s.what);
						continue;
					}
					if (h == HVoid) continue;
					commit();
					var pname = ident(m.name);
					while (info.names.exists(pname) || info.names.exists("get_" + pname))
						pname += "_";
					var getSel = getter != null ? getter : m.name;
					var setSel = setter != null ? setter : "set" + m.name.charAt(0).toUpperCase() + m.name.substr(1) + ":";
					var depr = m.avail != null ? m.avail.deprecated : null;
					var getF:FieldRec = {
						name: "get_" + pname, sel: getSel, isStatic: false, params: [], ret: h, selMeta: pname != m.name || getSel != m.name, lib: null,
						deprecated: depr, instancetype: false, accessor: true, isOverload: false
					};
					var setF:Null<FieldRec> = ro ? null : {
						name: "set_" + pname, sel: setSel, isStatic: false, params: [{name: "v", t: h}], ret: h, selMeta: pname != m.name || setter != null,
						lib: null, deprecated: depr, instancetype: false, accessor: true, isOverload: false
					};
					info.props.push({name: pname, objcName: m.name, h: h, readonly: ro, get: getF, set: setF, optional: m.optional, owner: name});
					info.sels.set("@" + m.name, true);
					info.sels.set(getSel, true);
					if (setF != null) info.sels.set(setSel, true);
					for (n in [pname, getF.name, "set_" + pname])
						info.names.set(n, true);
					tally(count, "protocol properties");
				case _:
			}
		var firsts = new Map<String, Int>();
		for (m in info.methods)
			firsts.set(pieces(m.rec.sel)[0], (firsts.exists(pieces(m.rec.sel)[0]) ? firsts.get(pieces(m.rec.sel)[0]) : 0) + 1);
		for (m in live)
			switch m.kind {
				case KMethod(_, _, _) if (!info.sels.exists(m.name)):
					var f = pieces(m.name)[0];
					firsts.set(f, (firsts.exists(f) ? firsts.get(f) : 0) + 1);
				case _:
			}
		for (m in live)
			switch m.kind {
				case KMethod(retT, params, variadic):
					where = name + " (protocol) -" + m.name;
					var sel = m.name;
					if (info.sels.exists(sel)) continue;
					if (variadic) {
						skip("variadic");
						continue;
					}
					within(m, null);
					var sig = try attempt(() -> {
						ret: types.map(retT, "NSObject"),
						params: [for (p in params) types.map(p.type, "NSObject")]
					}) catch (s:Skip) {
						skip(s.reason, s.what);
						continue;
					}
					commit();
					// (a selector of one piece keeps it; those of several sharing it are joined)
					var first = pieces(sel)[0], one = pieces(sel).length == 1;
					var n = naming(sel, params, s -> info.names.exists(s) || s == first && !one && firsts.get(first) > 1);
					var rec:FieldRec = {
						name: n.name, sel: sel, isStatic: false, params: [for (i in 0...params.length) {name: n.params[i], t: sig.params[i]}],
						ret: sig.ret, selMeta: n.selMeta, lib: null, deprecated: m.avail != null ? m.avail.deprecated : null,
						instancetype: Types.isInstancetype(retT), accessor: false, isOverload: false
					};
					info.methods.push({rec: rec, optional: m.optional, owner: name});
					info.sels.set(sel, true);
					info.names.set(rec.name, true);
					tally(count, "protocol methods");
				case _:
			}
		return info;
	}

	public function protoDef(name:String, mod:Module):TypeDefinition {
		var p = protos.get(name);
		var info = protoInfo(name);
		where = name + " (protocol)";
		var fields:Array<Field> = [];
		function optional(f:Field, o:Bool):Field {
			if (o) f.meta.push(meta(":optional"));
			return f;
		}
		for (pp in info.props) {
			if (pp.owner != name) continue;
			fields.push(optional({
				name: pp.name,
				access: [],
				meta: [],
				pos: POS,
				kind: FProp("get", pp.readonly ? "never" : "set", ctype(pp.h, mod))
			}, pp.optional));
			fields.push(optional(methodField(pp.get, pp.h, false, mod), pp.optional));
			if (pp.set != null) fields.push(optional(methodField(pp.set, pp.h, false, mod), pp.optional));
		}
		for (m in info.methods)
			if (m.owner == name) fields.push(optional(methodField(m.rec, m.rec.ret, false, mod), m.optional));
		var parents = [];
		for (q in p.protocols)
			if (protos.exists(q) && protosIncluded.exists(q)) {
				mod.use([packOf(protos.get(q).origin)], protoName(q));
				parents.push({pack: [], name: protoName(q)});
			}
		// (a root protocol: any object, hxmc.objc.Id)
		if (!Lambda.exists(p.protocols, q -> protos.exists(q))) parents.push({pack: ["hxmc", "objc"], name: "Id"});
		var m = [meta(":hxmc.objc", [str(name)])];
		if (p.avail != null && p.avail.deprecated != null) m.push(deprecatedMeta(p.avail.deprecated));
		tally(count, "protocols");
		return {
			pack: [packOf(p.origin)],
			name: protoName(name),
			pos: POS,
			meta: m,
			params: [],
			isExtern: true,
			kind: TDClass(null, parents, true, false, false),
			fields: fields
		};
	}

	// the protocols class `name` adopts that its declaration can implement:
	// each member of the protocol's family under its name in the protocol (a
	// method the class names otherwise gets a field of that name too, sending
	// the same selector; an optional one it lacks, none: the interface's);
	// a protocol whose names the class gives other members is left out
	function adoptions(name:String, st:ClassState, mod:Module, fields:Array<Field>):Array<TypePath> {
		var r = [];
		for (a in adopted.get(name)) {
			var p = a.proto;
			if (!protosIncluded.exists(p) || st.adopted.exists(p)) continue;
			var info = protoInfo(p);
			where = name + " <" + p + ">";
			var add:Array<FieldRec> = [], addProps:Array<ProtoProp> = [];
			var taken = new Map<String, Bool>();
			function free(n:String)
				return !st.names.exists(n) && !taken.exists(n);
			var why:Null<String> = null;
			for (pm in info.methods) {
				// (a protocol a superclass implements: its members are there)
				if (st.adopted.exists(pm.owner)) continue;
				var rec = pm.rec;
				var mine = st.sels.get(rec.sel), named = st.names.get(rec.name);
				if (mine != null && mine.name == rec.name && !mine.accessor) continue;
				if (named != null && named.sel == rec.sel && !named.accessor) continue;
				if (!free(rec.name)) {
					why = rec.sel + " is " + rec.name + " in the protocol, another member's name here";
					break;
				}
				if (pm.optional && mine == null) continue;
				add.push(rec);
				taken.set(rec.name, true);
			}
			if (why == null)
				for (pp in info.props) {
					if (st.adopted.exists(pp.owner)) continue;
					var mine = st.props.get(pp.objcName);
					if (mine != null) {
						var g = st.names.get(pp.name);
						if (g == null || g.sel != pp.get.sel || !g.accessor) why = "property " + pp.objcName + " is named otherwise here";
						else if (!pp.readonly && mine.readonly) why = "property " + pp.objcName + " is readonly here";
						if (why != null) break;
						continue;
					}
					if (!free(pp.name) || !free(pp.get.name) || !free("set_" + pp.name)) {
						why = "property " + pp.objcName + ": its names are other members' here";
						break;
					}
					if (pp.optional) continue;
					addProps.push(pp);
					for (n in [pp.name, pp.get.name, "set_" + pp.name])
						taken.set(n, true);
				}
			if (why != null) {
				skip("protocol not implemented (names)", why);
				continue;
			}
			for (rec in add) {
				fields.push(methodField(rec, rec.ret, false, mod));
				st.names.set(rec.name, rec);
				if (!st.sels.exists(rec.sel)) st.sels.set(rec.sel, rec);
				tally(count, "protocol members redeclared under the protocol's names");
			}
			for (pp in addProps) {
				fields.push({name: pp.name, access: [], meta: [], pos: POS, kind: FProp("get", pp.readonly ? "never" : "set", ctype(pp.h, mod))});
				fields.push(methodField(pp.get, pp.h, false, mod));
				if (pp.set != null) fields.push(methodField(pp.set, pp.h, false, mod));
				st.names.set(pp.name, pp.get);
				st.names.set(pp.get.name, pp.get);
				if (pp.set != null) st.names.set(pp.set.name, pp.set);
				st.props.set(pp.objcName, {readonly: pp.readonly, setter: pp.set != null ? pp.set.sel : null});
				tally(count, "protocol members redeclared under the protocol's names");
			}
			function mark(q:String) {
				st.adopted.set(q, true);
				for (x in protos.get(q).protocols)
					if (protos.exists(x)) mark(x);
			}
			mark(p);
			mod.use([packOf(protos.get(p).origin)], protoName(p));
			r.push({pack: [], name: protoName(p)});
			tally(count, "protocols adopted");
		}
		return r;
	}

	// --- classes ---

	public function classDef(name:String, st:ClassState, mod:Module):TypeDefinition {
		var c = classes.get(name);
		var fields:Array<Field> = [];
		var head:Array<Field> = [], tail:Array<Field> = [];
		var members = membersOf(name);
		where = name;
		var self = name;
		var rc = r.classes.get(name);
		var selfArgs = [for (p in rc.typeParams) HParam(p.name, false)];

		function retype(t:HType):HType
			return switch t {
				case HClass(_, n, _): HClass(self, n, selfArgs);
				case _: t;
			}

		// lightweight generics: the class's parameters and their bounds, the
		// superclass's arguments, and the inherited members in their terms
		within(new Member("", false, KMethod({qual: "void", desugared: "void"}, [], false), c.origin), name);
		bounds = new Map();
		var tparams:Array<TypeParamDecl> = [];
		for (p in rc.typeParams) {
			var b = try types.typeArg(p.bound, self) catch (_:Skip) null;
			if (b == null) b = HId(false);
			bounds.set(p.name, b);
		}
		for (p in rc.typeParams) {
			var b = ctype(bounds.get(p.name), mod);
			tparams.push({name: p.name, constraints: [b], defaultType: b});
		}
		var superArgs:Array<HType> = [];
		var sc = c.superName != null ? r.classes.get(c.superName) : null;
		if (sc != null && sc.typeParams.length > 0) {
			var by = new Map<String, HType>();
			var spelled = rc.superArgs != null && rc.superArgs.length == sc.typeParams.length ? rc.superArgs : null;
			for (i in 0...sc.typeParams.length) {
				var a = spelled == null ? null : try attempt(() -> types.typeArg({qual: spelled[i], desugared: spelled[i]}, self)) catch (_:Skip) null;
				if (a != null) commit();
				superArgs.push(a);
			}
			if (superArgs.indexOf(null) >= 0) superArgs = [];
			for (i in 0...sc.typeParams.length)
				by.set(sc.typeParams[i].name, superArgs.length > 0 ? superArgs[i] : HId(false));
			for (k => f in st.initLike)
				st.initLike.set(k, substRec(f, by));
			for (k => f in st.factories)
				st.factories.set(k, substRec(f, by));
		}

		// a member of another library's category carries its library
		function libOf(m:Member):Null<Origin>
			return m.origin.framework != c.origin.framework && m.origin.framework != "" ? m.origin : null;

		var redeclared = new Map<String, Bool>(); // instancetype selectors declared here
		var redeclaredStatic = new Map<String, Bool>();

		// unavailable here: initializers (and other instancetype methods) not inherited further
		for (m in members)
			if (unavailable(m.avail)) {
				skip("unavailable on macOS");
				if (m.isStatic) st.factories.remove(m.name) else st.initLike.remove(m.name);
			}
		var live = [];
		for (m in members) {
			if (unavailable(m.avail)) continue;
			if (!m.isStatic && m.kind.match(KMethod(_, _, _)) && MEMORY.indexOf(m.name) >= 0) {
				where = name + " -" + m.name;
				skip("memory management (the compiler's)");
				continue;
			}
			live.push(m);
		}

		// properties first: their accessors' selectors cover the methods of the same selectors
		var seenProps = new Map<String, Bool>();
		var propRW = new Map<String, Bool>(); // readwrite in any declaration (a class extension's)
		for (m in live)
			switch m.kind {
				case KProperty(_, ro, _, _) if (!ro): propRW.set(key(m), true);
				case _:
			}
		for (m in live) {
			switch m.kind {
				case KProperty(t, ro, getter, setter):
					where = name + " " + m.name;
					var k = key(m);
					if (seenProps.exists(k)) continue;
					seenProps.set(k, true);
					var readonly = ro && !propRW.exists(k);
					within(m, name);
					var h = try attempt(() -> types.map(t, self)) catch (s:Skip) {
						skip(s.reason, s.what);
						continue;
					}
					if (m.isStatic) {
						var used = [];
						paramsIn(h, used);
						if (used.length > 0) {
							skip("class property of a type parameter");
							continue;
						}
					}
					if (h == HVoid) {
						skip("void property");
						continue;
					}
					commit();
					var getSel = getter != null ? getter : m.name;
					var setSel = setter != null ? setter : "set" + m.name.charAt(0).toUpperCase() + m.name.substr(1) + ":";
					var depr = m.avail != null ? m.avail.deprecated : null;
					var lib = libOf(m);
					if (m.isStatic) {
						if (st.staticSels.exists(getSel)) continue;
					} else {
						var inherited = st.props.get(m.name);
						if (inherited != null) {
							if (!readonly && inherited.readonly) {
								// readonly in a superclass, readwrite here: the setter alone
								// (Haxe allows no redefinition of the variable)
								var f:FieldRec = {
									name: "set_" + m.name, sel: setSel, isStatic: false, params: [{name: "v", t: h}], ret: HVoid, selMeta: true,
									lib: lib, deprecated: depr, instancetype: false, accessor: true, isOverload: false
								};
								fields.push(methodField(f, HVoid, false, mod));
								st.names.set(f.name, f);
								st.sels.set(setSel, f);
								st.props.set(m.name, {readonly: false, setter: setSel});
								tally(count, "readwrite redeclarations (setter only)");
							} else skip("property redeclared (inherited)");
							continue;
						}
						if (st.sels.exists(getSel)) {
							skip("property whose getter a superclass declares as a method");
							continue;
						}
					}
					var names = m.isStatic ? st.staticNames : st.names;
					var pname = ident(m.name);
					while (names.exists(pname) || names.exists("get_" + pname))
						pname += "_";
					var renamed = pname != m.name;
					var getF:FieldRec = {
						name: "get_" + pname, sel: getSel, isStatic: m.isStatic, params: [], ret: h, selMeta: renamed || getter != null && getter != m.name,
						lib: lib, deprecated: null, instancetype: false, accessor: true, isOverload: false
					};
					var setF:FieldRec = {
						name: "set_" + pname, sel: setSel, isStatic: m.isStatic, params: [{name: "v", t: h}], ret: h,
						selMeta: renamed || setter != null, lib: lib, deprecated: null, instancetype: false, accessor: true, isOverload: false
					};
					var vm = [];
					if (depr != null) vm.push(deprecatedMeta(depr));
					fields.push({
						name: pname,
						access: m.isStatic ? [AStatic] : [],
						meta: vm,
						pos: POS,
						kind: FProp("get", readonly ? "never" : "set", ctype(h, mod))
					});
					fields.push(methodField(getF, h, false, mod));
					if (!readonly) fields.push(methodField(setF, h, false, mod));
					var sels = m.isStatic ? st.staticSels : st.sels;
					names.set(pname, getF);
					names.set(getF.name, getF);
					sels.set(getSel, getF);
					if (!readonly) {
						names.set(setF.name, setF);
						sels.set(setSel, setF);
					}
					if (!m.isStatic) st.props.set(m.name, {readonly: readonly, setter: setSel});
					tally(count, m.isStatic ? "class properties" : "properties");
				case _:
			}
		}

		// methods whose first pieces are the same: overloads of it where their
		// parameters' types tell them apart (`systemFontOfSize:`,
		// `systemFontOfSize:weight:`), the fewest pieces first; the others are
		// renamed to their pieces joined
		var groups = new Map<String, Array<{sel:String, sig:String}>>(); // "+name": the methods named so
		var candidates = [];
		var seenCandidates = new Map<String, Bool>();
		for (m in live)
			switch m.kind {
				case KMethod(_, _, false) if (!seenCandidates.exists(key(m))):
					seenCandidates.set(key(m), true);
					candidates.push(m);
				case _:
			}
		haxe.ds.ArraySort.sort(candidates, (a, b) -> pieces(a.name).length - pieces(b.name).length);
		for (m in candidates) {
			var ps = pieces(m.name);
			// inherited: its inherited name
			if (m.isStatic ? st.factories.exists(m.name) : st.sels.exists(m.name)) continue;
			if (!valid(ps[0]) || (m.isStatic ? st.staticNames : st.names).exists(ps[0])) continue;
			if (!m.isStatic && ps.length >= 2 && descendantClaims(name, ps[0], m.name)) continue;
			within(m, name);
			var sig = try attempt(() -> switch m.kind {
				case KMethod(_, params, _): [for (p in params) sigKey(types.map(p.type, self))].join(",");
				case _: throw "unreachable";
			}) catch (_:Skip) continue;
			var gk = (m.isStatic ? "+" : "-") + ps[0];
			if (!groups.exists(gk)) groups.set(gk, []);
			var g = groups.get(gk);
			if (!Lambda.exists(g, x -> x.sig == sig)) g.push({sel: m.name, sig: sig});
		}
		function claimed(isStatic:Bool, s:String, sel:String):Bool {
			var g = groups.get((isStatic ? "+" : "-") + s);
			return g != null && !Lambda.exists(g, x -> x.sel == sel);
		}
		function overloaded(isStatic:Bool, sel:String):Bool {
			var g = groups.get((isStatic ? "+" : "-") + pieces(sel)[0]);
			return g != null && g.length > 1 && Lambda.exists(g, x -> x.sel == sel);
		}
		var seenMethods = new Map<String, Bool>();
		for (m in live) {
			switch m.kind {
				case KMethod(retT, params, variadic):
					where = name + " " + (m.isStatic ? "+" : "-") + m.name;
					var k = key(m);
					if (seenMethods.exists(k)) continue;
					seenMethods.set(k, true);
					if (variadic) {
						skip("variadic");
						continue;
					}
					var sel = m.name;
					var isIt = Types.isInstancetype(retT);
					within(m, name);
					var sig = try attempt(() -> {
						ret: types.map(retT, self),
						params: [for (p in params) types.map(p.type, self)]
					}) catch (s:Skip) {
						skip(s.reason, s.what);
						continue;
					}
					var depr = m.avail != null ? m.avail.deprecated : null;
					if (m.isStatic) {
						if (st.staticSels.exists(sel)) {
							skip(st.staticSels.get(sel).accessor ? "method covered by a property" : "duplicate");
							continue;
						}
						var inh = st.factories.get(sel);
						var f:FieldRec;
						if (inh != null && isIt) {
							f = Reflect.copy(inh);
							f.ret = retype(sig.ret);
							f.deprecated = depr;
							redeclaredStatic.set(sel, true);
						} else {
							var o = overloaded(true, sel);
							var n = naming(sel, params, s -> st.staticNames.exists(s) || claimed(true, s, sel), o);
							f = {
								name: n.name, sel: sel, isStatic: true, params: [for (i in 0...params.length) {name: n.params[i], t: sig.params[i]}],
								ret: sig.ret, selMeta: n.selMeta, lib: libOf(m), deprecated: depr, instancetype: isIt, accessor: false, isOverload: o
							};
						}
						commit();
						fields.push(methodField(f, f.ret, false, mod));
						st.staticNames.set(f.name, f);
						st.staticSels.set(sel, f);
						if (isIt && ROOT_ONLY.indexOf(sel) < 0) st.factories.set(sel, f);
						tally(count, "class methods");
					} else {
						var inh = st.sels.get(sel);
						if (inh != null) {
							if (inh.accessor) {
								skip("method covered by a property");
								continue;
							}
							if (isIt && st.initLike.exists(sel)) {
								// an instancetype method redeclared: the inherited one's names and types
								var f = Reflect.copy(st.initLike.get(sel));
								f.ret = retype(sig.ret);
								f.deprecated = depr;
								commit();
								fields.push(methodField(f, f.ret, true, mod));
								st.initLike.set(sel, f);
								redeclared.set(sel, true);
								tally(count, "methods");
								continue;
							}
							if (isIt && !redeclared.exists(sel) && inh.instancetype && ROOT_ONLY.indexOf(sel) < 0) {
								// unavailable above, available again here
								var f = Reflect.copy(inh);
								f.ret = retype(sig.ret);
								f.deprecated = depr;
								commit();
								fields.push(methodField(f, f.ret, true, mod));
								st.initLike.set(sel, f);
								redeclared.set(sel, true);
								tally(count, "methods");
								continue;
							}
							skip("method redeclared (inherited)");
							continue;
						}
						var multi = pieces(sel).length >= 2;
						var o = overloaded(false, sel);
						var n = naming(sel, params, s -> st.names.exists(s) || claimed(false, s, sel) || multi && descendantClaims(name, s, sel), o);
						var f:FieldRec = {
							name: n.name, sel: sel, isStatic: false, params: [for (i in 0...params.length) {name: n.params[i], t: sig.params[i]}],
							ret: sig.ret, selMeta: n.selMeta, lib: libOf(m), deprecated: depr, instancetype: isIt, accessor: false, isOverload: o
						};
						commit();
						fields.push(methodField(f, f.ret, false, mod));
						st.names.set(f.name, f);
						st.sels.set(sel, f);
						if (isIt && ROOT_ONLY.indexOf(sel) < 0) {
							st.initLike.set(sel, f);
							redeclared.set(sel, true);
						}
						tally(count, "methods");
					}
				case _:
			}
		}

		// inherited instancetype methods, redeclared with this class's type
		var sorted = [for (k in st.factories.keys()) k];
		sorted.sort(Reflect.compare);
		for (sel in sorted) {
			if (redeclaredStatic.exists(sel)) continue;
			var f = Reflect.copy(st.factories.get(sel));
			f.ret = retype(f.ret);
			if (st.staticNames.exists(f.name)) continue;
			head.push(methodField(f, f.ret, false, mod));
			st.staticNames.set(f.name, f);
			st.staticSels.set(sel, f);
			st.factories.set(sel, f);
			tally(count, "redeclared factories (static instancetype)");
		}
		sorted = [for (k in st.initLike.keys()) k];
		sorted.sort(Reflect.compare);
		for (sel in sorted) {
			if (redeclared.exists(sel)) continue;
			var f = Reflect.copy(st.initLike.get(sel));
			f.ret = retype(f.ret);
			tail.push(methodField(f, f.ret, true, mod));
			st.initLike.set(sel, f);
			st.names.set(f.name, f);
			st.sels.set(sel, f);
			tally(count, "redeclared instancetype methods (override)");
		}

		// covariant (an immutable collection): widened to a supertype's
		// elements explicitly, Haxe's parameters being invariant
		if (rc.typeParams.length > 0 && Lambda.foreach(rc.typeParams, p -> p.covariant) && !st.staticNames.exists("upcast")) {
			var from = [], to = [], ups:Array<TypeParamDecl> = [];
			for (p in rc.typeParams) {
				var a = p.name + "From", b = p.name + "To";
				ups.push({name: a, constraints: [TPath({pack: [], name: b})]});
				ups.push({name: b, constraints: [ctype(bounds.get(p.name), mod)]});
				from.push(TPType(TPath({pack: [], name: a})));
				to.push(TPType(TPath({pack: [], name: b})));
			}
			fields.push({
				name: "upcast",
				access: [APublic, AStatic, AInline],
				pos: POS,
				kind: FFun({
					params: ups,
					args: [{name: "a", type: TPath({pack: [], name: name, params: from})}],
					ret: TPath({pack: [], name: name, params: to}),
					expr: {expr: EReturn({expr: ECast({expr: EConst(CIdent("a")), pos: POS}, null), pos: POS}), pos: POS}
				})
			});
			tally(count, "covariant classes (upcast)");
		}
		var impl = adoptions(name, st, mod, tail);
		// (a root class: any object, hxmc.objc.Id)
		if (c.superName == null) impl.push({pack: ["hxmc", "objc"], name: "Id"});
		var cm = [libMeta(c.origin), meta(":hxmc.objc")];
		if (c.avail != null && c.avail.deprecated != null) cm.push(deprecatedMeta(c.avail.deprecated));
		var sup = c.superName != null ? {
			mod.use([packOf(classes.get(c.superName).origin)], c.superName);
			{pack: [], name: c.superName, params: superArgs.length == 0 ? null : [for (a in superArgs) TPType(ctype(a, mod))]};
		} : null;
		if (rc.typeParams.length > 0) tally(count, "generic classes");
		return {
			pack: [packOf(c.origin)],
			name: name,
			pos: POS,
			meta: cm,
			params: tparams,
			isExtern: true,
			kind: TDClass(sup, impl, false, false, false),
			fields: head.concat(fields).concat(tail)
		};
	}

	// the instance names the classes below each class want: a property's, a
	// method's first piece, of its fewest pieces (an ancestor's method of
	// several pieces yields its name to a property or a method of one piece)
	var below:Null<Map<String, Map<String, String>>>;

	function descendantClaims(cls:String, name:String, sel:String):Bool {
		if (below == null) {
			below = new Map();
			for (c in included.keys()) {
				var own = new Map<String, String>();
				for (m in classes.get(c).members) {
					if (m.isStatic || unavailable(m.avail)) continue;
					switch m.kind {
						case KProperty(_, _, _, _): own.set(m.name, "@" + m.name);
						case KMethod(_, _, _):
							var p = pieces(m.name)[0], o = own.get(p);
							if (o == null || !o.startsWith("@") && pieces(o).length > pieces(m.name).length) own.set(p, m.name);
					}
				}
				var s = classes.get(c).superName;
				while (s != null) {
					if (!below.exists(s)) below.set(s, new Map());
					var b = below.get(s);
					for (k => v in own)
						if (!b.exists(k) || v.startsWith("@") || !b.get(k).startsWith("@") && pieces(b.get(k)).length > pieces(v).length) b.set(k, v);
					s = classes.get(s).superName;
				}
			}
		}
		var b = below.get(cls);
		if (b == null) return false;
		// a property's or a selector's of one piece (a descendant's method of
		// several pieces is renamed anyway)
		var v = b.get(name);
		return v != null && v != sel && (v.startsWith("@") || pieces(v).length == 1);
	}

	// the classes in an order where superclasses come first
	public function ordered():Array<String> {
		var r = [], done = new Map<String, Bool>();
		function visit(n:String) {
			if (done.exists(n)) return;
			done.set(n, true);
			var s = classes.get(n).superName;
			if (s != null) visit(s);
			r.push(n);
		}
		var names = [for (k in included.keys()) k];
		names.sort(Reflect.compare);
		for (n in names)
			visit(n);
		return r;
	}

	// --- enums ---

	static function fits32(v:haxe.Int64):Bool
		return v.high == (v.low >> 31);

	static function hex(v:haxe.Int64):String
		return "0x" + StringTools.hex(v.high, 8) + StringTools.hex(v.low, 8);

	// Int's literal of a value (a negative one as `-n`)
	static function intLiteral(v:Int):Expr
		return v < 0 ? (v == 0x80000000 ? int("0x80000000") : {expr: EUnop(OpNeg, false, int(Std.string(-v))), pos: POS}) : int(Std.string(v));

	// the constants' names without their common prefix (NSWindowStyleMaskTitled: Titled)
	static function shortNames(e:EnumInfo):Map<String, String> {
		var consts = [for (c in e.consts) if (!unavailable(c.avail)) c];
		var current = [for (c in consts) if (c.avail == null || c.avail.deprecated == null) c.name];
		if (current.length == 0) current = [for (c in consts) c.name];
		var all = current.concat([e.name]);
		var p = all[0];
		for (n in all)
			while (!n.startsWith(p))
				p = p.substr(0, p.length - 1);
		// at a word's start
		while (p.length > 0) {
			var ok = true;
			for (n in current) {
				var c = n.charCodeAt(p.length);
				if (c == null || !(c >= "A".code && c <= "Z".code)) ok = false;
			}
			if (ok) break;
			p = p.substr(0, p.length - 1);
		}
		var r = new Map<String, String>();
		for (c in consts) {
			var s = p != "" && c.name.startsWith(p) ? c.name.substr(p.length) : c.name;
			if (!valid(s)) return [for (c in consts) c.name => c.name];
			r.set(c.name, s);
		}
		// one name for two constants: the full names
		var seen = new Map<String, Bool>();
		for (s in r)
			if (seen.exists(s)) return [for (c in consts) c.name => c.name];
			else seen.set(s, true);
		return r;
	}

	public function enumDef(e:EnumInfo, mod:Module):TypeDefinition {
		var under = enumUnderlying(e);
		var uct = ctype(under, mod);
		var self:ComplexType = TPath({pack: [], name: typeName(e.name)});
		var wide = under == Types.I64;
		// Int8 ... UInt16: abstracts over Int whose constants are casts
		var small = !wide && under != Types.INT;
		var names = shortNames(e);
		var fields:Array<Field> = [];
		function id(n:String):Expr
			return {expr: EConst(CIdent(n)), pos: POS};
		function make(v:Expr):Expr
			return {expr: ENew({pack: [], name: typeName(e.name)}, [v]), pos: POS};
		// the underlying value of an argument (its `to`)
		function under(n:String):Expr
			return {expr: ECheckType(id(n), uct), pos: POS};
		for (c in e.consts) {
			if (unavailable(c.avail)) {
				skip("enum constant unavailable on macOS");
				continue;
			}
			var m = c.avail != null && c.avail.deprecated != null ? [deprecatedMeta(c.avail.deprecated)] : [];
			var n = names.get(c.name);
			if (wide && !fits32(c.value)) {
				// no constant of 64 bits: a static final
				fields.push({
					name: n,
					access: [APublic, AStatic, AFinal],
					meta: m,
					pos: POS,
					kind: FVar(self, make(int(hex(c.value), "i64")))
				});
				tally(count, "enum constants (64-bit, static final)");
			} else
				fields.push({name: n, access: [], meta: m, pos: POS, kind: FVar(null, small ? {expr: ECast(intLiteral(c.value.low), null), pos: POS} : intLiteral(c.value.low))});
			tally(count, "enum constants");
		}
		if (wide || e.options)
			fields.push({
				name: "new",
				access: [AInline],
				pos: POS,
				kind: FFun({args: [{name: "v", type: uct}], ret: null, expr: {expr: EBinop(OpAssign, id("this"), id("v")), pos: POS}})
			});
		if (e.options) {
			// no options: none of the bits, a value of its own (so `None` resolves
			// where the type is expected), unless a constant has the name
			if (!Lambda.exists(fields, f -> f.name == "None"))
				fields.push({name: "None", access: [], pos: POS, kind: FVar(null, small ? {expr: ECast(intLiteral(0), null), pos: POS} : intLiteral(0))});
			function op(o:Binop, fname:String):Field {
				var body = make({expr: EBinop(o, id("this"), under("b")), pos: POS});
				return {
					name: fname,
					access: [AInline],
					meta: [{name: ":op", params: [{expr: EBinop(o, id("A"), id("B")), pos: POS}], pos: POS}],
					pos: POS,
					kind: FFun({args: [{name: "b", type: self}], ret: self, expr: {expr: EReturn(body), pos: POS}})
				};
			}
			fields.push(op(OpOr, "or"));
			fields.push(op(OpAnd, "and"));
			// all of the given bits set
			var test:Expr = {expr: EBinop(OpEq, {expr: EParenthesis({expr: EBinop(OpAnd, id("this"), under("o")), pos: POS}), pos: POS}, under("o")), pos: POS};
			fields.push({
				name: "has",
				access: [APublic, AInline],
				pos: POS,
				kind: FFun({args: [{name: "o", type: self}], ret: TPath({pack: [], name: "Bool"}), expr: {expr: EReturn(test), pos: POS}})
			});
		}
		var m = e.avail != null && e.avail.deprecated != null ? [deprecatedMeta(e.avail.deprecated)] : [];
		tally(count, e.options ? "enums (options)" : "enums");
		return {
			pack: [typePack(e.name, e.origin)],
			name: typeName(e.name),
			pos: POS,
			meta: m,
			params: [],
			kind: TDAbstract(uct, [AbEnum, AbTo(uct)]),
			fields: fields
		};
	}

	// the constants of a header's anonymous enums, as a class of its own
	public function constantsDefs(taken:String->Bool):Array<{def:TypeDefinition, mod:Module}> {
		var byHeader = new Map<String, Array<EnumInfo>>();
		var order = [];
		for (e in r.enums) {
			if (e.name != null || scope.indexOf(e.origin.framework) < 0) continue;
			var k = packOf(e.origin) + "." + e.origin.header;
			if (!byHeader.exists(k)) {
				byHeader.set(k, []);
				order.push(k);
			}
			byHeader.get(k).push(e);
		}
		var r = [];
		for (k in order) {
			var es = byHeader.get(k);
			var o = es[0].origin;
			var name = ident(o.header) + "Constants";
			while (taken(name))
				name += "_";
			var mod = new Module(packOf(o));
			var fields:Array<Field> = [];
			var seen = new Map<String, Bool>();
			for (e in es) {
				var under = enumUnderlying(e);
				var uct = ctype(under, mod);
				for (c in e.consts) {
					if (unavailable(c.avail)) {
						skip("enum constant unavailable on macOS");
						continue;
					}
					if (seen.exists(c.name) || !valid(c.name)) continue;
					seen.set(c.name, true);
					var m = c.avail != null && c.avail.deprecated != null ? [deprecatedMeta(c.avail.deprecated)] : [];
					var wide = under == Types.I64 && !fits32(c.value);
					fields.push({
						name: c.name,
						access: wide ? [APublic, AStatic, AFinal] : [APublic, AStatic, AInline],
						meta: m,
						pos: POS,
						kind: FVar(uct, wide ? {expr: ECast(int(hex(c.value), "i64"), null), pos: POS} : intLiteral(c.value.low))
					});
					tally(count, "anonymous enum constants");
				}
			}
			if (fields.length == 0) continue;
			r.push({
				def: {
					pack: [packOf(o)],
					name: name,
					pos: POS,
					params: [],
					kind: TDClass(null, [], false, true, false),
					fields: fields
				},
				mod: mod
			});
		}
		return r;
	}

	// --- structs ---

	public function structDef(rec:RecordInfo, mod:Module):TypeDefinition {
		var fields:Array<Field> = [];
		var args:Array<FunctionArg> = [];
		var body:Array<Expr> = [];
		for (f in rec.fields) {
			var h = types.map(f.type, "", true);
			var t = ctype(h, mod);
			var n = ident(f.name);
			fields.push({name: n, access: [APublic], pos: POS, kind: FVar(t, null)});
			args.push({name: n, type: t});
			body.push({
				expr: EBinop(OpAssign, {expr: EField({expr: EConst(CIdent("this")), pos: POS}, n), pos: POS}, {expr: EConst(CIdent(n)), pos: POS}),
				pos: POS
			});
		}
		fields.push({
			name: "new",
			access: [APublic, AInline],
			pos: POS,
			kind: FFun({args: args, ret: null, expr: {expr: EBlock(body), pos: POS}})
		});
		tally(count, "structs");
		return {
			pack: [typePack(rec.name, rec.origin)],
			name: typeName(rec.name),
			pos: POS,
			meta: [meta(":hxmc.struct")],
			params: [],
			kind: TDClass(null, [], false, false, false),
			fields: fields
		};
	}

	// --- output ---

	public function write(out:String):Array<String> {
		var printer = new haxe.macro.Printer("\t");
		var modules = [];
		var names = new Map<String, Bool>();
		function emit(td:TypeDefinition, mod:Module) {
			var dir = out + "/" + td.pack.join("/");
			sys.FileSystem.createDirectory(dir);
			var b = new StringBuf();
			b.add("// Generated by hxmc-objc-extern-gen from the macOS SDK's headers (declarations only).\n");
			b.add("package " + td.pack.join(".") + ";\n\n");
			var imports = [for (k in mod.imports.keys()) k];
			imports.sort(Reflect.compare);
			for (i in imports)
				b.add("import " + i + ";\n");
			if (imports.length > 0) b.add("\n");
			b.add(printer.printTypeDefinition(td, false));
			b.add("\n");
			sys.io.File.saveContent(dir + "/" + td.name + ".hx", b.toString());
			modules.push(td.pack.concat([td.name]).join("."));
		}
		var states = new Map<String, ClassState>();
		for (name in ordered()) {
			var c = classes.get(name);
			var st = c.superName != null ? states.get(c.superName).inherit() : new ClassState();
			var mod = new Module(packOf(c.origin));
			var td = classDef(name, st, mod);
			states.set(name, st);
			names.set(name, true);
			tally(count, "classes");
			emit(td, mod);
		}
		var ps = [for (k in protosIncluded.keys()) k];
		ps.sort(Reflect.compare);
		for (p in ps) {
			var mod = new Module(packOf(protos.get(p).origin));
			var td = protoDef(p, mod);
			if (names.exists(td.name)) {
				skip("protocol named like a class");
				continue;
			}
			emit(td, mod);
			names.set(td.name, true);
		}
		var es = [for (k in enumsUsed.keys()) k];
		es.sort(Reflect.compare);
		for (n in es) {
			if (names.exists(n)) {
				skip("enum named like a class");
				continue;
			}
			var mod = new Module(typePack(n, enumsUsed.get(n).origin));
			emit(enumDef(enumsUsed.get(n), mod), mod);
			names.set(n, true);
		}
		var ss = [for (k in structsUsed.keys()) k];
		ss.sort(Reflect.compare);
		for (n in ss) {
			if (names.exists(n)) {
				skip("struct named like another type");
				continue;
			}
			var mod = new Module(typePack(n, structsUsed.get(n).origin));
			emit(structDef(structsUsed.get(n), mod), mod);
			names.set(n, true);
		}
		for (c in constantsDefs(n -> names.exists(n))) {
			emit(c.def, c.mod);
			names.set(c.def.name, true);
		}
		var cfs = [for (k in cfUsed.keys()) k];
		cfs.sort(Reflect.compare);
		for (n in cfs) {
			if (names.exists(n)) {
				skip("object of C named like another type");
				continue;
			}
			emit(cfDef(n), new Module(packOf(cfByTag.get(cfTag.get(n)).origin)));
			names.set(n, true);
		}
		for (c in cDefs(n -> names.exists(n))) {
			emit(c.def, c.mod);
			names.set(c.def.name, true);
		}
		return modules;
	}
}
