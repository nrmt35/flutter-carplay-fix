//
//  FCPExtensions.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay
import Flutter
import UIKit

private let fcpTintedImageCache = NSCache<NSString, UIImage>()

// Creates a UIImage from raw PNG bytes sent over the MethodChannel.
// Used for Flutter asset SVGs that are rasterized to PNG on the Dart side,
// since UIImage cannot decode SVG directly. Returns nil when the data is
// missing or cannot be decoded so callers can fall back to string resolution.
func makeUIImage(fromBytes data: FlutterStandardTypedData?) -> UIImage? {
  guard let data = data else { return nil }
  return UIImage(data: data.data)
}

/// [maxSize] (points), when given, shrinks the loaded image to fit it at the
/// screen scale before it is cached and delivered — see
/// `UIImage.downscaled(toFit:scale:)` for why that matters.
@available(iOS 14.0, *)
func loadUIImage(
  from imagePath: String,
  bytes imageData: FlutterStandardTypedData?,
  tint imageTint: FCPImageTint? = nil,
  placeholderKind: String? = nil,
  maxSize: CGSize? = nil,
  completion: @escaping (UIImage) -> Void
) {
  var cacheKey = makeImageCacheKey(imagePath: imagePath, imageData: imageData, tint: imageTint)
  if let maxSize = maxSize {
    cacheKey += "|\(maxSize.width)x\(maxSize.height)"
  }
  if let cachedImage = fcpTintedImageCache.object(forKey: cacheKey as NSString) {
    completion(cachedImage)
    return
  }
  let scale = UIScreen.main.scale

  func complete(_ image: UIImage, cache: Bool) {
    let result = image.applyingImageTint(imageTint)
    if cache {
      fcpTintedImageCache.setObject(result, forKey: cacheKey as NSString)
    }
    completion(result)
  }

  if let bytesImage = makeUIImage(fromBytes: imageData) {
    complete(bytesImage.downscaled(toFit: maxSize, scale: scale), cache: true)
    return
  }

  // Cache successfully-loaded images (including untinted ones, e.g. remote
  // track art) so they aren't re-fetched on every list update — which made
  // network art flash the placeholder / intermittently disappear. A transient
  // failure still delivers a placeholder via `completion`, but `loadFailed`
  // keeps it out of the cache so a later load can succeed.
  var loadFailed = false
  loadUIImageAsync(
    from: imagePath.toImageSource(),
    placeholderKind: placeholderKind,
    fitting: maxSize,
    scale: scale,
    completion: { uiImage in
      guard let uiImage = uiImage else { return }
      complete(uiImage, cache: !loadFailed)
    },
    errorCallback: { _ in loadFailed = true }
  )
}

private func makeImageCacheKey(
  imagePath: String,
  imageData: FlutterStandardTypedData?,
  tint imageTint: FCPImageTint?
) -> String {
  let bytesKey = imageData.map { "\($0.data.count):\($0.data.hashValue)" } ?? "nil"
  let tintKey = imageTint?.cacheKey ?? "notint"
  return [imagePath, bytesKey, tintKey].joined(separator: "|")
}

// Image Source (no UIImage creation here)
enum ImageSource {
  case url(URL)
  case file(String)
  case flutterAsset(String)
  /// A native SF Symbol name (e.g. "arrow.down.circle.fill"), passed from Dart
  /// with an "sf:" prefix. Resolved via `UIImage(systemName:)`.
  case sfSymbol(String)
}

// String → ImageSource
extension String {
  func toImageSource() -> ImageSource {
    if self.starts(with: "sf:") {
      return .sfSymbol(String(self.dropFirst(3)))
    } else if self.starts(with: "http") {
      return .url(URL(string: self)!)
    } else if self.starts(with: "file://") {
      // Dart sends `Uri.file(path).toString()`, which percent-encodes spaces
      // and non-ASCII characters. `UIImage(contentsOfFile:)` needs the raw
      // filesystem path, so decode via URL(string:).path rather than a naive
      // prefix strip — otherwise any encoded char yields a nonexistent path
      // and locally cached art silently falls back to the placeholder.
      if let url = URL(string: self) {
        return .file(url.path)
      }
      let stripped = self.replacingOccurrences(of: "file://", with: "")
      return .file(stripped.removingPercentEncoding ?? stripped)
    } else {
      return .flutterAsset(self)
    }
  }
}

func makeSafeUIPlaceholder() -> UIImage {
  if Thread.isMainThread {
    return makeUIPlaceholder()
  } else {
    return DispatchQueue.main.sync {
      makeUIPlaceholder()
    }
  }
}

