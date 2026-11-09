// DMG 視窗外觀工具（不依賴 Finder AppleScript、第三方套件或網路；不需要管理員權限）。
//
//   swift Scripts/dmg-layout.swift background <輸出目錄>
//       產生安裝視窗背景 background.png（660×560）與 background@2x.png（1320×1120），
//       再由 build-dmg.sh 以 tiffutil 合併成 Retina 用的 background.tiff。
//   swift Scripts/dmg-layout.swift layout <已掛載的可寫入 DMG 目錄> <App 名稱.app> <視窗中顯示的卷宗名稱>
//       在 DMG 根目錄寫入 Finder 的 .DS_Store：圖示檢視、圖示位置、背景圖（alias 與 bookmark）。
//   swift Scripts/dmg-layout.swift dump <.DS_Store>
//       列出 .DS_Store 中的記錄，供驗證使用。
//
// .DS_Store 格式（buddy allocator + B-tree）參考公開的逆向工程文件；只寫入一個葉節點，足以容納安裝視窗所需的少量記錄。
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 版面常數（Finder 座標：原點在視窗內容左上角，數值為圖示中心）

enum Layout {
    static let width = 660
    static let height = 560
    static let iconSize = 112
    static let app = (x: 170, y: 196)
    static let applications = (x: 490, y: 196)
    static let guide = (x: 330, y: 446)
    static let guideFile = "Drag to Applications · 拖曳到應用程式.txt"
    static let backgroundFolder = ".background"
    static let backgroundFile = "background.tiff"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dmg-layout: \(message)\n".utf8))
    exit(1)
}

// MARK: - 背景圖

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// 以 Finder 座標（y 由上往下）置中繪製一行文字。
func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, weight: CTFontUIFontType, color: CGColor,
              centerX: CGFloat, top: CGFloat, height: CGFloat) {
    let font = CTFontCreateUIFontForLanguage(weight, size, "zh-Hant" as CFString)!
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let baselineFromTop = top + (size * 1.0)
    ctx.textPosition = CGPoint(x: centerX - bounds.width / 2, y: height - baselineFromTop)
    CTLineDraw(line, ctx)
}

func renderBackground(scale: Int) -> CGImage {
    let w = Layout.width * scale, h = Layout.height * scale
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let W = CGFloat(Layout.width), H = CGFloat(Layout.height)

    // 柔和的晨光漸層（上暖、下淡藍），與 App 圖示同一色系。
    let bg = CGGradient(colorsSpace: srgb, colors: [rgb(0xFBF6EE), rgb(0xE7EEF8)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

    // 標題
    drawText(ctx, "安裝靜醒  ·  Install Awaken", size: 22, weight: .emphasizedSystem, color: rgb(0x1B2552),
             centerX: W / 2, top: 34, height: H)

    // 兩個圖示之間的箭頭
    let y = H - CGFloat(Layout.app.y)
    let x0 = CGFloat(Layout.app.x) + 84, x1 = CGFloat(Layout.applications.x) - 84
    ctx.setStrokeColor(rgb(0x4A80C6))
    ctx.setLineWidth(9)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: x0, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 6, y: y))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: x1 - 26, y: y + 22))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 26, y: y - 22))
    ctx.strokePath()

    // 說明文字（圖示標籤下方）
    drawText(ctx, "將「靜醒」拖曳到「Applications」資料夾", size: 18, weight: .emphasizedSystem,
             color: rgb(0x1B2552), centerX: W / 2, top: 300, height: H)
    drawText(ctx, "Drag Awaken onto the Applications folder", size: 16, weight: .system,
             color: rgb(0x3A4868), centerX: W / 2, top: 328, height: H)
    drawText(ctx, "完成後從「應用程式」開啟  ·  Then open it from Applications", size: 12.5, weight: .system,
             color: rgb(0x5A6680), centerX: W / 2, top: 360, height: H)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    // 標示 72／144 dpi，tiffutil 會據此組成 Retina 雙解析度 TIFF。
    let dpi = Double(image.width) / Double(Layout.width) * 72
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

// MARK: - 位元組工具

