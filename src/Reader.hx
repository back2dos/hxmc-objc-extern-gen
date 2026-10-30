import Model;

using StringTools;

// Reads clang's JSON AST (-ast-dump=json): classes (with their categories),
// protocols, enums, records and typedefs. A node's `loc` and `range` name
// their `file` only when it differs from the previous one in dump order, so
// the walk follows every location, the nodes' children included.
class Reader {
	public var classes = new Map<String, Container>();
	public var categories:Array<{cls:String, cat:Container}> = [];
	public var protocols = new Map<String, Container>();
	public var enums:Array<EnumInfo> = [];
	public var enumsById = new Map<String, EnumInfo>();
	public var records = new Map<String, RecordInfo>(); // by id of the definition
	public var recordsByTag = new Map<String, RecordInfo>();
	public var typedefs = new Map<String, Typedef>();

	var file = "";
	var origins = new Map<String, Origin>();
	var avail:Avail;

	public function new(avail)
		this.avail = avail;

	function originOf(file:String):Origin {
		var o = origins.get(file);
		if (o == null) origins.set(file, o = Origin.of(file));
		return o;
	}

	// a bare location: its `file` when it changed; returns the offset
	function bare(l:Dynamic):Int {
		if (l == null) return -1;
		var f:Null<String> = l.file;
		if (f != null) file = f;
		var o:Null<Int> = l.offset;
		return o == null ? -1 : o;
	}

	// a location, perhaps in a macro: the spelling, then the expansion
	// (where the declaration is)
	function location(l:Dynamic):Int {
		if (l == null) return -1;
		if (l.spellingLoc != null || l.expansionLoc != null) {
			bare(l.spellingLoc);
			return bare(l.expansionLoc);
		}
		return bare(l);
	}

	// follows a node's locations: returns the file of its loc and its extent
	function locate(n:Dynamic):{file:String, span:Int} {
		location(n.loc);
		var f = file;
		var span = -1;
		if (n.range != null) {
			var b = location(n.range.begin), e = location(n.range.end);
			if (b >= 0 && e >= 0) span = e - b;
		}
		return {file: f, span: span};
	}

	function walkChildren(n:Dynamic) {
		var inner:Array<Dynamic> = n.inner;
		if (inner != null)
			for (c in inner)
				walk(c);
	}

	// every node, for the locations; declarations at the top level read
	function walk(n:Dynamic) {
		locate(n);
		walkChildren(n);
	}

	public function read(root:Dynamic) {
		locate(root);
		var inner:Array<Dynamic> = root.inner;
		for (n in inner) {
			var at = locate(n);
			var o = originOf(at.file);
			switch (n.kind : String) {
				case "ObjCInterfaceDecl":
					interfaceDecl(n, o, at.span);
				case "ObjCCategoryDecl":
					categoryDecl(n, o);
				case "ObjCProtocolDecl":
					protocolDecl(n, o, at.span);
				case "EnumDecl":
					enumDecl(n, o);
				case "RecordDecl":
					recordDecl(n, o);
				case "TypedefDecl":
					typedefDecl(n);
				case _:
					walkChildren(n);
			}
		}
	}

	function ctype(t:Dynamic):CType {
		var q:String = t.qualType;
		var d:Null<String> = t.desugaredQualType;
		return {qual: q, desugared: d != null ? d : q};
	}

	// the members of an interface, category or protocol (walking them)
	function members(n:Dynamic, c:Container, o:Origin, key:String) {
		var inner:Array<Dynamic> = n.inner;
		if (inner == null) return;
		for (m in inner) {
			locate(m);
			switch (m.kind : String) {
				case "ObjCMethodDecl" if (m.isImplicit != true):
					var params:Array<Param> = [];
					var designated = false;
					var ps:Array<Dynamic> = m.inner;
					if (ps != null)
						for (p in ps) {
							locate(p);
							if (p.kind == "ParmVarDecl") params.push({name: p.name, type: ctype(p.type)});
							if (p.kind == "ObjCDesignatedInitializerAttr") designated = true;
							walkChildren(p);
						}
					var inst = m.instance == true;
					var mem = new Member(m.name, !inst, KMethod(ctype(m.returnType), params, m.variadic == true), o);
					mem.at = m.range != null ? location(m.range.begin) : -1;
					mem.optional = m.control == "optional";
					mem.designated = designated;
					mem.avail = avail.get(key + "|" + (inst ? "-" : "+") + m.name);
					c.members.push(mem);
				case "ObjCPropertyDecl":
					var getter:Null<String> = m.getter != null ? m.getter.name : null;
					var setter:Null<String> = m.setter != null ? m.setter.name : null;
					var pt = ctype(m.type);
					// (nullable) that the type lost (`API_AVAILABLE CALayer *`: NSView's layer)
					if (m.nullability == true && pt.qual.indexOf("_Nonnull") < 0 && pt.qual.indexOf("_Null") < 0) pt.qual += " _Nullable";
					var mem = new Member(m.name, Reflect.field(m, "class") == true,
						KProperty(pt, m.readonly == true, getter, setter), o);
					mem.optional = m.control == "optional";
					mem.avail = avail.get(key + "|@" + m.name);
					c.members.push(mem);
					walkChildren(m);
				case _:
					walkChildren(m);
			}
		}
	}

	function protocolList(n:Dynamic):Array<String> {
		var ps:Array<Dynamic> = n.protocols;
		return ps == null ? [] : [for (p in ps) p.name];
	}

