import foundation.*;
import appkit.*;
import corefoundation.*;
import objc.NSObject;
import hxmc.I64;
import hxmc.unsafe.Arena;
import hxmc.unsafe.CString;
import hxmc.unsafe.Ptr;

// Uses of the generated declarations that are lowered and run (macOS):
//   npm run gen, then with hxmc's Objective-C interop:
//   haxe -cp smoke -cp out -main Smoke --custom-target hxmc=bin/smoke
class Smoke {
	static function ns(s:String):NSString
		return Arena.scopedValue(a -> NSString.alloc().initWithUTF8String(a.cstring(s)));

	static function str(s:NSString):String
		return (cast s.UTF8String : CString).toString();

	static function main() {
		// NSString
		var s = ns("héllo");
		trace("string", str(s), s.length, str(s.uppercaseString));
		// an enum passed to a message (and its result an enum)
		var r = s.compareOptions(ns("HÉLLO"), NSStringCompareOptions.CaseInsensitiveSearch);
		trace("compare", r == NSComparisonResult.OrderedSame, (r : I64));
		// NSMutableArray
		var a = NSMutableArray.alloc().init();
		a.addObject(ns("one"));
		a.addObject(ns("two"));
		trace("array", a.count, str(cast a.objectAtIndex(1)), str(a.description));
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
			NSWindowStyleMask.Titled | NSWindowStyleMask.Closable, NSBackingStoreType.Buffered, false);
		trace("window", (w.styleMask : I64), w.styleMask == (NSWindowStyleMask.Titled | NSWindowStyleMask.Closable));
		w.styleMask = NSWindowStyleMask.Borderless;
		trace("window'", (w.styleMask : I64));
		var u = NSMutableString.alloc().initWithString(ns("ab"));
		u.appendString(ns("cd"));
		trace("mutable", str(u), str(NSMutableString.stringWithString(ns("x"))));
	}
}
