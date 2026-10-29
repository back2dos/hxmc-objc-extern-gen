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
	accessor:Bool
}

// what a class sees of itself and its superclasses
class ClassState {
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

	var r:Reader;
	var types:Types;
	var scope:Array<String>;

	// the classes of the SDK (categories merged), the protocols each adopts
	var classes = new Map<String, Container>();
	var adopted = new Map<String, Array<{proto:String, origin:Origin}>>();
	var enumByName = new Map<String, EnumInfo>();

	// what is generated
	public var included = new Map<String, Bool>();
	var structsUsed = new Map<String, RecordInfo>();
	var enumsUsed = new Map<String, EnumInfo>();
	var structOk = new Map<String, Null<String>>(); // record id -> why it cannot be passed (null: it can)

	// what the type being mapped references (committed when its member is kept)
	var refs:Array<String> = [];
	var structRefs:Array<RecordInfo> = [];
	var enumRefs:Array<EnumInfo> = [];

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
			for (m in cat.cat.members)
				c.members.push(m);
			for (p in cat.cat.protocols)
				adopted.get(cat.cls).push({proto: p, origin: cat.cat.origin});
		}
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
	}

	public function isClass(name:String):Bool
		return classes.exists(name);

	public function enumNamed(name:String):Null<EnumInfo>
		return enumByName.get(name);

	public function useClass(name:String, nullable:Bool):HType {
		refs.push(name);
		return HClass(name, nullable);
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
		structRefs = [];
		enumRefs = [];
		return f();
	}

	function commit() {
		for (n in refs)
			include(n);
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
		var done = new Map<String, Bool>();
		var progress = true;
		while (progress) {
			progress = false;
			for (name in [for (k in included.keys()) k]) {
				if (done.exists(name)) continue;
				done.set(name, true);
				progress = true;
				for (m in membersOf(name)) {
					if (unavailable(m.avail) || m.optional) continue;
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

	static function camel(ps:Array<String>):String {
		var b = new StringBuf();
		for (i in 0...ps.length)
			b.add(i == 0 ? ps[i] : ps[i].charAt(0).toUpperCase() + ps[i].substr(1));
		return b.toString();
	}

	// the name and parameter names of a method: the selector's first piece,
	// the following pieces; else @:selector and names that are valid
	function naming(sel:String, params:Array<Param>, taken:String->Bool):{name:String, params:Array<String>, selMeta:Bool} {
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
		if (derived && !taken(ps[0])) return {name: ps[0], params: names, selMeta: false};
		// renamed: the pieces joined, or with underscores until free
		var name = ident(ps.length > 1 && ps.join("") != "" ? camel([for (p in ps) if (p != "") p]) : ps[0]);
		if (derived && taken(ps[0]) && params.length <= 1 && ps.length == 1) name = ident(ps[0]);
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
			case HClass(name, nullable):
				var c = path([packOf(classes.get(name).origin)], name);
				nullable ? TPath({pack: [], name: "Null", params: [TPType(c)]}) : c;
			case HStruct(rec): path([packOf(rec.origin)], typeName(rec.name));
			case HEnum(e): path([packOf(e.origin)], typeName(e.name));
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

	static function meta(name:String, ?args:Array<Expr>):MetadataEntry
		return {name: name, params: args == null ? [] : args, pos: POS};

	static function str(s:String):Expr
		return {expr: EConst(CString(s, DoubleQuotes)), pos: POS};

	static function int(s:String, ?suffix:String):Expr
		return {expr: EConst(CInt(s, suffix)), pos: POS};

	static function libMeta(o:Origin):MetadataEntry
		return o.lib != null ? meta(":hxmc.lib", [str(o.lib)]) : meta(":hxmc.framework", [str(o.framework)]);

	static function deprecatedMeta(d:String):MetadataEntry
		return d == "" ? meta(":deprecated") : meta(":deprecated", [str(d)]);

	function methodField(f:FieldRec, ret:HType, isOverride:Bool, mod:Module):Field {
		var m = [];
		if (f.selMeta) m.push(meta(":selector", [str(f.sel)]));
		if (f.lib != null) m.push(libMeta(f.lib));
		if (f.deprecated != null) m.push(deprecatedMeta(f.deprecated));
		var access = [];
		if (f.isStatic) access.push(AStatic);
		if (isOverride) access.push(AOverride);
		return {
			name: f.name,
			access: access,
			meta: m,
			pos: POS,
			kind: FFun({args: [for (p in f.params) {name: p.name, type: ctype(p.t, mod)}], ret: ctype(ret, mod), expr: null})
		};
	}

	// --- classes ---

	public function classDef(name:String, st:ClassState, mod:Module):TypeDefinition {
		var c = classes.get(name);
		var fields:Array<Field> = [];
		var head:Array<Field> = [], tail:Array<Field> = [];
		var members = membersOf(name);
		where = name;
		var self = name;

		function retype(t:HType):HType
			return switch t {
				case HClass(_, n): HClass(self, n);
				case _: t;
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
		var live = [for (m in members) if (!unavailable(m.avail)) m];

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
					var h = try attempt(() -> types.map(t, self)) catch (s:Skip) {
						skip(s.reason, s.what);
						continue;
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
									lib: lib, deprecated: depr, instancetype: false, accessor: true
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
						lib: lib, deprecated: null, instancetype: false, accessor: true
					};
					var setF:FieldRec = {
						name: "set_" + pname, sel: setSel, isStatic: m.isStatic, params: [{name: "v", t: h}], ret: h,
						selMeta: renamed || setter != null, lib: lib, deprecated: null, instancetype: false, accessor: true
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

		// methods: of those whose names would be the same, the one of the fewest
		// pieces keeps it (`performSelector:` over `performSelector:withObject:`)
		var preferred = new Map<String, String>();
		for (m in live)
			switch m.kind {
				case KMethod(_, _, false):
					var k = (m.isStatic ? "+" : "-") + pieces(m.name)[0];
					var p = preferred.get(k);
					if (p == null || pieces(m.name).length < pieces(p).length) preferred.set(k, m.name);
				case _:
			}
		function claimed(isStatic:Bool, s:String, sel:String):Bool {
			var p = preferred.get((isStatic ? "+" : "-") + s);
			return p != null && p != sel;
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
							var n = naming(sel, params, s -> st.staticNames.exists(s) || claimed(true, s, sel));
							f = {
								name: n.name, sel: sel, isStatic: true, params: [for (i in 0...params.length) {name: n.params[i], t: sig.params[i]}],
								ret: sig.ret, selMeta: n.selMeta, lib: libOf(m), deprecated: depr, instancetype: isIt, accessor: false
							};
						}
						commit();
						fields.push(methodField(f, f.ret, false, mod));
						st.staticNames.set(f.name, f);
						st.staticSels.set(sel, f);
						if (isIt) st.factories.set(sel, f);
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
							if (isIt && !redeclared.exists(sel) && inh.instancetype) {
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
						var n = naming(sel, params, s -> st.names.exists(s) || claimed(false, s, sel) || multi && descendantClaims(name, s, sel));
						var f:FieldRec = {
							name: n.name, sel: sel, isStatic: false, params: [for (i in 0...params.length) {name: n.params[i], t: sig.params[i]}],
							ret: sig.ret, selMeta: n.selMeta, lib: libOf(m), deprecated: depr, instancetype: isIt, accessor: false
						};
						commit();
						fields.push(methodField(f, f.ret, false, mod));
						st.names.set(f.name, f);
						st.sels.set(sel, f);
						if (isIt) {
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

		var cm = [libMeta(c.origin), meta(":hxmc.objc")];
		if (c.avail != null && c.avail.deprecated != null) cm.push(deprecatedMeta(c.avail.deprecated));
		var sup = c.superName != null ? {
			mod.use([packOf(classes.get(c.superName).origin)], c.superName);
			{pack: [], name: c.superName};
		} : null;
		return {
			pack: [packOf(c.origin)],
			name: name,
			pos: POS,
			meta: cm,
			params: [],
			isExtern: true,
			kind: TDClass(sup, [], false, false, false),
			fields: head.concat(fields).concat(tail)
		};
	}

	// the instance names the classes below each class want: a property's, a
	// method's first piece (an ancestor's method of several pieces yields
	// its name: AppKit's NSObject category `layer:shouldInheritContentsScale:fromWindow:`
	// to NSView's property `layer`)
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
						case KMethod(_, _, _): if (!own.exists(pieces(m.name)[0])) own.set(pieces(m.name)[0], m.name);
					}
				}
				var s = classes.get(c).superName;
				while (s != null) {
					if (!below.exists(s)) below.set(s, new Map());
					var b = below.get(s);
					for (k => v in own)
						if (!b.exists(k) || v.startsWith("@")) b.set(k, v);
					s = classes.get(s).superName;
				}
			}
		}
		var b = below.get(cls);
		if (b == null) return false;
		var v = b.get(name);
		return v != null && v != sel;
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
					kind: FVar(self, {expr: ECast(int(hex(c.value), "i64"), null), pos: POS})
				});
				tally(count, "enum constants (64-bit, static final)");
			} else
				fields.push({name: n, access: [], meta: m, pos: POS, kind: FVar(null, small ? {expr: ECast(intLiteral(c.value.low), null), pos: POS} : intLiteral(c.value.low))});
			tally(count, "enum constants");
		}
		if (e.options) {
			function op(o:Binop, fname:String):Field {
				var b:Expr = {expr: ECheckType({expr: ECast({expr: EConst(CIdent("b")), pos: POS}, null), pos: POS}, uct), pos: POS};
				var body:Expr = {expr: ECast({expr: EParenthesis({expr: EBinop(o, {expr: EConst(CIdent("this")), pos: POS}, b), pos: POS}), pos: POS}, null), pos: POS};
				return {
					name: fname,
					access: [AInline],
					meta: [{name: ":op", params: [{expr: EBinop(o, {expr: EConst(CIdent("A")), pos: POS}, {expr: EConst(CIdent("B")), pos: POS}), pos: POS}], pos: POS}],
					pos: POS,
					kind: FFun({args: [{name: "b", type: self}], ret: self, expr: {expr: EReturn(body), pos: POS}})
				};
			}
			fields.push(op(OpOr, "or"));
			fields.push(op(OpAnd, "and"));
		}
		var m = e.avail != null && e.avail.deprecated != null ? [deprecatedMeta(e.avail.deprecated)] : [];
		tally(count, e.options ? "enums (options)" : "enums");
		return {
			pack: [packOf(e.origin)],
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
			pack: [packOf(rec.origin)],
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
		var es = [for (k in enumsUsed.keys()) k];
		es.sort(Reflect.compare);
		for (n in es) {
			if (names.exists(n)) {
				skip("enum named like a class");
				continue;
			}
			var mod = new Module(packOf(enumsUsed.get(n).origin));
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
			var mod = new Module(packOf(structsUsed.get(n).origin));
			emit(structDef(structsUsed.get(n), mod), mod);
			names.set(n, true);
		}
		for (c in constantsDefs(n -> names.exists(n))) {
			emit(c.def, c.mod);
			names.set(c.def.name, true);
		}
		return modules;
	}
}