struct Bytes {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] as [UInt32] { data.append(UInt8((v >> s) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func raw(_ d: Data) { data.append(d) }
    mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    mutating func pad(to n: Int) { if data.count < n { data.append(Data(count: n - data.count)) } }
    /// 固定長度的 Pascal 字串（第一個位元組為長度）。
    mutating func pascal(_ s: Data, field: Int) {
        let d = s.prefix(field - 1)
        u8(UInt8(d.count)); raw(d); raw(Data(count: field - 1 - d.count))
    }
}

func utf16be(_ s: String) -> Data {
    var d = Data()
    for unit in s.utf16 { d.append(UInt8(unit >> 8)); d.append(UInt8(unit & 0xFF)) }
    return d
}

// MARK: - Alias（version 2）：Finder 以此在 DMG 中找到背景圖

let hfsEpochOffset: TimeInterval = 2_082_844_800   // 1904-01-01 到 1970-01-01 的秒數

func hfsSeconds(_ date: Date) -> UInt32 { UInt32(max(0, date.timeIntervalSince1970 + hfsEpochOffset)) }

func makeAlias(volume: URL, volumeName: String, target: URL) throws -> Data {
    let fm = FileManager.default
    let volumeValues = try volume.resourceValues(forKeys: [.volumeCreationDateKey])
    let volumeDate = volumeValues.volumeCreationDate ?? Date()
    let folder = target.deletingLastPathComponent()
    let targetAttrs = try fm.attributesOfItem(atPath: target.path)
    let folderAttrs = try fm.attributesOfItem(atPath: folder.path)
    let targetCNID = UInt32((targetAttrs[.systemFileNumber] as? NSNumber)?.uint32Value ?? 0)
    let folderCNID = UInt32((folderAttrs[.systemFileNumber] as? NSNumber)?.uint32Value ?? 0)
    let created = (targetAttrs[.creationDate] as? Date) ?? Date()
    let fileName = target.lastPathComponent
    let folderName = folder.lastPathComponent
    let colonSafe = { (s: String) in Data(s.replacingOccurrences(of: ":", with: "/").utf8) }

    var b = Bytes()
    b.raw(Data(count: 4))          // app info
    b.u16(0)                       // 總長度，最後回填
    b.u16(2)                       // version 2
    b.u16(0)                       // kind：檔案
    b.pascal(colonSafe(volumeName), field: 28)
    b.u32(hfsSeconds(volumeDate))
    b.ascii("H+")                  // 檔案系統：HFS+
    b.u16(5)                       // 磁碟類型：可退出
    b.u32(folderCNID)
    b.pascal(colonSafe(fileName), field: 64)
    b.u32(targetCNID)
    b.u32(hfsSeconds(created))
    b.raw(Data(count: 8))          // type / creator code
    b.i16(-1); b.i16(-1)           // nlvlFrom / nlvlTo
    b.u32(0)                       // 卷宗屬性
    b.raw(Data(count: 2))          // 檔案系統 ID
    b.raw(Data(count: 10))         // 保留

    func tag(_ t: Int16, _ d: Data) {
        b.i16(t); b.u16(UInt16(d.count)); b.raw(d)
        if d.count % 2 == 1 { b.u8(0) }
    }
    func highRes(_ date: Date) -> Data {
        var t = Bytes(); t.u64(UInt64(max(0, (date.timeIntervalSince1970 + hfsEpochOffset) * 65536))); return t.data
    }
    tag(0, colonSafe(folderName))                                   // 上層資料夾名稱
    tag(16, highRes(volumeDate))                                    // 高精度卷宗建立時間
    tag(17, highRes(created))                                       // 高精度檔案建立時間
    var cnidPath = Bytes(); cnidPath.u32(folderCNID)
    tag(1, cnidPath.data)                                           // CNID 路徑
    tag(2, colonSafe("\(volumeName):\(folderName):\(fileName)"))    // Carbon 路徑
    var uFile = Bytes(); uFile.u16(UInt16(fileName.utf16.count)); uFile.raw(utf16be(fileName))
    tag(14, uFile.data)                                             // Unicode 檔名
    var uVol = Bytes(); uVol.u16(UInt16(volumeName.utf16.count)); uVol.raw(utf16be(volumeName))
    tag(15, uVol.data)                                              // Unicode 卷宗名稱
    tag(18, Data("/\(folderName)/\(fileName)".utf8))                // 卷宗內 POSIX 路徑
    tag(19, Data("/Volumes/\(volumeName)".utf8))                    // 一般使用者看到的掛載點
    b.i16(-1); b.u16(0)                                             // 結束

    var data = b.data
    let length = UInt16(data.count)
    data[4] = UInt8(length >> 8); data[5] = UInt8(length & 0xFF)
    return data
}

// MARK: - .DS_Store 記錄

enum Value {
    case blob(Data)
    case long(UInt32)
    case type(String)
}

struct Record {
    let name: String
    let code: String
    let value: Value

    func encode(into b: inout Bytes) {
        b.u32(UInt32(name.utf16.count)); b.raw(utf16be(name)); b.ascii(code)
        switch value {
        case .blob(let d): b.ascii("blob"); b.u32(UInt32(d.count)); b.raw(d)
        case .long(let v): b.ascii("long"); b.u32(v)
        case .type(let t): b.ascii("type"); b.ascii(t)
        }
    }
}

func iloc(_ p: (x: Int, y: Int)) -> Value {
    var b = Bytes()
    b.u32(UInt32(p.x)); b.u32(UInt32(p.y))
    b.raw(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00]))
    return .blob(b.data)
}

