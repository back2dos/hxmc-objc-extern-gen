import Model;

using StringTools;

// The headers' object-like macros that are constants (`#define kVK_Space
// 0x31`, `#define kAXTitleAttribute CFSTR("AXTitle")`, `#define
// kCGDockWindowLevel ((CGWindowLevel)20)`), from clang's `-E -dD` output: its
// line markers tell each macro's header. A body is evaluated as C would: casts
// to a type are dropped, other macros and enum constants are looked up.

enum MacroValue {
	MInt(v:haxe.Int64);
	MFloat(v:Float);
	MString(s:String); // CFSTR("...") or @"...": an NSString
}

typedef Macro = {name:String, body:String, origin:Origin};

class Macros {
	public var list:Array<Macro> = [];

	var byName = new Map<String, Macro>();
	var values = new Map<String, Null<MacroValue>>();
	var enumConsts = new Map<String, haxe.Int64>();

	public function new() {}

	public function read(path:String) {
		var origins = new Map<String, Origin>();
		var origin:Null<Origin> = null;
		var marker = ~/^# [0-9]+ "([^"]+)"/;
		var define = ~/^#define ([A-Za-z_][A-Za-z0-9_]*)(?:[ \t]+(.*))?$/;
		for (line in sys.io.File.getContent(path).split("\n")) {
			if (line.startsWith("# ") && marker.match(line)) {
				var f = marker.matched(1);
				origin = origins.get(f);
				if (origin == null) origins.set(f, origin = Origin.of(f));
			} else if (line.startsWith("#define ") && origin != null && define.match(line)) {
				var m = {name: define.matched(1), body: (define.matched(2) ?? "").trim(), origin: origin};
				list.push(m);
				byName.set(m.name, m); // (a later definition replaces an earlier one, as in C)
			}
		}
	}

	public function addEnums(enums:Array<EnumInfo>)
		for (e in enums)
			for (c in e.consts)
				enumConsts.set(c.name, c.value);

	// a macro's value: null when it is not a constant (empty, attributes, calls)
	public function value(name:String):Null<MacroValue> {
		if (values.exists(name)) return values.get(name);
		values.set(name, null); // (a cycle: no value)
		var m = byName.get(name);
		var v = m == null || m.body == "" ? null : try new Eval(tokens(m.body), this).run() catch (e:Dynamic) null;
		values.set(name, v);
		return v;
	}

	function lookup(name:String):Null<MacroValue> {
		if (byName.exists(name)) return value(name);
		var c = enumConsts.get(name);
		return c != null ? MInt(c) : null;
	}

