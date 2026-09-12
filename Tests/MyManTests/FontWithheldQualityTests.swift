import AppKit
import CoreText
import WebKit
import XCTest
@testable import MyMan

/// Bypasses OCR entirely: only these source glyphs enter inference. Hidden
/// originals are loaded afterward, solely for measurement and visual comparison.
final class FontWithheldQualityTests: XCTestCase {
    @MainActor func testWithheldLetterDesignWithoutOCR() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_FONT_UI_REVIEW"] else { throw XCTSkip("Opt-in native font quality review") }
        _ = NSApplication.shared
        let controller = FontWorkbenchController(); defer { controller.window.close() }
        controller.window.makeKeyAndOrderFront(nil)
        let deadline = Date().addingTimeInterval(30)
        while !controller.ready && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(controller.ready)
        var measurements: [[String: Any]] = []
        for name in ["HelveticaNeue", "Georgia", "Courier-Bold"] {
            let original = CTFontCreateWithName(name as CFString, 1000, nil)
            let source = CTFontCreateCopyWithAttributes(original, 700_000 / CTFontGetCapHeight(original), nil, nil)
            var captured: [String: Any] = [:]
            for char in "HOnolmpeSI" {
                var unicode = Array(String(char).utf16)[0], glyph: CGGlyph = 0
                XCTAssertTrue(CTFontGetGlyphsForCharacters(source, &unicode, &glyph, 1))
                let path = try XCTUnwrap(CTFontCreatePathForGlyph(source, glyph, nil)); let bounds = path.boundingBoxOfPath
                var advance = CGSize.zero; CTFontGetAdvancesForGlyphs(source, .horizontal, &glyph, &advance, 1)
                let shift = 50 - bounds.minX
                var svg = ""
                func point(_ p: CGPoint) -> String { "\(p.x + shift) \(p.y)" }
                path.applyWithBlock { element in
                    let e = element.pointee
                    switch e.type {
                    case .moveToPoint: svg += "M" + point(e.points[0])
                    case .addLineToPoint: svg += "L" + point(e.points[0])
                    case .addQuadCurveToPoint: svg += "Q" + point(e.points[0]) + " " + point(e.points[1])
                    case .addCurveToPoint: svg += "C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2])
                    case .closeSubpath: svg += "Z"
                    @unknown default: break
                    }
                }
                captured[String(char)] = ["char": String(char), "source": "traced", "path": svg, "advanceWidth": advance.width, "xMin": 50, "xMax": bounds.width + 50, "yMin": bounds.minY, "yMax": bounds.maxY]
            }
            let metrics: [String: Any] = ["unitsPerEm":1000,"capHeight":700,"xHeight":CTFontGetXHeight(source),"ascent":CTFontGetAscent(source),"descent": -CTFontGetDescent(source),"baselineY":0]
            let result = try await controller.webView.callAsyncJavaScript("const out=await FontEngine.inferMissing(captured, metrics); const merged={...out.inferred, ...captured, ' ':out.space}; const bytes=new Uint8Array(await FontEngine.buildFont(merged,metrics,'Withheld Review')); let encoded=''; for(let i=0;i<bytes.length;i+=16384) encoded+=String.fromCharCode(...bytes.subarray(i,i+16384)); return {font:btoa(encoded),capturedPreserved:Object.keys(captured).every(c=>merged[c].path===captured[c].path),style:out.style};", arguments: ["captured":captured,"metrics":metrics], in:nil, contentWorld:.page) as? [String:Any]
            XCTAssertEqual(result?["capturedPreserved"] as? Bool, true)
            let data = try XCTUnwrap(Data(base64Encoded:result?["font"] as? String ?? "")); try FontProjectStore.validate(data)
            let descriptor = try XCTUnwrap((CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first)
            let inferred = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
            let canvas = NSImage(size:CGSize(width:1000,height:380)); canvas.lockFocus()
            NSColor.white.setFill(); NSRect(x:0,y:0,width:1000,height:380).fill()
            for (row, font) in [source,inferred].enumerated() {
                let display = CTFontCreateCopyWithAttributes(font, 64_000 / CTFontGetCapHeight(font), nil, nil)
                ((row == 0 ? "\(name) · withheld originals" : "Sample-based approximations") as NSString).draw(at:NSPoint(x:30,y:CGFloat(330-row*165)),withAttributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.darkGray])
                let baseline = CGFloat(225-row*165)
                NSColor.lightGray.setStroke(); let guide = NSBezierPath(); guide.move(to:NSPoint(x:25,y:baseline));guide.line(to:NSPoint(x:975,y:baseline));guide.stroke()
                for (column,char) in "ABg27?".enumerated() {
                    var unicode=Array(String(char).utf16)[0],glyph:CGGlyph=0
                    XCTAssertTrue(CTFontGetGlyphsForCharacters(display,&unicode,&glyph,1))
                    let path=try XCTUnwrap(CTFontCreatePathForGlyph(display,glyph,nil)),bounds=path.boundingBoxOfPath
                    let ctx=try XCTUnwrap(NSGraphicsContext.current?.cgContext);ctx.saveGState();ctx.translateBy(x:CGFloat(40+column*150),y:baseline);ctx.addPath(path);ctx.setFillColor(NSColor.black.cgColor);ctx.fillPath();ctx.restoreGState()
                    measurements.append(["font":name,"character":String(char),"source":row == 0 ? "withheld" : "inferred","width":bounds.width,"bottom":bounds.minY,"top":bounds.maxY])
                    XCTAssertTrue(bounds.width.isFinite && bounds.width > 0)
                    if row == 1 && "AB27".contains(char) { XCTAssertEqual(bounds.minY,0,accuracy:1) }
                }
            }
            canvas.unlockFocus()
            try AgentImages.png(canvas).write(to:URL(fileURLWithPath:folder).appendingPathComponent("\(name)-withheld-comparison.png"))
        }
        try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:folder).appendingPathComponent("withheld-measurements.json"))
    }
}
