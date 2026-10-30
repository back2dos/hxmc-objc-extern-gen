import Model;

using StringTools;

// Availability on macOS, from clang's text dump (-ast-dump): the JSON dump
// prints an AvailabilityAttr without its platform or versions. Keyed by
// declaration ("I:NSView", "C:NSObject(NSKeyValueCoding)", "P:NSCopying",
// "<container>|-initWithFrame:", "<container>|@frame", "E:NSWindowStyleMask",
// "K:NSWindowStyleMaskTitled"), the same keys Reader asks for.
class Avail {
	var map = new Map<String, Availability>();

	// the Objective-C classes C's structs are objects of (`CF_BRIDGED_TYPE`),
	// by tag: the class (`NSString`, or `id`: an object of no class) and the
	// mutable one; JSON's ObjCBridgeAttr names neither
	public var bridges = new Map<String, {objc:Null<String>, mutable:Null<String>}>();

	public function new() {}

	public function get(key:String):Null<Availability>
		return map.get(key);

	public static function merge(a:Null<Availability>, b:Null<Availability>):Null<Availability> {
		if (a == null) return b;
		if (b == null) return a;
		return {unavailable: a.unavailable || b.unavailable, deprecated: a.deprecated != null ? a.deprecated : b.deprecated};
	}

	function add(key:String, a:Availability)
		map.set(key, merge(map.get(key), a));

	// the position after a balanced <...> at i
	static function skipAngle(s:String, i:Int):Int {
		var depth = 0;
		while (i < s.length) {
			var c = s.fastCodeAt(i++);
			if (c == "<".code) depth++;
			else if (c == ">".code && --depth == 0) break;
		}
		return i;
	}

	static function skipSpaces(s:String, i:Int):Int {
		while (i < s.length && s.fastCodeAt(i) == " ".code)
			i++;
		return i;
	}

	// tokens, a quoted string one token (without its quotes)
	static function tokens(s:String):Array<String> {
		var r = [], i = 0;
		while (true) {
			i = skipSpaces(s, i);
			if (i >= s.length) break;
			if (s.fastCodeAt(i) == '"'.code) {
				var b = new StringBuf();
				i++;
				while (i < s.length && s.fastCodeAt(i) != '"'.code) {
					if (s.fastCodeAt(i) == "\\".code) i++;
					if (i < s.length) b.addChar(s.fastCodeAt(i));
					i++;
				}
				i++;
				r.push(b.toString());
			} else {
				var j = i;
				while (j < s.length && s.fastCodeAt(j) != " ".code)
					j++;
				r.push(s.substring(i, j));
				i = j;
			}
		}
		return r;
	}

	static function major(v:String):Int {
		var m = Std.parseInt(v.split(".")[0]);
		return m == null ? 0 : m;
	}

	// an attribute's meaning on macOS, or null
	static function attr(kind:String, args:String):Null<Availability> {
		var t = tokens(args);
		while (t.length > 0 && (t[0] == "Inherited" || t[0] == "Implicit"))
			t.shift();
		return switch kind {
			case "UnavailableAttr":
				{unavailable: true, deprecated: null};
			case "DeprecatedAttr":
				{unavailable: false, deprecated: t.length > 0 ? t[0] : ""};
			case "AvailabilityAttr" if (t.length >= 4 && t[0] == "macos"):
				var unavailable = t[4] == "Unavailable" || t[3] != "0";
				var dep = t[2] != "0" && major(t[2]) < 100000; // 100000: API_TO_BE_DEPRECATED
				var msg = t.length > (t[4] == "Unavailable" ? 5 : 4) ? t[t[4] == "Unavailable" ? 5 : 4] : "";
				unavailable || dep ? {unavailable: unavailable, deprecated: dep ? msg : null} : null;
			case _: null;
		}
	}