/// Thread-safe variant of `makeArtworkPlaceholder` — used as the *initial*
/// image on artwork slots (row covers, image-row grid tiles) while the real
/// image loads asynchronously, so rows show the standard placeholder instead
/// of a blank gap during loading. Accessory/trailing slots and tab icons keep
/// the transparent `makeSafeUIPlaceholder`.
func makeSafeArtworkPlaceholder(kind: String? = nil) -> UIImage {
  if Thread.isMainThread {
    return makeArtworkPlaceholder(kind: kind)
  }
  return DispatchQueue.main.sync {
    makeArtworkPlaceholder(kind: kind)
  }
}

func makeUIPlaceholder() -> UIImage {
  let size = CGSize(width: 100, height: 100)
  let renderer = UIGraphicsImageRenderer(size: size)
  return renderer.image { _ in
    UIColor.clear.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))
  }
}

/// App-registered artwork fallbacks keyed by "kind" (see the
/// `setArtworkPlaceholder` channel): the app sends its own placeholder assets
/// (rasterized on the Dart side) per content kind — e.g. `"default"` for
/// tracks and `"playlist"` for playlist covers — so the loading/failure
/// placeholder is pixel-identical to the asset shown for items with no
/// artwork at all. When no matching slot is registered,
/// `makeArtworkPlaceholder` draws a lookalike instead.
var artworkPlaceholders: [String: UIImage] = [:]

/// Resolves the registered placeholder for [kind], falling back to the
/// `"default"` slot.
private func registeredArtworkPlaceholder(kind: String?) -> UIImage? {
  if let kind = kind, let image = artworkPlaceholders[kind] {
    return image
  }
  return artworkPlaceholders["default"]
}

/// Artwork placeholders already shrunk to a slot's size, keyed by kind and
/// size and remembering the image they were made from, so re-registering a
/// placeholder refreshes them.
private var fittedArtworkPlaceholders: [String: (source: UIImage, fitted: UIImage)] = [:]

/// `makeArtworkPlaceholder(kind:)` shrunk to fit [maxSize] points, e.g.
/// `CPListItem.maximumImageSize`. Every list row still loading (or failing to
/// load) its cover shows this, and handing CarPlay the full-size placeholder
/// cost ~2ms of main-thread resizing per row (see `UIImage.downscaled`).
/// Main thread only.
func makeArtworkPlaceholder(kind: String?, fitting maxSize: CGSize) -> UIImage {
  let key = "\(kind ?? "")|\(maxSize.width)x\(maxSize.height)"
  let registered = registeredArtworkPlaceholder(kind: kind)
  if let cached = fittedArtworkPlaceholders[key],
    registered == nil || cached.source === registered
  {
    return cached.fitted
  }
  let source = registered ?? makeArtworkPlaceholder(kind: kind)
  let fitted = source.downscaled(toFit: maxSize, scale: UIScreen.main.scale)
  fittedArtworkPlaceholders[key] = (source, fitted)
  return fitted
}

/// Visible fallback for *artwork* that is loading or failed to download (a
/// cover URL that can't be fetched over the network). Prefers the
/// app-registered placeholder for [kind] (see [artworkPlaceholders]);
/// otherwise drawn to match the app's `cp_placeholder_track.svg` — a #737378
/// rounded square (corner radius 6/28 of the side) with a centered white
/// music-note glyph. Used only for artwork slots — asset/file/SF-symbol
/// failures (and the accessory-image slots, which never load over the
/// network) keep the transparent `makeUIPlaceholder` so a grey square never
/// appears as a trailing glyph. Main thread only (UIKit drawing + symbol
/// lookup).
func makeArtworkPlaceholder(kind: String? = nil) -> UIImage {
  if let registered = registeredArtworkPlaceholder(kind: kind) {
    return registered
  }
  let side: CGFloat = 180
  let size = CGSize(width: side, height: side)
  let renderer = UIGraphicsImageRenderer(size: size)
  return renderer.image { _ in
    let rect = CGRect(origin: .zero, size: size)
    UIColor(red: 115 / 255.0, green: 115 / 255.0, blue: 120 / 255.0, alpha: 1).setFill()
    UIBezierPath(roundedRect: rect, cornerRadius: side * 6.0 / 28.0).fill()
    let config = UIImage.SymbolConfiguration(pointSize: side * 0.35, weight: .regular)
    if let note = UIImage(systemName: "music.note", withConfiguration: config)?
      .withTintColor(.white, renderingMode: .alwaysOriginal)
    {
      let noteSize = note.size
      let origin = CGPoint(
        x: (size.width - noteSize.width) / 2,
        y: (size.height - noteSize.height) / 2)
      note.draw(in: CGRect(origin: origin, size: noteSize))
    }
  }
}