func bplist(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

/// Finder 依檔名（不分大小寫）再依代碼排序記錄。
func sorted(_ records: [Record]) -> [Record] {
    records.sorted {
        let a = $0.name.lowercased(), b = $1.name.lowercased()
        return a == b ? $0.code < $1.code : a.utf16.lexicographicallyPrecedes(b.utf16)
    }
}

/// 以 buddy allocator 格式寫出只有一個葉節點的 .DS_Store。
func encodeDSStore(_ records: [Record]) -> Data {
    // 區塊配置（位址相對於檔案第 4 個位元組；低 5 位元為 log2(大小)）
    let rootOffset: UInt32 = 0x1000, rootLog: UInt32 = 11      // 區塊 0：配置資訊
    let dsdbOffset: UInt32 = 0x20, dsdbLog: UInt32 = 5         // 區塊 1：DSDB 標頭
    let nodeOffset: UInt32 = 0x2000, nodeLog: UInt32 = 12      // 區塊 2：葉節點
    let total = 0x3000

    var node = Bytes()
    node.u32(0)                     // 0 代表葉節點
    node.u32(UInt32(records.count))
    for r in sorted(records) { r.encode(into: &node) }
    precondition(node.data.count <= 1 << nodeLog, "too many .DS_Store records for one node")

    var dsdb = Bytes()
    dsdb.u32(2)                     // 根節點區塊編號
    dsdb.u32(0)                     // 內部節點層數
    dsdb.u32(UInt32(records.count))
    dsdb.u32(1)                     // 節點數
    dsdb.u32(0x1000)                // 頁面大小

    var root = Bytes()
    let addresses = [rootOffset | rootLog, dsdbOffset | dsdbLog, nodeOffset | nodeLog]
    root.u32(UInt32(addresses.count)); root.u32(0)
    for a in addresses { root.u32(a) }
    for _ in addresses.count..<256 { root.u32(0) }
    root.u32(1); root.u8(4); root.ascii("DSDB"); root.u32(1)
    // 空閒清單：依 log2 大小 0…31。
    var free = [[UInt32]](repeating: [], count: 32)
    free[6] = [0x40]; free[7] = [0x80]; free[8] = [0x100]; free[9] = [0x200]; free[10] = [0x400]
    free[11] = [0x800, 0x1800]; free[12] = [0x3000]
    for k in 14...30 { free[k] = [UInt32(1) << UInt32(k)] }
    for list in free { root.u32(UInt32(list.count)); for o in list { root.u32(o) } }
    precondition(root.data.count <= 1 << rootLog)

    var file = Bytes()
    file.u32(1)
    file.ascii("Bud1")
    file.u32(rootOffset); file.u32(1 << rootLog); file.u32(rootOffset)
    file.raw(Data([0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00]))
    func place(_ d: Data, at offset: UInt32) {
        let start = Int(offset) + 4
        file.pad(to: start + d.count)
        file.data.replaceSubrange(start..<start + d.count, with: d)
    }
    place(dsdb.data, at: dsdbOffset)
    place(root.data, at: rootOffset)
    place(node.data, at: nodeOffset)
    file.pad(to: total + 4)
    return file.data
}

// MARK: - 讀回（驗證用）

func decodeDSStore(_ d: Data) -> [(name: String, code: String, type: String)] {
    decodeDSStoreFull(d).map { ($0.name, $0.code, $0.type) }
}

func decodeDSStoreFull(_ d: Data) -> [(name: String, code: String, type: String, blob: Data?)] {
    let bytes = [UInt8](d)
    func u32(_ o: Int) -> Int { Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3]) }
    guard bytes.count > 36, u32(0) == 1, String(bytes: bytes[4..<8], encoding: .ascii) == "Bud1" else { fail("not a .DS_Store") }
    let root = u32(8) + 4
    let count = u32(root)
    var addresses: [Int] = []
    for i in 0..<count { addresses.append(u32(root + 8 + i * 4)) }
    var p = root + 8 + ((count + 255) / 256) * 256 * 4
    let tocCount = u32(p); p += 4
    var dsdbBlock = -1
    for _ in 0..<tocCount {
        let n = Int(bytes[p]); let name = String(bytes: bytes[p + 1..<p + 1 + n], encoding: .ascii)
        p += 1 + n
        if name == "DSDB" { dsdbBlock = u32(p) }
        p += 4
    }
    guard dsdbBlock >= 0 else { fail("missing DSDB") }
    func blockOffset(_ i: Int) -> Int { (addresses[i] & ~0x1F) + 4 }
    let dsdb = blockOffset(dsdbBlock)
    var node = blockOffset(u32(dsdb))
    guard u32(node) == 0 else { fail("multi-level trees are not supported by this checker") }
    let n = u32(node + 4); node += 8
    var out: [(String, String, String, Data?)] = []
    for _ in 0..<n {
        let len = u32(node); node += 4
        var units: [UInt16] = []
        for i in 0..<len { units.append(UInt16(bytes[node + i * 2]) << 8 | UInt16(bytes[node + i * 2 + 1])) }
        node += len * 2
        let name = String(utf16CodeUnits: units, count: units.count)
        let code = String(bytes: bytes[node..<node + 4], encoding: .ascii) ?? "?"
        let type = String(bytes: bytes[node + 4..<node + 8], encoding: .ascii) ?? "?"
        node += 8
        var blob: Data? = nil
        switch type {
        case "blob":
            let len = u32(node)
            blob = Data(bytes[node + 4..<node + 4 + len])
            node += 4 + len
        case "long", "shor", "type": node += 4
        case "bool": node += 1
        case "comp", "dutc": node += 8
        case "ustr": node += 4 + u32(node) * 2
        default: fail("unknown record type \(type)")
        }
        out.append((name, code, type, blob))
    }
    return out
}