	function interfaceDecl(n:Dynamic, o:Origin, span:Int) {
		var name:String = n.name;
		var c = classes.get(name);
		if (c == null) classes.set(name, c = new Container(name));
		if (n.inner != null || span > c.span) {
			if (span > c.span) {
				c.span = span;
				c.origin = o;
			}
			if (Reflect.field(n, "super") != null) c.superName = Reflect.field(n, "super").name;
			for (p in protocolList(n))
				if (c.protocols.indexOf(p) < 0) c.protocols.push(p);
		}
		if (c.origin == null) c.origin = o;
		var a = avail.get("I:" + name);
		if (a != null) c.avail = Avail.merge(c.avail, a);
		members(n, c, o, "I:" + name);
	}

	function categoryDecl(n:Dynamic, o:Origin) {
		var cls:String = Reflect.field(n, "interface").name;
		var name:String = n.name != null ? n.name : "";
		var c = new Container(name);
		c.origin = o;
		c.protocols = protocolList(n);
		var key = "C:" + cls + "(" + name + ")";
		c.avail = avail.get(key);
		members(n, c, o, key);
		categories.push({cls: cls, cat: c});
	}

	function protocolDecl(n:Dynamic, o:Origin, span:Int) {
		var name:String = n.name;
		var c = protocols.get(name);
		if (c == null) protocols.set(name, c = new Container(name));
		if (span > c.span) {
			c.span = span;
			c.origin = o;
		}
		for (p in protocolList(n))
			if (c.protocols.indexOf(p) < 0) c.protocols.push(p);
		var a = avail.get("P:" + name);
		if (a != null) c.avail = Avail.merge(c.avail, a);
		var begin = n.range != null ? location(n.range.begin) : -1, f = file;
		var before = c.members.length;
		members(n, c, o, "P:" + name);
		optionals(f, begin, c.members.slice(before));
	}

	// which methods of a protocol are @optional: the dumps say it of
	// properties only, so the last of @optional and @required before each
	// method in the protocol's source (read here, never written out)
	var sources = new Map<String, Null<String>>();

	function optionals(f:String, begin:Int, ms:Array<Member>) {
		if (begin < 0 || f == "") return;
		if (!sources.exists(f)) sources.set(f, try sys.io.File.getContent(f) catch (_:Dynamic) null);
		var src = sources.get(f);
		if (src == null) return;
		for (m in ms) {
			if (!m.kind.match(KMethod(_, _, _)) || m.at <= begin || m.at > src.length) continue;
			var head = src.substring(begin, m.at);
			m.optional = head.lastIndexOf("@optional") > head.lastIndexOf("@required");
		}
	}

	// the value of an enumerator's initializer: a ConstantExpr's
	static function constant(n:Dynamic):Null<String> {
		if (n.kind == "ConstantExpr" && n.value != null) return n.value;
		var inner:Array<Dynamic> = n.inner;
		if (inner != null)
			for (c in inner) {
				var v = constant(c);
				if (v != null) return v;
			}
		return null;
	}

	// a decimal integer, wrapping to 64 bits (unsigned values over 2^63)
	public static function parseInt64(s:String):haxe.Int64 {
		var neg = s.startsWith("-");
		var v = haxe.Int64.make(0, 0);
		for (i in (neg ? 1 : 0)...s.length)
			v = v * 10 + (s.charCodeAt(i) - "0".code);
		return neg ? -v : v;
	}

	function enumDecl(n:Dynamic, o:Origin) {
		var id:String = n.id;
		var name:Null<String> = n.name;
		var inner:Array<Dynamic> = n.inner;
		var consts:Array<Dynamic> = inner == null ? [] : [for (c in inner) if (c.kind == "EnumConstantDecl") c];
		walkChildren(n);
		if (consts.length == 0) return;
		var e = new EnumInfo(id, name, o);
		if (n.fixedUnderlyingType != null) e.underlying = ctype(n.fixedUnderlyingType);
		for (c in inner)
			if (c.kind == "FlagEnumAttr") e.options = true;
		if (name != null) e.avail = avail.get("E:" + name);
		var next = haxe.Int64.make(0, 0);
		for (c in consts) {
			var v = constant(c);
			var value = v != null ? parseInt64(v) : next;
			next = value + 1;
			e.consts.push({name: c.name, value: value, avail: avail.get("K:" + c.name)});
		}
		enums.push(e);
		enumsById.set(id, e);
	}

	function recordDecl(n:Dynamic, o:Origin) {
		var tag:String = n.name != null ? n.name : "";
		walkChildren(n);
		if (n.completeDefinition != true) return;
		var r = new RecordInfo(n.id, tag, n.tagUsed == "union", o);
		r.complete = true;
		var inner:Array<Dynamic> = n.inner;
		if (inner != null)
			for (f in inner)
				switch (f.kind : String) {
					case "FieldDecl":
						r.fields.push({name: f.name != null ? f.name : "", type: ctype(f.type), bitfield: f.isBitfield == true});
					case "RecordDecl" | "EnumDecl": // nested: an anonymous member's type, read with its field
					case _:
				}
		records.set(r.id, r);
		if (tag != "") recordsByTag.set(tag, r);
	}

	// the declaration a typedef's type names (its tag's id)
	static function tagOf(n:Dynamic):Null<String> {
		if (n.ownedTagDecl != null) return n.ownedTagDecl.id;
		if (n.decl != null && (n.kind == "RecordType" || n.kind == "EnumType")) return n.decl.id;
		var inner:Array<Dynamic> = n.inner;
		if (inner != null)
			for (c in inner) {
				var t = tagOf(c);
				if (t != null) return t;
			}
		return null;
	}

	function typedefDecl(n:Dynamic) {
		walkChildren(n);
		var name:String = n.name;
		if (!typedefs.exists(name)) typedefs.set(name, {name: name, type: ctype(n.type), tagId: tagOf(n)});
	}
}