	public function read(path:String) {
		var text = sys.io.File.getContent(path);
		// the open nodes: [depth] -> its key, perhaps not known yet (a
		// category's class is its first child)
		var stack:Array<Node> = [];
		var pos = 0, len = text.length;
		while (pos < len) {
			var end = text.indexOf("\n", pos);
			if (end < 0) end = len;
			var i = pos;
			while (i < end) {
				var c = text.fastCodeAt(i);
				if (c != " ".code && c != "|".code && c != "-".code && c != "`".code) break;
				i++;
			}
			var line = pos;
			pos = end + 1;
			if (i >= end) continue;
			var c = text.fastCodeAt(i);
			if (!(c >= "A".code && c <= "Z".code)) continue;
			var depth = (i - line) >> 1;
			var sp = text.indexOf(" ", i);
			if (sp < 0 || sp > end) sp = end;
			var kind = text.substring(i, sp);
			// after the address and the range
			var j = sp + 1;
			while (j < end && text.fastCodeAt(j) != " ".code)
				j++;
			j = skipSpaces(text, j);
			if (j < end && text.fastCodeAt(j) == "<".code) j = skipAngle(text, j);
			var rest = text.substring(j, end);
			if (kind.endsWith("Attr")) {
				var p = stack[depth - 1];
				if (p != null && p.kind == "RecordDecl" && (kind == "ObjCBridgeAttr" || kind == "ObjCBridgeMutableAttr")) {
					bridge(beforeQuote(p.text.replace(" definition", "")), kind == "ObjCBridgeMutableAttr", rest);
					continue;
				}
				if (p != null) {
					var a = attr(kind, rest);
					if (a != null) p.avail = merge(p.avail, a);
				}
				continue;
			}
			// leaving the nodes at this depth and below
			while (stack.length > depth) {
				var n = stack.pop();
				if (n != null) close(n);
			}
			while (stack.length < depth)
				stack.push(null);
			var parent = depth > 0 ? stack[depth - 1] : null;
			if (kind == "ObjCInterface" && parent != null && parent.kind == "ObjCCategoryDecl") {
				var q = rest.indexOf("'");
				parent.cls = rest.substring(q + 1, rest.lastIndexOf("'"));
			}
			stack.push(switch kind {
				case "ObjCInterfaceDecl" | "ObjCCategoryDecl" | "ObjCProtocolDecl" | "EnumDecl" | "ObjCMethodDecl" | "ObjCPropertyDecl" | "EnumConstantDecl":
					new Node(kind, afterLoc(rest), parent);
				// (C's: at the top level only, not a function body's)
				case "FunctionDecl" | "VarDecl" | "RecordDecl" if (depth == 1):
					new Node(kind, afterLoc(rest), parent);
				case _: null;
			});
		}
		while (stack.length > 0) {
			var n = stack.pop();
			if (n != null) close(n);
		}
	}

	// a declaration's text after its location
	static function afterLoc(s:String):String {
		var i = skipSpaces(s, 0);
		if (i < s.length && s.fastCodeAt(i) == "<".code) i = skipAngle(s, i);
		while (i < s.length && s.fastCodeAt(i) != " ".code)
			i++;
		return s.substring(i).trim();
	}

	static function lastWord(s:String):String {
		var t = s.split(" ");
		return t[t.length - 1];
	}

	static function beforeQuote(s:String):String {
		var q = s.indexOf("'");
		return lastWord((q < 0 ? s : s.substring(0, q)).trim());
	}

	static function containerKey(n:Null<Node>):Null<String> {
		if (n == null) return null;
		return switch n.kind {
			case "ObjCInterfaceDecl": "I:" + lastWord(n.text);
			case "ObjCProtocolDecl": "P:" + lastWord(n.text);
			case "ObjCCategoryDecl": "C:" + n.cls + "(" + (n.text == "" ? "" : lastWord(n.text)) + ")";
			case _: null;
		}
	}

	function close(n:Node) {
		if (n.avail == null) return;
		var key = switch n.kind {
			case "ObjCMethodDecl":
				var c = containerKey(n.parent);
				var r = ~/(?:^| )([-+]) (\S+) '/;
				c != null && r.match(n.text) ? c + "|" + r.matched(1) + r.matched(2) : null;
			case "ObjCPropertyDecl":
				var c = containerKey(n.parent);
				c != null ? c + "|@" + beforeQuote(n.text) : null;
			case "EnumDecl": beforeQuote(n.text) == "" ? null : "E:" + beforeQuote(n.text);
			case "EnumConstantDecl": "K:" + beforeQuote(n.text);
			case "FunctionDecl": "F:" + beforeQuote(n.text);
			case "VarDecl": "V:" + beforeQuote(n.text);
			case "RecordDecl": null;
			case _: containerKey(n);
		}
		if (key != null) add(key, n.avail);
	}

	// a struct's bridge (`ObjCBridgeAttr ... NSString`); an inherited one
	// (a later declaration's) names its class again or nothing
	function bridge(tag:String, mutable:Bool, args:String) {
		var t = [for (w in tokens(args)) if (w != "Inherited" && w != "Implicit") w];
		if (tag == "" || t.length == 0) return;
		var b = bridges.get(tag);
		if (b == null) bridges.set(tag, b = {objc: null, mutable: null});
		if (mutable) b.mutable = t[0] else b.objc = t[0];
	}
}

private class Node {
	public var kind:String;
	public var text:String;
	public var parent:Null<Node>;
	public var cls:String = "";
	public var avail:Null<Availability>;

	public function new(kind, text, parent) {
		this.kind = kind;
		this.text = text;
		this.parent = parent;
	}
}
