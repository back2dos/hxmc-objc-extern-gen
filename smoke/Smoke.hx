import foundation.*;
import appkit.*;
import coregraphics.*;
import objc.NSObject;
import hxmc.I64;
import hxmc.objc.Selector;
import hxmc.objc.ObjCClass;
import hxmc.objc.Id;
import hxmc.unsafe.Arena;
import hxmc.unsafe.CString;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.Mem;
import coretext.CoreText;

using coregraphics.CoreGraphics;
using coretext.CoreText;

// Uses of the generated declarations that are lowered and run (macOS):
//   npm run gen, then with hxmc's Objective-C interop:
//   haxe -cp smoke -cp out -main Smoke --custom-target hxmc=bin/smoke
// a delegate implementing two of the protocol's optional methods
class XmlLog extends NSObject implements NSXMLParserDelegate {
	public var log:Array<String> = [];

	public function new() {}

	public function parserDidStartElementNamespaceURIQualifiedNameAttributes(parser:NSXMLParser, didStartElement:NSString, namespaceURI:Null<NSString>,
			qualifiedName:Null<NSString>, attributes:NSDictionary<NSString, NSString>)
		log.push("<" + didStartElement.UTF8String.toString() + ">");

	public function parserFoundCharacters(parser:NSXMLParser, foundCharacters:NSString)
		log.push(foundCharacters.UTF8String.toString());
}

// a class AppKit sends a class method: the pasteboard asking which types it reads
class Clip extends NSObject implements NSPasteboardReading {
	public static var asked = 0;

	public function new() {}

	public static function readableTypesForPasteboard(pasteboard:NSPasteboard):NSArray<NSString> {
		asked++;
		return NSArray.arrayWithObject(Smoke.ns("org.example.clip"));
	}
}

class Smoke {
	public static function ns(s:String):NSString
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
		trace("array", a.count, str(a.objectAtIndex(1)), str(a.description));
		trace("indexOf", a.indexOfObject(ns("two")), str(a.componentsJoinedByString(ns("+"))));
		// NSDictionary
		var d = NSDictionary.dictionaryWithObject(ns("v"), ns("k"));
		trace("dict", d.count, str(d.objectForKey(ns("k"))));
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
		// blocks: a comparator returning an enum, a block given a block (a
		// completion handler, kept and called after the accessor returns)
		var sorted = a.sortedArrayUsingComparator((p, q) -> (cast q : NSString).compare(cast p));
		trace("sorted", str(sorted.componentsJoinedByString(ns(","))));
		var done:Null<() -> Void> = null;
		var urls = NSArray.arrayWithObject(NSURL.fileURLWithPath(ns("/tmp"), true));
		NSFileCoordinator.alloc().initWithFilePresenter(null).prepareForReadingItemsAtURLsOptionsWritingItemsAtURLsOptionsErrorByAccessor(urls, None, null, None,
			Ptr.nil(), completion -> done = completion);
		trace("accessor", done != null);
		// options: none, combined, tested
		var o = NSFileCoordinatorReadingOptions.WithoutChanges | NSFileCoordinatorReadingOptions.ResolvesSymbolicLink;
		// lightweight generics: typed elements, a block over them, covariance,
		// a superclass's argument (an anchor constrained to anchors of its axis)
		var host = NSView.alloc().initWithFrame(new CGRect(new CGPoint(0, 0), new CGSize(10, 10)));
		host.addSubview(NSButton.alloc().initWithFrame(new CGRect(new CGPoint(0, 0), new CGSize(5, 5))));
		var subs:NSArray<NSView> = host.subviews;
		var kinds = [];
		subs.enumerateObjectsUsingBlock((view, i, stop) -> kinds.push(str(view.className)));
		var objects:NSArray = NSArray.upcast(subs);
		trace("generics", kinds, objects.count, Std.isOfType(subs.objectAtIndex(0), NSButton));
		var c = host.leadingAnchor.constraintEqualToAnchor(subs.objectAtIndex(0).leadingAnchor);
		trace("anchor", c != null);
		trace("options", o.has(NSFileCoordinatorReadingOptions.WithoutChanges), o.has(NSFileCoordinatorReadingOptions.ForUploading),
			NSFileCoordinatorReadingOptions.None.has(NSFileCoordinatorReadingOptions.WithoutChanges), o.has(None));
		// C's functions, objects and constants: drawing with Core Graphics
		// (`using`: its functions as methods of their first argument), a Core
		// Text font (toll-free bridged: an NSFont), AppKit's and Foundation's
		var space = CoreGraphics.CGColorSpaceCreateDeviceRGB();
		// (premultiplied last: kCGImageAlphaPremultipliedLast)
		var ctx = CoreGraphics.CGBitmapContextCreate(Ptr.nil(), 4, 4, 8, 16, space, cast 1);
		var path = CoreGraphics.CGPathCreateMutable();
		path.CGPathAddRect(Ptr.nil(), new CGRect(new CGPoint(1, 1), new CGSize(2, 2)));
		ctx.CGContextSetFillColorWithColor(CoreGraphics.CGColorCreateSRGB(1, 0, 0, 1));
		ctx.CGContextAddPath(path);
		ctx.CGContextFillPath();
		// (a block through a C function: Block<F>, from a function)
		var elements = [];
		path.CGPathApplyWithBlock(e -> elements.push(Mem.getI32(e, 0)));
		var px = ctx.CGBitmapContextGetData();
		trace("drawn", elements, [for (i in 0...4) Mem.getU8(px, 20 + i)], [for (i in 0...4) Mem.getU8(px, i)], path.CGPathGetBoundingBox().size.width,
			CoreGraphics.CGRectZero.size.width);
		var font = CoreText.CTFontCreateWithName(ns("Helvetica"), 12, Ptr.nil());
		trace("font", font.CTFontGetSize(), font.CTFontCopyFamilyName().UTF8String.toString(), font.pointSize);
		trace("constants", AppKit.NSFontAttributeName.UTF8String.toString(),
			Foundation.NSStringFromRect(new CGRect(new CGPoint(1, 2), new CGSize(3, 4))).UTF8String.toString());
		// a nil-terminated variadic message (`...rest`)
		var listed = NSArray.arrayWithObjects(ns("x"), ns("y"), ns("z"));
		trace("variadic", listed.count, str(listed.componentsJoinedByString(ns("+"))));
		// class methods: a Haxe class's static AppKit sends (ObjCClass: the class itself)
		var pb = NSPasteboard.pasteboardWithUniqueName();
		pb.clearContents();
		pb.setString(ns("hello"), ns("public.utf8-plain-text"));
		var read = pb.readObjectsForClasses(NSArray.arrayWithObject((ObjCClass.of(Clip) : Id)), null);
		trace("pasteboard", Clip.asked > 0, read == null ? -1 : read.count, (cast ObjCClass.of(Clip) : NSObject).respondsToSelector(Selector.of("readableTypesForPasteboard:")));
		pb.releaseGlobally();
		done();
	}
}
