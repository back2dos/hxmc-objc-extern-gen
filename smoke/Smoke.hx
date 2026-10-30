import foundation.*;
import appkit.*;
import coregraphics.*;
import objc.NSObject;
import hxmc.I64;
import hxmc.objc.Selector;
import hxmc.unsafe.Arena;
import hxmc.unsafe.CString;
import hxmc.unsafe.Ptr;

// Uses of the generated declarations that are lowered and run (macOS):
//   npm run gen, then with hxmc's Objective-C interop:
//   haxe -cp smoke -cp out -main Smoke --custom-target hxmc=bin/smoke
// a delegate implementing two of the protocol's optional methods
class XmlLog extends NSObject implements NSXMLParserDelegate {
	public var log:Array<String> = [];

	public function new() {}

	public function parserDidStartElementNamespaceURIQualifiedNameAttributes(parser:NSXMLParser, didStartElement:NSString, namespaceURI:Null<NSString>,
			qualifiedName:Null<NSString>, attributes:NSDictionary)
		log.push("<" + didStartElement.UTF8String.toString() + ">");

	public function parserFoundCharacters(parser:NSXMLParser, foundCharacters:NSString)
		log.push(foundCharacters.UTF8String.toString());
}

class Smoke {
	static function ns(s:String):NSString
		return Arena.scopedValue(a -> NSString.alloc().initWithUTF8String(a.cstring(s)));

	static function str(s:NSString):String
		return s.UTF8String.toString();

	static function main() {
		// NSString
		var s = ns("héllo");
		trace("string", str(s), s.length, str(s.uppercaseString));
		// an enum passed to a message (and its result an enum)
		var r = s.compare(ns("HÉLLO"), CaseInsensitiveSearch);
		trace("compare", r == NSComparisonResult.OrderedSame, (r : I64));
		// overloads: one name, the selectors of their parameters' names
		trace("compare'", (s.compare(ns("HÉLLO")) : I64), s.rangeOfString(ns("l")).location, s.rangeOfString(ns("L"), CaseInsensitiveSearch).location);
		trace("font", NSFont.systemFontOfSize(12).pointSize, NSFont.systemFontOfSize(13, 0.4).pointSize);
		trace("perform", str(cast s.performSelector(Selector.of("uppercaseString"))), str(cast s.performSelector(Selector.of("stringByAppendingString:"), ns("!"))));
		// a C string both ways
		var c:CString = s.UTF8String;
		trace("cstring", c.length(), str(NSString.stringWithUTF8String(c)));
		// NSMutableArray
		var a = NSMutableArray.alloc().init();
		a.addObject(ns("one"));
		a.addObject(ns("two"));
		trace("array", a.count, str(cast a.objectAtIndex(1)), str(a.description));
		trace("indexOf", a.indexOfObject(ns("two")), str(a.componentsJoinedByString(ns("+"))));
		// NSDictionary
		var d = NSDictionary.dictionaryWithObject(ns("v"), ns("k"));
		trace("dict", d.count, str(cast d.objectForKey(ns("k"))));
		// NSNumber
		var n = NSNumber.numberWithInteger(42);
		trace("number", n.integerValue, n.doubleValue, str(n.stringValue));
		// NSView: a struct property round trip
		var v = NSView.alloc().initWithFrame(new CGRect(new CGPoint(1, 2), new CGSize(30, 40)));
		var f = v.frame;
		trace("frame", f.origin.x, f.origin.y, f.size.width, f.size.height);
		v.frame = new CGRect(new CGPoint(5, 6), new CGSize(70, 80));
		f = v.frame;
		trace("frame'", f.origin.x, f.origin.y, f.size.width, f.size.height);
		v.hidden = true;
		trace("hidden", v.hidden, v.flipped);
		// an options enum through a property
		var w = NSWindow.alloc().initWithContentRect(new CGRect(new CGPoint(0, 0), new CGSize(100, 100)),
			Titled | Closable | Resizable, Buffered, false);
		trace("window", (w.styleMask : I64), w.styleMask == (NSWindowStyleMask.Titled | NSWindowStyleMask.Closable | NSWindowStyleMask.Resizable));
		w.styleMask = NSWindowStyleMask.Borderless;
		trace("window'", (w.styleMask : I64));
		var u = NSMutableString.alloc().initWithString(ns("ab"));
		u.appendString(ns("cd"));
		trace("mutable", str(u), str(NSMutableString.stringWithString(ns("x"))));
		// protocols: a delegate, conformance (NSString adopts NSCopying), id<P>
		var x = new XmlLog();
		var parser = NSXMLParser.alloc().initWithData(ns("<a>one<b>two</b></a>").dataUsingEncoding(NSStringConstants.NSUTF8StringEncoding));
		parser.delegate = x;
		trace("delegate", parser.parse(), x.log, (x : NSObject).respondsToSelector(Selector.of("parserDidEndDocument:")));
		var copying:NSCopying = s;
		trace("conforms", Std.isOfType(copying, NSCopying), Std.isOfType((x : NSObject), NSCopying), Std.isOfType((x : NSObject), NSXMLParserDelegate));
	}
}