	static function tokens(s:String):Array<String> {
		var re = ~/^(?:[ \t]+|(CFSTR\("[^"\\]*"\)|@"[^"\\]*"|'[^'\\]{1,4}'|0[xX][0-9A-Fa-f]+[uUlL]*|[0-9]*\.[0-9]+(?:[eE][-+]?[0-9]+)?[fF]?|[0-9]+\.(?:[eE][-+]?[0-9]+)?[fF]?|[0-9]+[eE][-+]?[0-9]+[fF]?|[0-9]+[uUlL]*|[A-Za-z_][A-Za-z0-9_]*|<<|>>|[-+*\/%&|^~()]))/;
		var r = [];
		while (s.length > 0) {
			if (!re.match(s)) throw "token";
			if (re.matched(1) != null) r.push(re.matched(1));
			s = re.matchedRight();
		}
		return r;
	}

	public function resolve(name:String)
		return lookup(name);

	public function isValue(name:String):Bool
		return byName.exists(name) || enumConsts.exists(name);
}

// precedence climbing over C's operators
private class Eval {
	final ts:Array<String>;
	final ms:Macros;
	var i = 0;

	public function new(ts, ms) {
		this.ts = ts;
		this.ms = ms;
	}

	public function run():MacroValue {
		var v = binary(0);
		if (i != ts.length) throw "trailing";
		return v;
	}

	static final PREC = ["|" => 1, "^" => 2, "&" => 3, "<<" => 4, ">>" => 4, "+" => 5, "-" => 5, "*" => 6, "/" => 6, "%" => 6];

	function binary(min:Int):MacroValue {
		var l = unary();
		while (i < ts.length) {
			var p = PREC.get(ts[i]);
			if (p == null || p < min) break;
			var op = ts[i++];
			l = apply(op, l, binary(p + 1));
		}
		return l;
	}

	function unary():MacroValue {
		var t = ts[i++];
		if (t == null) throw "end";
		switch t {
			case "-":
				return switch unary() {
					case MInt(v): MInt(-v);
					case MFloat(v): MFloat(-v);
					case _: throw "-";
				}
			case "+":
				return unary();
			case "~":
				return switch unary() {
					case MInt(v): MInt(~v);
					case _: throw "~";
				}
			case "(":
				// a cast: a name that is no value, then `)` and an operand
				if (i + 1 < ts.length && ~/^[A-Za-z_]/.match(ts[i]) && ts[i + 1] == ")" && !ms.isValue(ts[i])) {
					i += 2;
					return unary();
				}
				var v = binary(0);
				if (ts[i++] != ")") throw ")";
				return v;
			case _:
		}
		var c = t.charCodeAt(0);
		if (t.startsWith("CFSTR(")) return MString(t.substring(7, t.length - 2));
		if (c == "@".code) return MString(t.substring(2, t.length - 1));
		if (c == "'".code) {
			var v = 0;
			for (k in 1...t.length - 1)
				v = (v << 8) | t.charCodeAt(k);
			return MInt(v);
		}
		if (c == ".".code || (c >= "0".code && c <= "9".code)) {
			if (!t.startsWith("0x") && !t.startsWith("0X") && (t.indexOf(".") >= 0 || t.indexOf("e") >= 0 || t.indexOf("E") >= 0)) {
				var f = Std.parseFloat(~/[fF]$/.replace(t, ""));
				if (Math.isNaN(f)) throw "float";
				return MFloat(f);
			}
			var digits = ~/[uUlL]+$/.replace(t, "");
			// (an octal literal: rare in these headers, and not Haxe's)
			if (digits.length > 1 && digits.charAt(0) == "0" && digits.charAt(1) != "x" && digits.charAt(1) != "X") throw "octal";
			return MInt(digits.startsWith("0x") || digits.startsWith("0X") ? parseHex(digits.substr(2)) : haxe.Int64.parseString(digits));
		}
		var v = ms.resolve(t);
		if (v == null) throw "name";
		return v;
	}

	static function parseHex(h:String):haxe.Int64 {
		if (h.length > 16) throw "hex";
		var v:haxe.Int64 = 0;
		for (k in 0...h.length)
			v = (v << 4) | Std.parseInt("0x" + h.charAt(k));
		return v;
	}

	static function apply(op:String, a:MacroValue, b:MacroValue):MacroValue {
		switch [a, b] {
			case [MInt(x), MInt(y)]:
				return MInt(switch op {
					case "|": x | y;
					case "^": x ^ y;
					case "&": x & y;
					case "<<": x << y.low;
					case ">>": x >> y.low;
					case "+": x + y;
					case "-": x - y;
					case "*": x * y;
					case "/": if (y == 0) throw "/0"; x / y;
					case "%": if (y == 0) throw "%0"; x % y;
					case _: throw op;
				});
			case [MInt(_) | MFloat(_), MInt(_) | MFloat(_)]:
				var x = num(a), y = num(b);
				return MFloat(switch op {
					case "+": x + y;
					case "-": x - y;
					case "*": x * y;
					case "/": x / y;
					case _: throw op;
				});
			case _:
				throw op;
		}
	}

	static function num(v:MacroValue):Float
		return switch v {
			case MInt(x): haxe.Int64.toStr(x) == Std.string(x.low) ? x.low : Std.parseFloat(haxe.Int64.toStr(x));
			case MFloat(x): x;
			case _: throw "num";
		}
}