/// Finder 的 icvp 仍以舊式 Alias 記錄指向背景圖；CFURLCreateBookmarkDataFromAliasRecord 是系統唯一能解析它的 API
/// （已標為 deprecated，因此以 dlsym 取得，避免每次執行都印出警告；僅用於驗證）。
func aliasToBookmark(_ alias: Data) -> Data? {
    typealias Convert = @convention(c) (CFAllocator?, CFData) -> Unmanaged<CFData>?
    guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY),
          let symbol = dlsym(handle, "CFURLCreateBookmarkDataFromAliasRecord") else { return nil }
    let convert = unsafeBitCast(symbol, to: Convert.self)
    return convert(nil, alias as CFData)?.takeRetainedValue() as Data?
}

// MARK: - 進入點

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "background":
    guard args.count == 2 else { fail("usage: background <out-dir>") }
    let dir = URL(fileURLWithPath: args[1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    writePNG(renderBackground(scale: 1), dir.appendingPathComponent("background.png"))
    writePNG(renderBackground(scale: 2), dir.appendingPathComponent("background@2x.png"))
    print(dir.path)

case "layout":
    guard args.count == 4 else { fail("usage: layout <mounted-volume> <App.app> <volume-name>") }
    let volume = URL(fileURLWithPath: args[1], isDirectory: true)
    let appName = args[2], volumeName = args[3]
    let background = volume.appendingPathComponent(Layout.backgroundFolder).appendingPathComponent(Layout.backgroundFile)
    for path in [background.path, volume.appendingPathComponent(appName).path,
                 volume.appendingPathComponent("Applications").path,
                 volume.appendingPathComponent(Layout.guideFile).path] {
        var isDir: ObjCBool = false
        // Applications 是符號連結；只確認連結本身存在。
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else { fail("missing \(path)") }
    }
    do {
        let alias = try makeAlias(volume: volume, volumeName: volumeName, target: background)
        let bookmark = try background.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let windowSettings: [String: Any] = [
            "WindowBounds": "{{200, 120}, {\(Layout.width), \(Layout.height + 28)}}",
            "ShowSidebar": false, "ContainerShowSidebar": false, "SidebarWidth": 0,
            "ShowToolbar": false, "ShowTabView": false, "ShowPathbar": false, "ShowStatusBar": false,
        ]
        let iconView: [String: Any] = [
            "viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": Double(Layout.iconSize), "textSize": 13.0,
            "labelOnBottom": true, "showIconPreview": true, "showItemInfo": false,
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
            "backgroundType": 2, "backgroundImageAlias": alias,
            "backgroundColorRed": 0.91, "backgroundColorGreen": 0.93, "backgroundColorBlue": 0.97,
        ]
        let records = [
            Record(name: ".", code: "bwsp", value: .blob(try bplist(windowSettings))),
            Record(name: ".", code: "icvp", value: .blob(try bplist(iconView))),
            Record(name: ".", code: "pBBk", value: .blob(bookmark)),
            Record(name: ".", code: "vSrn", value: .long(1)),
            Record(name: ".", code: "vstl", value: .type("icnv")),
            Record(name: appName, code: "Iloc", value: iloc(Layout.app)),
            Record(name: "Applications", code: "Iloc", value: iloc(Layout.applications)),
            Record(name: Layout.guideFile, code: "Iloc", value: iloc(Layout.guide)),
        ]
        let out = volume.appendingPathComponent(".DS_Store")
        try encodeDSStore(records).write(to: out)
        for r in decodeDSStore(try Data(contentsOf: out)) { print("\(r.name)\t\(r.code)\t\(r.type)") }
    } catch {
        fail("\(error)")
    }

case "check":
    // 以系統 API 解析 .DS_Store 中的背景 alias 與 bookmark，確認都指向卷宗內的背景圖。
    guard args.count == 2 else { fail("usage: check <mounted-volume>") }
    let volume = URL(fileURLWithPath: args[1], isDirectory: true)
    let expected = volume.appendingPathComponent(Layout.backgroundFolder).appendingPathComponent(Layout.backgroundFile)
        .resolvingSymlinksInPath().standardizedFileURL
    guard let ds = FileManager.default.contents(atPath: volume.appendingPathComponent(".DS_Store").path) else { fail("no .DS_Store") }
    let records = decodeDSStoreFull(ds)
    guard let icvp = records.first(where: { $0.name == "." && $0.code == "icvp" })?.blob,
          let plist = try? PropertyListSerialization.propertyList(from: icvp, format: nil) as? [String: Any],
          let alias = plist["backgroundImageAlias"] as? Data, (plist["backgroundType"] as? Int) == 2 else {
        fail("icvp has no background alias")
    }
    func resolve(_ bookmark: Data, _ label: String) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) else {
            fail("\(label) does not resolve")
        }
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected.path else {
            fail("\(label) resolves to \(url.path), expected \(expected.path)")
        }
        print("\(label) -> \(url.lastPathComponent) OK")
    }
    guard let aliasBookmark = aliasToBookmark(alias) else {
        fail("alias record is not valid")
    }
    resolve(aliasBookmark, "backgroundImageAlias")
    if let pBBk = records.first(where: { $0.name == "." && $0.code == "pBBk" })?.blob { resolve(pBBk, "pBBk bookmark") }

case "dump":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("usage: dump <.DS_Store>") }
    for r in decodeDSStore(data) { print("\(r.name)\t\(r.code)\t\(r.type)") }

default:
    fail("usage: background <dir> | layout <volume> <App.app> <volume-name> | dump <.DS_Store>")
}