// UIImage creation (MAIN THREAD ONLY)
@available(iOS 14.0, *)
func makeUIImage(
  from source: ImageSource,
  placeholderKind: String? = nil,
  errorCallback: ((Error) -> Void)? = nil
) -> UIImage {
  do {
    switch source {
    case .url(let url):
      let data = try Data(contentsOf: url)
      if let image = UIImage(data: data) {
        return image
      } else {
        throw NSError(
          domain: "ImageLoadError", code: 0,
          userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
      }

    case .file(let path):
      if let image = UIImage(contentsOfFile: path) {
        return image
      } else {
        throw NSError(
          domain: "ImageLoadError", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "File not found or invalid"])
      }

    case .flutterAsset(let name):
      guard !name.isEmpty else {
        throw NSError(
          domain: "ImageLoadError", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Asset name cannot be empty"])
      }
      let key = SwiftFlutterCarplayPlugin.registrar!.lookupKey(forAsset: name)
      guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
        throw NSError(
          domain: "ImageLoadError", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Asset not found in bundle"])
      }
      guard let image = UIImage(contentsOfFile: path) else {
        throw NSError(
          domain: "ImageLoadError", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Failed to decode image at path: \(path)"])
      }
      return image

    case .sfSymbol(let name):
      let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
      guard
        let symbol = UIImage(systemName: name, withConfiguration: config)?
          .withRenderingMode(.alwaysTemplate)
      else {
        throw NSError(
          domain: "ImageLoadError", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Unknown SF Symbol: \(name)"])
      }
      return symbol
    }
  } catch {
    errorCallback?(error)
    // Only network artwork gets the visible grey placeholder; other sources
    // (assets, files, SF symbols — incl. accessory glyphs) stay transparent.
    if case .url = source {
      return makeArtworkPlaceholder(kind: placeholderKind)
    }
    return makeUIPlaceholder()
  }
}

// Asynchronous image loader. Always calls completion on main thread.
// [maxSize] (points, at [scale]) shrinks downloaded/file images on the
// background queue that loaded them, so the main thread never decodes or
// resizes the full-size original.
@available(iOS 14.0, *)
func loadUIImageAsync(
  from source: ImageSource,
  placeholderKind: String? = nil,
  fitting maxSize: CGSize? = nil,
  scale: CGFloat = 1,
  completion: @escaping (UIImage?) -> Void,
  errorCallback: ((Error) -> Void)? = nil
) {
  switch source {
  case .url(let url):
    let task = URLSession.shared.dataTask(with: url) { data, response, error in
      do {
        if let error = error { throw error }
        guard let data = data, let image = UIImage(data: data) else {
          throw NSError(
            domain: "ImageLoadError", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
        }
        let fitted = image.downscaled(toFit: maxSize, scale: scale)
        DispatchQueue.main.async { completion(fitted) }
      } catch {
        DispatchQueue.main.async {
          errorCallback?(error)
          // Network fetch failed — show the visible artwork placeholder
          // instead of leaving the slot empty.
          completion(
            maxSize.map { makeArtworkPlaceholder(kind: placeholderKind, fitting: $0) }
              ?? makeArtworkPlaceholder(kind: placeholderKind))
        }
      }
    }
    task.resume()

  case .file(let path):
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        guard let image = UIImage(contentsOfFile: path) else {
          throw NSError(
            domain: "ImageLoadError", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "File not found or invalid"])
        }
        let fitted = image.downscaled(toFit: maxSize, scale: scale)
        DispatchQueue.main.async { completion(fitted) }
      } catch {
        DispatchQueue.main.async {
          errorCallback?(error)
          completion(makeUIPlaceholder())
        }
      }
    }

  case .sfSymbol(let name):
    DispatchQueue.main.async {
      // Render at a generous point size; CarPlay scales the accessory image to
      // fit the row. `.alwaysTemplate` lets the tint pipeline recolor it.
      let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
      if let symbol = UIImage(systemName: name, withConfiguration: config)?
        .withRenderingMode(.alwaysTemplate)
      {
        completion(symbol)
      } else {
        errorCallback?(
          NSError(
            domain: "ImageLoadError", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Unknown SF Symbol: \(name)"]))
        completion(makeUIPlaceholder())
      }
    }

  case .flutterAsset(let name):
    DispatchQueue.main.async {
      do {
        guard !name.isEmpty else {
          throw NSError(
            domain: "ImageLoadError", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Asset name cannot be empty"])
        }
        let key = SwiftFlutterCarplayPlugin.registrar!.lookupKey(forAsset: name)
        guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
          throw NSError(
            domain: "ImageLoadError", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Asset not found in bundle"])
        }
        guard let image = UIImage(contentsOfFile: path) else {
          throw NSError(
            domain: "ImageLoadError", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Failed to decode image at path: \(path)"])
        }
        completion(image.downscaled(toFit: maxSize, scale: scale))
      } catch {
        errorCallback?(error)
        completion(makeUIPlaceholder())
      }
    }
  }
}

//  UIImage utilities (safe, UI only)
extension UIImage {
  /// A copy that fits within [maxSize] points at [scale], or `self` when it
  /// already fits or no size is given. Safe off the main thread.
  ///
  /// CarPlay shrinks every image handed to `CPListItem.setImage` to the row's
  /// maximum size on the calling (main) thread, decoding the original each
  /// time: ~7ms per row for a 600px cover, so a few hundred rows stalled the
  /// main thread — and with it the Now Playing screen and row taps — for
  /// seconds. Shrinking once, off the main thread, before caching makes each
  /// later `setImage` ~0.7ms.
  func downscaled(toFit maxSize: CGSize?, scale: CGFloat) -> UIImage {
    guard let maxSize = maxSize, size.width > 0, size.height > 0 else { return self }
    let ratio = min(maxSize.width / size.width, maxSize.height / size.height)
    guard ratio < 1 else { return self }
    let target = CGSize(width: size.width * ratio, height: size.height * ratio)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }.withRenderingMode(renderingMode)
  }

  func resizeImageTo(size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      draw(in: CGRect(origin: .zero, size: size))
    }
  }

  func applyingImageTint(_ tint: FCPImageTint?) -> UIImage {
    guard let tint = tint else { return self }

    let lightTrait = UITraitCollection(userInterfaceStyle: .light)
    let darkTrait = UITraitCollection(userInterfaceStyle: .dark)
    let lightImage = tintedGlyph(
      with: tint.color(for: .light).resolvedColor(with: lightTrait),
      selectedSafe: tint.selectedSafe
    )
    let darkImage = tintedGlyph(
      with: tint.color(for: .dark).resolvedColor(with: darkTrait),
      selectedSafe: tint.selectedSafe
    )

    let imageAsset = UIImageAsset()
    imageAsset.register(lightImage, with: lightTrait)
    imageAsset.register(darkImage, with: darkTrait)
    return imageAsset.image(with: UITraitCollection.current).withRenderingMode(.alwaysOriginal)
  }

  private func tintedGlyph(with color: UIColor, selectedSafe: Bool) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false

    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let rect = CGRect(origin: .zero, size: size)
    let glyph = renderer.image { _ in
      color.setFill()
      UIRectFill(rect)
      draw(in: rect, blendMode: .destinationIn, alpha: 1)
    }.withRenderingMode(.alwaysOriginal)

    guard selectedSafe else { return glyph }

    return renderer.image { context in
      let shadowColor = contrastColor(for: color).cgColor
      let blur = max(1, min(size.width, size.height) * 0.06)
      context.cgContext.setShadow(offset: .zero, blur: blur, color: shadowColor)
      glyph.draw(in: rect)
      context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
      glyph.draw(in: rect)
    }.withRenderingMode(.alwaysOriginal)
  }

  private func contrastColor(for color: UIColor) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    if luminance > 0.55 {
      return UIColor.black.withAlphaComponent(0.85)
    }
    return UIColor.white.withAlphaComponent(0.95)
  }
}

/// Resolve a tab icon from [systemIcon]:
/// 1. Named SF Symbol (ex: "star") → `UIImage(systemName:)`
/// 2. Image source (URL, file, Flutter asset) → loaded via `makeUIImage` /
///    `loadUIImageAsync`, using a placeholder on iOS 26+ while loading async.
///
/// The [applyImage] closure is called once with the resolved image so that
/// the caller can assign it to the appropriate template property.
@available(iOS 14.0, *)
func resolveTabIcon(
  _ systemIcon: String,
  applyImage: @escaping (UIImage?) -> Void
) {
  // 1. SF Symbol — resolved synchronously
  if let sysImage = UIImage(systemName: systemIcon) {
    applyImage(sysImage)
    return
  }

  // 2. Image source (URL, file, asset)
  let imageSource = systemIcon.toImageSource()
  if #available(iOS 26.0, *) {
    applyImage(makeSafeUIPlaceholder())
    loadUIImageAsync(from: imageSource) { uiImage in
      applyImage(uiImage)
    }
  } else {
    applyImage(makeUIImage(from: imageSource))
  }
}

// Regex helper
extension String {
  func match(_ regex: String) -> [[String]] {
    let nsString = self as NSString
    return (try? NSRegularExpression(pattern: regex))?
      .matches(in: self, range: NSRange(location: 0, length: nsString.length))
      .map { match in
        (0..<match.numberOfRanges).map {
          match.range(at: $0).location == NSNotFound
            ? ""
            : nsString.substring(with: match.range(at: $0))
        }
      } ?? []
  }
}
