//
//  FCPNowPlayingButton.swift
//  flutter_carplay
//
//  Custom addition: wraps CPNowPlayingShuffleButton/CPNowPlayingRepeatButton/
//  CPNowPlayingImageButton so Dart can populate
//  CPNowPlayingTemplate.shared.nowPlayingButtons, which the stock plugin does
//  not expose.
//
//  CPNowPlayingShuffleButton/CPNowPlayingRepeatButton exist to replace
//  target-action handling of MPRemoteCommandCenter's changeShuffleModeCommand/
//  changeRepeatModeCommand, and CarPlay draws their glyph from that same
//  command center state (`currentShuffleType`/`currentRepeatType`) rather than
//  from `isSelected` alone, so both must be kept in sync here.
//

import CarPlay
import Flutter
import MediaPlayer

@available(iOS 14.0, *)
final class FCPNowPlayingButton {
  private(set) var elementId: String
  private var type: String
  private var isSelected: Bool
  private var repeatMode: String?
  private var image: String?
  private var imageData: FlutterStandardTypedData?
  private(set) var _super: CPNowPlayingButton?

  init(obj: [String: Any]) {
    self.elementId = obj["_elementId"] as! String
    self.type = obj["type"] as? String ?? "shuffle"
    self.isSelected = obj["isSelected"] as? Bool ?? false
    self.repeatMode = obj["repeatMode"] as? String
    self.image = obj["image"] as? String
    self.imageData = obj["imageData"] as? FlutterStandardTypedData
  }

  /// A stable description of this button's *visual* state, excluding the
  /// per-rebuild [elementId]. Used to skip redundant
  /// `CPNowPlayingTemplate.updateNowPlayingButtons` calls (which would redraw
  /// — and visibly flicker — every button even when nothing changed). The Dart
  /// side already dedupes, but state churn during looping playback (repeat-one)
  /// can still slip identical payloads through; this is the backstop.
  var signature: String {
    return [type, String(isSelected), repeatMode ?? "", image ?? ""].joined(separator: "|")
  }

  /// Whether this on-screen button can be reused for [new] — i.e. both are
  /// image buttons with the same image, so only `isSelected` can differ. Only
  /// image buttons draw a custom selected state, and their image is read-only.
  func canTakeOver(_ new: FCPNowPlayingButton) -> Bool {
    return _super != nil && type == "image" && new.type == "image" && image == new.image
  }

  /// Makes this on-screen button stand in for [new]. Reusing the instance
  /// keeps its CarPlay identifier, so when the row is re-sent the host reuses
  /// the button's on-screen view instead of creating a new one — a new view
  /// for every button was what made the whole row blink.
  func takeOver(_ new: FCPNowPlayingButton) {
    elementId = new.elementId
    isSelected = new.isSelected
    _super?.isSelected = new.isSelected
  }

  private func handler(button: CPNowPlayingButton) {
    DispatchQueue.main.async {
      FCPStreamHandlerPlugin.sendEvent(
        type: FCPChannelTypes.onNowPlayingButtonPressed,
        data: ["elementId": self.elementId]
      )
    }
  }

  var get: CPNowPlayingButton {
    let button: CPNowPlayingButton
    let commandCenter = MPRemoteCommandCenter.shared()

    switch type {
    case "repeat":
      button = CPNowPlayingRepeatButton(handler: self.handler)
      switch repeatMode {
      case "one":
        commandCenter.changeRepeatModeCommand.currentRepeatType = .one
      case "all":
        commandCenter.changeRepeatModeCommand.currentRepeatType = .all
      default:
        commandCenter.changeRepeatModeCommand.currentRepeatType = .off
      }
    case "shuffle":
      button = CPNowPlayingShuffleButton(handler: self.handler)
      commandCenter.changeShuffleModeCommand.currentShuffleType =
        isSelected ? .items : .off
    default:
      // "image": a plain custom toggle with no dedicated CarPlay button
      // class (e.g. the app's echo effect). The image is resolved
      // synchronously here — [imageData] is already the rasterized PNG
      // bytes for Flutter asset SVGs (resolved on the Dart side before the
      // method channel call), since CPNowPlayingImageButton, unlike
      // CPListItem, has no setter to swap the image in asynchronously later.
      let uiImage =
        makeUIImage(fromBytes: imageData)
        ?? makeUIImage(from: (image ?? "").toImageSource())
      button = makeImageButton(image: uiImage)
    }

    button.isSelected = isSelected
    self._super = button
    return button
  }

  /// iOS 27's CPNowPlayingImageButton downsizes its image to
  /// CPNowPlayingButtonMaximumImageSize (20pt) in the *source* image's scale,
  /// then tags the result with the screen scale. Our rasterized PNGs are 1x,
  /// so on a 3x phone the 120px glyph came out as 20px shown at 6.7pt — a
  /// third of the iOS 26 size. Measured on the iOS 27 simulator: 20pt@1x and
  /// 120pt@1x both end up 6.7pt@3x, while 20pt@3x stays 20pt@3x.
  ///
  /// The button's own `image.scale` tells us which scale it settled on, so
  /// when that differs from ours, redraw at the maximum point size in that
  /// scale and rebuild — the framework then has nothing left to rescale.
  private func makeImageButton(image: UIImage) -> CPNowPlayingImageButton {
    let button = CPNowPlayingImageButton(image: image, handler: self.handler)
    guard let buttonScale = button.image?.scale, buttonScale != image.scale,
      image.size.width > 0, image.size.height > 0
    else { return button }

    let maxSize = CPNowPlayingButtonMaximumImageSize
    let ratio = min(1, maxSize.width / image.size.width, maxSize.height / image.size.height)
    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
    let format = UIGraphicsImageRendererFormat()
    format.scale = buttonScale
    format.opaque = false
    let rescaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    return CPNowPlayingImageButton(image: rescaled, handler: self.handler)
  }
}
